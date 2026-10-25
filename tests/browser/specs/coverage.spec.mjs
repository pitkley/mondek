// Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
// SPDX-License-Identifier: Apache-2.0
import { test, expect } from '@playwright/test';
import { checkpoint, connected, incidentNavigation, keyboardSubmit, mode, sectionTabs } from '../support/helpers.mjs';

async function coverage(request, filters = {}) {
  const response = await request.get(`/api/v1/coverage?${new URLSearchParams(filters)}`);
  expect(response.ok(), await response.text()).toBeTruthy();
  return response.json();
}

async function observers(request, id) {
  const response = await request.get(`/api/v1/coverage/${id}/observers`);
  expect(response.ok(), await response.text()).toBeTruthy();
  return (await response.json()).items;
}

async function scopeInState(request, predicate, status) {
  let scope;
  await expect.poll(async () => {
    scope = (await coverage(request)).items.find(predicate);
    return scope?.status;
  }, { timeout: 90_000 }).toBe(status);
  return scope;
}

async function reset(request) {
  await mode(request, { webhook: 'ok', offline_installations: [], grouped_samples: {
    'coverage-service-a-staging/elasticsearch': { available: true, used_percent: 40, sample_age_seconds: 0 },
    'coverage-service-b-staging/elasticsearch': { available: true, used_percent: 40, sample_age_seconds: 0 },
  } });
  await expect.poll(async () => (await coverage(request)).total, { timeout: 90_000 }).toBe(5);
  return scopeInState(request, (scope) => scope.environment === 'staging', 'observed');
}

async function filtersFit(page) {
  const controls = await page.locator('#coverage-filters').evaluate((form) => {
    const fields = [...form.querySelectorAll('input:not([type="hidden"]), select, button, a')].map((element) => {
      const box = element.getBoundingClientRect();
      return { name: element.id || element.textContent, top: box.top, bottom: box.bottom, height: box.height, left: box.left, right: box.right };
    });
    return { fields, width: document.documentElement.clientWidth };
  });
  for (const field of controls.fields) {
    expect(field.height, `${field.name} control height`).toBeCloseTo(44, 0);
    expect(field.left).toBeGreaterThanOrEqual(0);
    expect(field.right).toBeLessThanOrEqual(controls.width + 1);
  }
  const button = controls.fields.find((field) => field.name === 'Apply filters');
  const sameRow = controls.fields.filter((field) => Math.abs(field.top - button.top) < 44);
  for (const field of sameRow) {
    expect(field.top, `${field.name} aligns with Apply filters`).toBeCloseTo(button.top, 0);
    expect(field.bottom).toBeCloseTo(button.bottom, 0);
  }
}

test('a never-installed node and excluded environment remain visible through filtering, inspection and reconnect', async ({ page, request }, testInfo) => {
  await reset(request);
  await page.goto('/coverage');
  await connected(page);
  await sectionTabs(page, 'Coverage', 'Coverage views', 'Intended results');
  await incidentNavigation(page, request);
  await expect(page.locator('#coverage-scopes')).toContainText('5 matching intended results');
  await expect(page.locator('#coverage-scopes .coverage-scope')).toHaveCount(5);
  await filtersFit(page);
  await checkpoint(page, testInfo, 'declared-scopes-desktop');
  await page.locator('#coverage-environment').fill('production');
  await page.locator('#coverage-status').selectOption('missing');
  await keyboardSubmit(page, page.locator('#coverage-filters button'));
  await expect(page.locator('#coverage-scopes .coverage-scope')).toHaveCount(2);
  const missing = (await coverage(request, { environment: 'production', status: 'missing' })).items;
  const node = missing.find((scope) => scope.source_key === 'root-disk-node-b');
  expect(node).toBeTruthy();
  expect(node.counts.selected).toBe(0);
  const nodeDeclarations = await observers(request, node.id);
  expect(nodeDeclarations).toHaveLength(3);
  expect(nodeDeclarations.every((observer) => !observer.selected && !observer.assignment_id)).toBe(true);
  await page.locator(`[data-scope-id="${node.id}"] h3 a`).click();
  await connected(page);
  await expect(page.locator('#coverage-scope-detail')).toContainText('No selected runner');
  await expect(page.locator('#coverage-observers .coverage-scope')).toHaveCount(3);
  await expect(page.locator('#coverage-observers')).not.toContainText('Inspect result');
  await page.locator('#coverage-agent-prompts-coverage summary').click();
  await expect(page.locator('#coverage-agent-prompts-coverage-text')).toHaveValue(/root-disk-node-b/);
  await keyboardSubmit(page, page.locator('#coverage-agent-prompts-coverage-select'));
  expect(await page.locator('#coverage-agent-prompts-coverage-text').evaluate((node) => node.selectionEnd - node.selectionStart)).toBeGreaterThan(100);
  await page.evaluate(() => window.liveSocket.disconnect());
  await expect(page.locator('[data-phx-main]')).not.toHaveClass(/phx-connected/);
  await page.evaluate(() => window.liveSocket.connect());
  await connected(page);
  await expect(page.locator('a.back')).toHaveAttribute('href', '/coverage?environment=production&status=missing');
  await checkpoint(page, testInfo, 'missing-node-details');
  await page.setViewportSize({ width: 320, height: 760 });
  await checkpoint(page, testInfo, 'missing-node-narrow');
  await page.locator('a.back').click();
  await expect(page.locator('#coverage-environment')).toHaveValue('production');
  await expect(page.locator('#coverage-status')).toHaveValue('missing');
  await filtersFit(page);
  await checkpoint(page, testInfo, 'missing-scopes-narrow');
  await page.goto('/coverage/diagnostics');
  await connected(page);
  await sectionTabs(page, 'Coverage', 'Coverage views', 'Unresolved declarations');
  await incidentNavigation(page, request);
  await expect(page.locator('#coverage-diagnostics')).toContainText('2 unresolved declarations');
  await checkpoint(page, testInfo, 'unbound-declarations-narrow');
  await page.getByRole('navigation', { name: 'Coverage views' }).getByRole('link', { name: 'Runner declarations', exact: true }).click();
  await connected(page);
  await sectionTabs(page, 'Coverage', 'Coverage views', 'Runner declarations');
  await incidentNavigation(page, request);
  await expect(page.locator('#coverage-publishers')).toContainText('3 source publications');
  await expect(page.locator('#coverage-publishers .badge')).toHaveText(['Declarations confirmed', 'Declarations confirmed', 'Declarations confirmed']);
  await checkpoint(page, testInfo, 'source-publications-narrow');
  await page.reload();
  await connected(page);
  await page.evaluate(() => window.liveSocket.disconnect());
  await expect(page.locator('[data-phx-main]')).not.toHaveClass(/phx-connected/);
  await page.evaluate(() => window.liveSocket.connect());
  await connected(page);
  await sectionTabs(page, 'Coverage', 'Coverage views', 'Runner declarations');
  await incidentNavigation(page, request);
  await page.setViewportSize({ width: 390, height: 844 });
  await checkpoint(page, testInfo, 'coverage-section-tabs-after-reload-reconnect-390');
  await page.getByRole('navigation', { name: 'Coverage views' }).getByRole('link', { name: 'Intended results', exact: true }).click();
  await connected(page);
  await sectionTabs(page, 'Coverage', 'Coverage views', 'Intended results');
});

