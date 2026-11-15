import { unpackAPI } from '../support/helpers.mjs';
// Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
// SPDX-License-Identifier: Apache-2.0
import { test, expect } from '@playwright/test';
import { checkpoint, connected, keyboardFill, keyboardSubmit, mode, streams, searchFilters } from '../support/helpers.mjs';

test('durable rules are reviewable, retain drafts across reconnect and expose instance precedence', async ({ page, request }, testInfo) => {
  const errors = [];
  page.on('pageerror', (error) => errors.push(error.message));
  await expect.poll(async () => (await streams(request, { freshness: 'fresh' })).total,
    { timeout: 120_000 }).toBe(1);
  const stream = (await streams(request)).items[0];
  const assignmentID = stream.assignment_id;
  async function assignment() {
    const response = await request.get(`/api/v1/assignments/${assignmentID}/configuration`);
    expect(response.ok(), await response.text()).toBeTruthy();
    return response.json().then(unpackAPI);
  }
  await page.goto('/configuration');
  await connected(page);
  await expect(page.locator('#configuration-adoption-summary')).toBeVisible();
  await expect(page.locator('#configuration-scope-guidance')).toContainText('shared rule');
  await page.setViewportSize({ width: 390, height: 844 });
  await checkpoint(page, testInfo, 'configuration-intent-before-installation-adoption');
  await page.locator('#new-shared-rule').click();
  await expect(page).toHaveURL(/\/configuration\/rules\/new$/);
  await expect(page.locator('#configuration-group-chooser')).toBeVisible();
  await page.getByLabel('Find check settings', { exact: true }).fill('no-such-settings');
  await page.getByLabel('Find check settings', { exact: true }).press('Enter');
  await expect(page.getByText(/No matching shared settings\./)).toBeVisible();
  await page.getByLabel('Find check settings', { exact: true }).fill('');
  await page.getByLabel('Find check settings', { exact: true }).press('Enter');
  await page.getByRole('link', { name: /^Use settings from / }).click();
  await expect(page.locator('#rule-target-scope')).toHaveValue('all');
  await expect(page.locator('#rule-environment-scope')).toHaveValue('all');
  await checkpoint(page, testInfo, 'shared-rule-starts-with-explicit-group-wide-scope');
  await page.goto(`/results/${stream.id}/full?return_to=${encodeURIComponent('/checks?search=volume')}`);
  await page.getByRole('link', { name: 'View check configuration', exact: true }).click();
  await connected(page);
  await expect(page.locator('#configuration-origin')).toBeVisible();
  await expect(page.locator('#delegated-parameters')).toContainText('an instance exception for this scheduled check');
  await expect(page.locator('#delegated-parameters')).toContainText('it does not follow a replacement observer');
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
  await expect(page.locator('#rule-preview-summary')).toContainText('1 check reviewed');
  await expect(page.locator('#rule-preview [headers=rule-review-proposed] th').first()).toContainText('(items)');
  await checkpoint(page, testInfo, 'rules-exact-values-preview-390');
  await page.setViewportSize({ width: 320, height: 740 });
  await checkpoint(page, testInfo, 'rules-complete-preview-320');
  const previewLayout = await page.locator('#rule-preview').evaluate(element => {
    const boundary = element.getBoundingClientRect();
    const metrics = node => {
      const box = node.getBoundingClientRect();
      const style = getComputedStyle(node);
      return {tag: node.tagName, id: node.id, class: node.className,
        client: node.clientWidth, scroll: node.scrollWidth, rectWidth: box.width,
        left: box.left, right: box.right, display: style.display, width: style.width,
        tableLayout: style.tableLayout, whiteSpace: style.whiteSpace,
        text: node.textContent.trim().slice(0, 100)};
    };
    return {card: metrics(element), tables: [...element.querySelectorAll('table,tbody,tr,th,td')].map(metrics),
      overflowing: [...element.querySelectorAll('*')].filter(node => {
        const box = node.getBoundingClientRect();
        return box.width && (node.scrollWidth > node.clientWidth + 1 || box.left < boundary.left - 1 || box.right > boundary.right + 1);
      }).map(metrics)};
  });
  await testInfo.attach('rule-preview-layout-320', {body: JSON.stringify(previewLayout, null, 2), contentType: 'application/json'});
  await testInfo.attach('rule-preview-card-320', {body: await page.locator('#rule-preview').screenshot(), contentType: 'image/png'});
  expect(previewLayout.card.scroll, 'Proposed values must be readable without horizontal scrolling')
    .toBeLessThanOrEqual(previewLayout.card.client + 1);
  await page.setViewportSize({ width: 390, height: 844 });

  await page.evaluate(() => window.liveSocket.disconnect());
  await expect(page.locator('[data-phx-main]')).not.toHaveClass(/phx-connected/);
  await page.evaluate(() => window.liveSocket.connect());
  await connected(page);
  await expect(page.locator('#rule-name')).toHaveValue('Orders volume policy');
  await expect(page.locator('#rule-param-critical_items')).toHaveValue('10');
  await expect(page.locator('#rule-save')).toHaveCount(0);
  await page.getByRole('button', { name: 'Preview rule', exact: true }).click();
  await expect(page.locator('#rule-preview-summary')).toContainText('1 check reviewed');

  // A concurrent instance edit invalidates the review without discarding our draft.
  const before = await assignment();
  const concurrent = await request.put(`/api/v1/assignments/${assignmentID}/configuration`, {
    data: { revision: before.revision, params: { warning_items: 60, critical_items: 120 } },
  });
  expect(concurrent.ok(), await concurrent.text()).toBeTruthy();
  await page.getByRole('button', { name: 'Save rule', exact: true }).click();
  await expect(page.locator('#rule-error')).toBeVisible();
  await expect(page.locator('#rule-name')).toHaveValue('Orders volume policy');
  await expect(page.locator('#rule-param-critical_items')).toHaveValue('10');
  await page.getByRole('button', { name: 'Preview rule', exact: true }).click();
  await expect(page.locator('#rule-preview-summary')).toContainText('1 instance exception');
  await page.getByRole('button', { name: 'Save rule', exact: true }).click();
  await expect(page).toHaveURL(/\/configuration\/rules\/[0-9a-f-]{36}(?:\?|$)/);
  await expect(page.locator('#rule-saved-change')).toContainText('No check received a new desired version');
  await page.evaluate(() => window.liveSocket.disconnect());
  await expect(page.locator('[data-phx-main]')).not.toHaveClass(/phx-connected/);
  await page.evaluate(() => window.liveSocket.connect());
  await connected(page);
  await expect(page.locator('#rule-saved-change')).toContainText('No check received a new desired version');
  const ruleURL = page.url();
  await page.getByRole('link', {name: 'Back to investigation', exact: true}).click();
  await expect(page).toHaveURL(new RegExp(`/configuration/${assignmentID}(?:\\?|$)`));
  await expect(page.locator('#configuration-origin')).toContainText('instance exception');
  await page.getByRole('link', {name: '← Back to result', exact: true}).click();
  await expect(page).toHaveURL(url => url.pathname === `/results/${stream.id}/full`);
  await expect(page.locator('#preview-result-page .preview-result-measurement')).toBeVisible();
  await page.getByRole('link', {name: '← Back to checks', exact: true}).click();
  await expect(page).toHaveURL(url => url.pathname === '/checks' && url.searchParams.get('search') === 'volume');
  await expect(page.locator('.preview-search-token')).toContainText('volume');
  await expect(page.locator(`#result-row-${stream.id}`)).toBeVisible();
  await page.goto('/configuration/rules');
  await expect(page.locator('[id^="rule-row-"]')).toHaveCount(1);
  await checkpoint(page, testInfo, 'rules-list-shows-stable-target-policy');
  await page.goto(`/configuration/${assignmentID}`);
  await expect(page.locator('#configuration-origin')).toContainText('instance exception');

  await mode(request, { offline_installations: [stream.runner_id] });
  try {
    await page.getByRole('button', { name: 'Remove exception and use rules/defaults', exact: true }).click();
    await expect(page.locator('#exception-reset-preview')).toBeVisible();
    await expect(page.locator('#exception-reset-preview th').first()).toContainText('(items)');
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
    await expect(page.getByRole('table', { name: 'Configuration versions' })).toBeVisible();
    await page.evaluate(() => window.liveSocket.disconnect());
    await expect(page.locator('[data-phx-main]')).not.toHaveClass(/phx-connected/);
    await page.evaluate(() => window.liveSocket.connect());
    await connected(page);
    await expect(page.locator('#configuration-adoption-versions')).toHaveAttribute('open', '');
    await page.locator('#configuration-adoption-versions > summary').click();
    await checkpoint(page, testInfo, 'rules-saved-values-wait-for-offline-runner');
    const configurationURL = page.url();
    await page.locator('#configuration-adoption-status').getByRole('link', { name: 'check runner status', exact: true }).click();
    await expect(page.locator('#overview-panel')).toContainText(stream.runner_id);
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
    await expect(page.locator('#rule-preview-summary')).toContainText('1 configuration will change');
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
