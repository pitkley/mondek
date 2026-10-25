// Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
// SPDX-License-Identifier: Apache-2.0
import { test, expect } from '@playwright/test';
import { checkpoint, connected, mode, streams } from '../support/helpers.mjs';

const project = 'browser-monitoring';
const source = 'durable-volume-monitoring';
const limits = { warning_items: 5, critical_items: 10 };
const defaults = { warning_items: 50, critical_items: 100 };
const manifest = (rules) => ({ version: 1, project, rules });
const rule = (extra = {}) => ({ key: 'volume-limits', name: 'Project volume limits',
  source_id: source, parameter_contract: 'volume.pending-items.v1', params: limits, ...extra });

async function policy(request, desired) {
  // Each fixture mutation is intentional; ordinary clients must reconcile before selecting a fresh base.
  const revision = await (await request.get('/api/v1/configuration/revision')).json();
  const response = await request.post('/api/v1/configuration/policy/plan', { data: { manifest: desired, base_head: revision.head } });
  expect(response.ok(), await response.text()).toBeTruthy();
  const plan = await response.json();
  expect(plan.review_token).toBeTruthy();
  const applied = await request.post('/api/v1/configuration/policy/apply', {
    data: { manifest: desired, review_token: plan.review_token },
  });
  expect(applied.ok(), await applied.text()).toBeTruthy();
  return applied.json();
}

async function ready(request) {
  await expect.poll(async () => (await streams(request, { freshness: 'fresh' })).total,
    { timeout: 120_000 }).toBe(1);
  return (await streams(request)).items[0];
}

test('project policy stays readable through exceptions, offline adoption and browser reconnect', async ({ page, request }, testInfo) => {
  const stream = await ready(request);
  const assignmentID = stream.assignment_id;
  async function assignment() {
    return (await request.get(`/api/v1/assignments/${assignmentID}`)).json();
  }
  await page.goto(`/checks/${stream.id}?return_to=${encodeURIComponent('/checks?search=volume&tab=all&view=list')}`);
  await page.getByRole('link', { name: 'Review configuration', exact: true }).click();
  await expect(page.getByRole('link', {name: 'Back to result', exact: true})).toBeVisible();
  await connected(page);
  await expect(page.locator('#configuration-origin')).toContainText('Defaults from code');
  await expect(page.locator('#configuration-value-comparison')).toHaveCount(0);
  await page.locator('#configuration-origin > summary').click();
  await page.locator('#configuration-as-code > summary').click();
  await expect(page.locator('#configuration-as-code')).toContainText('Rules are optional');
  await checkpoint(page, testInfo, 'source-values-without-a-policy-document');

  await mode(request, { offline_installations: [stream.runner_id] });
  try {
    await policy(request, manifest([rule()]));
    await expect(page.locator('#configuration-value-comparison')).toContainText('Project:');
    await expect(page.locator('#configuration-value-comparison')).toContainText(project);
    await expect(page.locator('#configuration-value-comparison')).toContainText('Default from code');
    await expect(page.locator('#configuration-adoption-status')).toContainText('still being adopted');
    await expect(page.locator('#configuration-editor-updated')).toContainText('Your draft has been kept');
    await expect(page.locator('[name="params[warning_items]"]')).toHaveValue('50');
    await page.setViewportSize({ width: 390, height: 844 });
    await checkpoint(page, testInfo, 'managed-policy-source-differences-offline');
    const saved = await assignment();
    expect(saved.params).toEqual(limits);
    expect(saved.observed_generation).not.toBe(saved.desired_generation);
    await page.locator('#configuration-editor-updated').getByRole('button', { name: 'Reload current values and discard draft' }).click();
    await expect(page.locator('#configuration-editor-updated')).toHaveCount(0);
    await expect(page.locator('[name="params[warning_items]"]')).toHaveValue('5');

    await page.locator('#configuration-origin').getByRole('link', { name: 'Project volume limits', exact: true }).click();
    await expect(page.locator('#managed-rule')).toContainText(project);
    await expect(page.locator('#configuration-rule-form')).toBeVisible();
    await page.setViewportSize({ width: 320, height: 740 });
    await checkpoint(page, testInfo, 'managed-rule-editable-320');
    await page.evaluate(() => window.liveSocket.disconnect());
    await expect(page.locator('[data-phx-main]')).not.toHaveClass(/phx-connected/);
    await page.evaluate(() => window.liveSocket.connect());
    await connected(page);
    await expect(page.locator('#managed-rule')).toContainText('Edit here or through Git');
    await expect(page.locator('#configuration-rule-form')).toBeVisible();

    await page.goto(`/checks/${stream.id}?return_to=${encodeURIComponent('/checks?search=volume&tab=all&view=list')}`);
    const originalResultURL = page.url();
    await page.getByRole('link', { name: 'Review configuration', exact: true }).click();
    await connected(page);
    await page.locator('#configuration-origin > summary').click();
    await page.locator('[name="params[warning_items]"]').fill('60');
    await page.locator('[name="params[critical_items]"]').fill('120');
    await page.getByRole('button', { name: 'Save settings for this check', exact: true }).click();
    await page.locator('#configuration-saved-actions').getByRole('link', {name: 'Back to result', exact: true}).click();
    await expect(page).toHaveURL(originalResultURL);
    await page.getByRole('link', {name: 'Review configuration', exact: true}).click();
    await page.locator('#configuration-origin > summary').click();
    await expect(page.locator('#configuration-under-exception')).toContainText('Project volume limits');
    await expect(page.locator('#configuration-value-comparison')).toContainText('Without exception');
    await checkpoint(page, testInfo, 'instance-exception-compares-source-and-project');
    await page.evaluate(() => window.liveSocket.disconnect());
    await expect(page.locator('[data-phx-main]')).not.toHaveClass(/phx-connected/);
    await page.evaluate(() => window.liveSocket.connect());
    await connected(page);
    await expect(page.locator('#configuration-under-exception')).toContainText(project);
    await page.getByRole('button', { name: 'Remove exception and use rules/defaults', exact: true }).click();
    await expect(page.locator('#exception-reset-preview')).toContainText('10');
    await page.getByRole('button', { name: 'Confirm removal', exact: true }).click();
    await expect(page.locator('#configuration-origin')).toContainText('From rule');
  } finally {
    await mode(request, { offline_installations: [] });
  }
  await expect.poll(async () => {
    const current = await assignment();
    return current.observed_generation === current.desired_generation;
  }, { timeout: 120_000 }).toBe(true);
  await expect(page.locator('#configuration-adoption-status')).toContainText('Saved version measured');
  await checkpoint(page, testInfo, 'project-policy-measured-after-reconnect');
  await policy(request, manifest([]));
  await expect.poll(async () => (await assignment()).params).toEqual(defaults);
  await expect(page.locator('#configuration-value-comparison')).toHaveCount(0);
});

