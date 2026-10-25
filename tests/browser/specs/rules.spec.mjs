// Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
// SPDX-License-Identifier: Apache-2.0
import { test, expect } from '@playwright/test';
import { checkpoint, connected, keyboardFill, keyboardSubmit, mode, streams } from '../support/helpers.mjs';

test('durable rules are reviewable, retain drafts across reconnect and expose instance precedence', async ({ page, request }, testInfo) => {
  const errors = [];
  page.on('pageerror', (error) => errors.push(error.message));
  await expect.poll(async () => (await streams(request, { freshness: 'fresh' })).total,
    { timeout: 120_000 }).toBe(1);
  const stream = (await streams(request)).items[0];
  const assignmentID = stream.assignment_id;
  async function assignment() {
    const response = await request.get(`/api/v1/assignments/${assignmentID}`);
    expect(response.ok(), await response.text()).toBeTruthy();
    return response.json();
  }
  await page.goto('/configuration');
  await connected(page);
  await expect(page.locator('#configuration-adoption-summary')).not.toHaveAttribute('open');
  await expect(page.getByRole('heading', { name: 'Share settings across similar checks' })).toBeVisible();
  await page.setViewportSize({ width: 390, height: 844 });
  await checkpoint(page, testInfo, 'configuration-intent-before-installation-adoption');
  await page.locator('#new-shared-rule').click();
  await expect(page).toHaveURL(/\/configuration\/rules\/new$/);
  await expect(page.locator('#configuration-group-chooser')).toBeVisible();
  await page.getByLabel('Find check settings', { exact: true }).fill('no-such-settings');
  await page.getByRole('button', { name: 'Find groups', exact: true }).click();
  await expect(page.getByRole('heading', { name: 'No matching shared settings' })).toBeVisible();
  await page.getByLabel('Find check settings', { exact: true }).fill('');
  await page.getByRole('button', { name: 'Find groups', exact: true }).click();
  await page.getByRole('link', { name: 'Use these settings', exact: true }).click();
  await expect(page.locator('#rule-target-scope')).toHaveValue('all');
  await expect(page.locator('#rule-environment-scope')).toHaveValue('all');
  await checkpoint(page, testInfo, 'shared-rule-starts-with-explicit-group-wide-scope');
  await page.goto(`/checks/${stream.id}?return_to=${encodeURIComponent('/checks?search=volume&tab=all&view=list')}`);
  const originalResultURL = page.url();
  await page.getByRole('link', { name: 'Review configuration', exact: true }).click();
  await connected(page);
  await expect(page.locator('#configuration-origin')).not.toHaveAttribute('open');
  await expect(page.locator('#configuration-scope')).toContainText('Future checks are not included');
  await checkpoint(page, testInfo, 'result-settings-scope-390');
  await page.getByRole('link', { name: 'Configure similar checks', exact: true }).click();
  await expect(page.locator('#rule-target-key')).toHaveValue('volume:orders');
  await keyboardFill(page, page.locator('#rule-name'), 'Orders volume policy');
  await page.locator('#rule-param-warning_items').fill('5');
  await page.locator('#rule-param-critical_items').fill('10');
  await page.keyboard.press('Tab');
  await page.evaluate(() => window.liveSocket.disconnect());
  await expect(page.locator('[data-phx-main]')).not.toHaveClass(/phx-connected/);
  await page.evaluate(() => window.liveSocket.connect());
  await connected(page);
  await expect(page.locator('#rule-name')).toHaveValue('Orders volume policy');
  await expect(page.locator('#rule-param-warning_items')).toHaveValue('5');
  await expect(page.locator('#rule-param-critical_items')).toHaveValue('10');
  await page.setViewportSize({ width: 390, height: 844 });
  await checkpoint(page, testInfo, 'rules-draft-restored-after-websocket-reconnect');
  await keyboardSubmit(page, page.getByRole('button', { name: 'Preview rule', exact: true }));
  await expect(page.locator('#rule-preview-summary')).toContainText('1 checks reviewed');
  await expect(page.locator('#rule-preview .rule-values dt').first()).toContainText('(items)');
  await checkpoint(page, testInfo, 'rules-exact-values-preview-390');
  await page.setViewportSize({ width: 320, height: 740 });
  await checkpoint(page, testInfo, 'rules-complete-preview-320');
  expect(await page.locator('#rule-preview .rule-table-wrap').evaluate(
    (element) => element.scrollWidth <= element.clientWidth + 1,
  ), 'Proposed values must be readable without horizontal scrolling').toBe(true);
  await page.setViewportSize({ width: 390, height: 844 });

  await page.evaluate(() => window.liveSocket.disconnect());
  await expect(page.locator('[data-phx-main]')).not.toHaveClass(/phx-connected/);
  await page.evaluate(() => window.liveSocket.connect());
  await connected(page);
  await expect(page.locator('#rule-name')).toHaveValue('Orders volume policy');
  await expect(page.locator('#rule-param-critical_items')).toHaveValue('10');
  await expect(page.locator('#rule-save')).toHaveCount(0);
  await page.getByRole('button', { name: 'Preview rule', exact: true }).click();
  await expect(page.locator('#rule-preview-summary')).toContainText('1 checks reviewed');

  // A concurrent instance edit invalidates the review without discarding our draft.
  const before = await assignment();
  const concurrent = await request.put(`/api/v1/assignments/${assignmentID}`, {
    data: { revision: before.revision, params: { warning_items: 60, critical_items: 120 } },
  });
  expect(concurrent.ok(), await concurrent.text()).toBeTruthy();
  await page.getByRole('button', { name: 'Save rule', exact: true }).click();
  await expect(page.locator('#rule-error')).toBeVisible();
  await expect(page.locator('#rule-name')).toHaveValue('Orders volume policy');
  await expect(page.locator('#rule-param-critical_items')).toHaveValue('10');
  await page.getByRole('button', { name: 'Preview rule', exact: true }).click();
  await expect(page.locator('#rule-preview-summary')).toContainText('1 instance exceptions');
  await page.getByRole('button', { name: 'Save rule', exact: true }).click();
  await expect(page).toHaveURL(/\/configuration\/rules\/[0-9a-f-]{36}(?:\?|$)/);
  await expect(page.locator('#rule-saved-change')).toContainText('No check received a new desired version');
  await page.evaluate(() => window.liveSocket.disconnect());
  await expect(page.locator('[data-phx-main]')).not.toHaveClass(/phx-connected/);
  await page.evaluate(() => window.liveSocket.connect());
  await connected(page);
  await expect(page.locator('#rule-saved-change')).toContainText('No check received a new desired version');
  const ruleURL = page.url();
  await page.getByRole('link', {name: 'Back to result', exact: true}).click();
  await expect(page).toHaveURL(originalResultURL);
  await page.getByRole('link', {name: 'Back to results', exact: true}).click();
  await expect(page.locator('#inventory-search')).toHaveValue('volume');
  await page.goto('/configuration/rules');
  await expect(page.locator('[id^="rule-row-"]')).toHaveCount(1);
  await checkpoint(page, testInfo, 'rules-list-shows-stable-target-policy');
  await page.goto(`/configuration/${assignmentID}`);
  await expect(page.locator('#configuration-origin')).toContainText('instance exception');

  await mode(request, { offline_installations: [stream.runner_id] });
  try {
    await page.getByRole('button', { name: 'Remove exception and use rules/defaults', exact: true }).click();
    await expect(page.locator('#exception-reset-preview')).toBeVisible();
    await expect(page.locator('#exception-reset-preview dt').first()).toContainText('(items)');
    await checkpoint(page, testInfo, 'rules-review-return-to-policy');
    await page.getByRole('button', { name: 'Confirm removal', exact: true }).click();
    await expect.poll(async () => (await assignment()).configuration_origin.kind).toBe('rule');
    const saved = await assignment();
    expect(saved.params).toEqual({ warning_items: 5, critical_items: 10 });
    expect(saved.observed_generation).not.toBe(saved.desired_generation);
    await expect(page.locator('#configuration-origin')).toContainText('Orders volume policy');
    await expect(page.locator('#configuration-adoption-status')).toContainText('still being adopted');
    await expect(page.locator('#configuration-adoption-versions')).not.toHaveAttribute('open');
    const statusBounds = await page.locator('#configuration-adoption-status').boundingBox();
    const formBounds = await page.locator(`#form-${assignmentID}`).boundingBox();
    expect(statusBounds.y + statusBounds.height).toBeLessThanOrEqual(formBounds.y);
    await page.locator('#configuration-adoption-versions > summary').click();
    await expect(page.getByRole('list', { name: 'Configuration adoption stages' })).toBeVisible();
    await page.evaluate(() => window.liveSocket.disconnect());
    await expect(page.locator('[data-phx-main]')).not.toHaveClass(/phx-connected/);
    await page.evaluate(() => window.liveSocket.connect());
    await connected(page);
    await expect(page.locator('#configuration-adoption-versions')).toHaveAttribute('open', '');
    await page.locator('#configuration-adoption-versions > summary').click();
    await checkpoint(page, testInfo, 'rules-saved-values-wait-for-offline-runner');
    const configurationURL = page.url();
    await page.locator('#configuration-adoption-status').getByRole('link', { name: 'check runner status', exact: true }).click();
    await expect(page).toHaveURL(new RegExp(`/runners/${stream.runner_id}(?:\\?|$)`));
    await expect(page.locator('#runner-detail')).toBeVisible();
    await expect(page.locator('#runner-detail')).toContainText(stream.runner_id);
    await page.setViewportSize({ width: 320, height: 740 });
    await checkpoint(page, testInfo, 'pending-configuration-selected-runner-320');
    await page.goto(configurationURL);
    await connected(page);
  } finally {
    await mode(request, { offline_installations: [] });
  }
  await expect.poll(async () => {
    const row = await assignment();
    return row.observed_generation === row.desired_generation && row.current.health === 'CRIT';
  }, { timeout: 90_000 }).toBe(true);
  await expect(page.locator('#configuration-adoption-status')).toContainText('Saved version measured');

  // Disabling is also a reviewed policy change, then fresh measurement confirms fallback.
  await page.goto(ruleURL);
  await mode(request, { offline_installations: [stream.runner_id] });
  try {
    await page.locator('#rule-enabled').selectOption('false');
    await page.getByRole('button', { name: 'Preview rule', exact: true }).click();
    await expect(page.locator('#rule-preview-summary')).toContainText('1 configurations will change');
    await page.getByRole('button', { name: 'Save rule', exact: true }).click();
    await expect(page.locator('#rule-saved-change-summary')).toContainText('1 waiting for runner');
    await page.evaluate(() => window.liveSocket.disconnect());
    await expect(page.locator('[data-phx-main]')).not.toHaveClass(/phx-connected/);
    await page.evaluate(() => window.liveSocket.connect());
    await connected(page);
    await expect(page.locator('#rule-saved-change-summary')).toContainText('1 waiting for runner');
    await page.locator('#rule-saved-change-details > summary').click();
    await page.setViewportSize({ width: 320, height: 740 });
    await checkpoint(page, testInfo, 'rules-exact-saved-change-offline-after-reconnect');
  } finally {
    await mode(request, { offline_installations: [] });
  }
  await expect.poll(async () => {
    const row = await assignment();
    return row.configuration_origin.kind === 'source' && row.params.warning_items === 50
      && row.observed_generation === row.desired_generation && row.current.health === 'OK';
  }, { timeout: 90_000 }).toBe(true);
  await expect(page.locator('#rule-saved-change-summary')).toContainText('1 measured');
  await checkpoint(page, testInfo, 'rules-exact-saved-change-measured');
  await page.goto('/configuration/rules');
  await expect(page.locator('[id^="rule-row-"]')).toContainText('Disabled');
  await page.setViewportSize({ width: 1280, height: 900 });
  await checkpoint(page, testInfo, 'rules-disabled-policy-preserved');
  expect(errors).toEqual([]);
});