test('fresh Critical evidence remains covered and independent collection loss is visible without hiding the failure', async ({ page, request }, testInfo) => {
  let staging = await reset(request);
  await mode(request, { grouped_samples: { 'coverage-service-a-staging/elasticsearch': { used_percent: 96 } } });
  let failing;
  await expect.poll(async () => {
    failing = (await observers(request, staging.id)).find((observer) => observer.current?.health === 'CRIT');
    return failing?.measurement_state;
  }, { timeout: 60_000 }).toBe('fresh');
  staging = await scopeInState(request, (scope) => scope.id === staging.id, 'observed');
  expect(staging.counts.fresh).toBe(2);
  await page.goto(`/coverage/${staging.id}`);
  await connected(page);
  await expect(page.locator('#coverage-scope-detail')).toContainText('Fresh measurements available');
  await expect(page.locator('#coverage-observers')).toContainText('Last measured health: Critical');
  await incidentNavigation(page, request);
  await checkpoint(page, testInfo, 'critical-is-observed');
  await mode(request, { grouped_samples: { 'coverage-service-b-staging/elasticsearch': { available: false } } });
  staging = await scopeInState(request, (scope) => scope.id === staging.id, 'partial');
  expect(staging.counts.fresh).toBe(1);
  expect(staging.counts.unavailable).toBe(1);
  await expect(page.locator('#coverage-scope-detail')).toContainText('Partial runner coverage');
  await expect(page.locator('#coverage-observers')).toContainText('Collection unavailable');
  await page.locator(`[data-runner-id="${failing.runner_id}"]`).getByRole('link', { name: 'Inspect result', exact: true }).click();
  await connected(page);
  await expect(page.getByRole('link', { name: 'Back to coverage', exact: true })).toBeVisible();
  await page.getByRole('link', { name: 'Back to coverage', exact: true }).click();
  await expect(page).toHaveURL(new RegExp(`/coverage/${staging.id}$`));
  const coverageURL = page.url();
  await page.locator('#coverage-observers').getByRole('link', {name: 'Investigate measurement', exact: true}).click();
  await expect(page.locator('#investigation-finding')).toContainText('Collection unavailable');
  await page.getByRole('link', {name: 'Full status for this runner', exact: true}).click();
  await page.locator('a.back').click();
  await expect(page.locator('#investigation-finding')).toContainText('Collection unavailable');
  await page.getByRole('link', {name: '← Back to coverage', exact: true}).click();
  await expect(page).toHaveURL(coverageURL);
  await page.setViewportSize({ width: 320, height: 760 });
  await checkpoint(page, testInfo, 'partial-observers-narrow');
  await reset(request);
  await expect(page.locator('#coverage-scope-detail')).toContainText('Fresh measurements available');
  await expect(page.locator('#coverage-observers')).not.toContainText('Last measured health: Critical');
  await checkpoint(page, testInfo, 'independent-observers-restored');
});