test('adopting a UI rule preserves editing and removing policy retains an understandable page', async ({ page, request }, testInfo) => {
  const stream = await ready(request);
  const seeded = await request.get(`/api/v1/configuration/rules/seed/${stream.assignment_id}`);
  const proposal = { ...await seeded.json(), name: 'Adopted project limits', params: limits };
  const preview = await request.post('/api/v1/configuration/rules/preview', { data: { proposal } });
  expect(preview.ok(), await preview.text()).toBeTruthy();
  const reviewed = await preview.json();
  const response = await request.post('/api/v1/configuration/rules/apply', {
    data: { proposal: reviewed.proposal, review_token: reviewed.review_token },
  });
  expect(response.ok(), await response.text()).toBeTruthy();
  const saved = await response.json();
  await page.goto(`/configuration/rules/${saved.rule.id}`);
  await connected(page);
  await expect(page.locator('#configuration-rule-form')).toBeVisible();
  await page.locator('#rule-name').fill('An unsaved draft');
  await policy(request, manifest([rule({ adopt_rule_id: saved.rule.id, name: proposal.name })]));
  await expect(page.locator('#managed-rule')).toContainText(project);
  await expect(page.locator('#configuration-rule-form')).toBeVisible();
  await checkpoint(page, testInfo, 'adopted-rule-preserves-ui-editing');
  await page.goto('/configuration/rules');
  await expect(page.locator(`#rule-row-${saved.rule.id}`)).toContainText(`Project: ${project}`);
  await checkpoint(page, testInfo, 'rule-list-explains-project-ownership');
  await page.goto(`/configuration/rules/${saved.rule.id}`);
  await page.locator('#rule-param-warning_items').fill('6');
  await page.getByRole('button', {name: 'Preview rule', exact: true}).click();
  await page.getByRole('button', {name: 'Save rule', exact: true}).click();
  await expect.poll(async () => (await (await request.get(`/api/v1/configuration/rules/${saved.rule.id}`)).json()).params.warning_items).toBe(6);
  await page.goto('/configuration/history');
  await connected(page);
  await expect(page.locator('#configuration-repository-history')).toContainText('UI save');
  await page.getByRole('button', {name: /Inspect changes/}).first().click();
  await expect(page.locator('#configuration-change-detail')).toContainText('Warning at (items)');
  await expect(page.locator('#configuration-change-detail')).toContainText('Before: 5');
  await expect(page.locator('#configuration-change-detail')).toContainText('After: 6');
  await checkpoint(page, testInfo, 'automatic-ui-history-changed-fields');
  await page.setViewportSize({width: 390, height: 844});
  await page.getByText('Complete documents and scope', {exact: true}).click();
  await checkpoint(page, testInfo, 'automatic-ui-history-complete-scope-mobile');
  await page.goto(`/configuration/rules/${saved.rule.id}`);
  await policy(request, manifest([]));
  await expect(page.locator('#rule-notice')).toContainText('rule was removed');
  await expect(page.locator('#managed-rule')).toHaveCount(0);
  await checkpoint(page, testInfo, 'removed-policy-retains-explanation');
});
