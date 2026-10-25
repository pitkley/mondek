// Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
// SPDX-License-Identifier: Apache-2.0
import { test, expect } from '@playwright/test';
import {
  checkpoint, connected, fixtureURL, keyboardFill, keyboardSubmit, mode, snapshot, streams,
} from '../support/helpers.mjs';

async function configurations(request) {
  const rows = [];
  for (let page = 1; page <= 5; page += 1) {
    const response = await request.get(`/api/v1/configuration?page=${page}&page_size=100`);
    expect(response.ok(), await response.text()).toBeTruthy();
    const result = await response.json();
    expect(result.total).toBe(500);
    rows.push(...result.items);
  }
  expect(new Set(rows.map((row) => row.id)).size).toBe(500);
  return rows;
}

async function postBulk(request, action, data) {
  const response = await request.post(`/api/v1/configuration/bulk/${action}`, { data });
  expect(response.ok(), await response.text()).toBeTruthy();
  return response.json();
}

async function selectAll(page) {
  await expect(page.locator('#bulk-selection-count')).toHaveCount(0);
  await expect(page.locator('[id^="bulk-select-"]').first()).not.toBeChecked();
  await page.locator('[id^="bulk-select-"]').first().check();
  await expect(page.locator('#bulk-selection-count')).toContainText('1 selected');
  await page.getByRole('button', { name: 'Add all compatible matches', exact: true }).click();
  await expect(page.locator('#bulk-selection-count')).toContainText('500 selected');
  await page.getByRole('button', { name: 'Review selected checks', exact: true }).click();
  await expect(page.locator('#bulk-editor')).toBeVisible();
}

async function activeStepBeforeInventory(page, selector) {
  const step = await page.locator(selector).boundingBox();
  const inventory = await page.locator('#bulk-instance-inventory').boundingBox();
  expect(step, 'The active configuration step must be visible').not.toBeNull();
  expect(inventory, 'Inventory remains available after the active step').not.toBeNull();
  expect(step.y + step.height).toBeLessThanOrEqual(inventory.y);
}

test('500 delegated checks can be reviewed and saved together without concealing individual adoption', async ({ page, request, context }, testInfo) => {
  const errors = [];
  page.on('pageerror', (error) => errors.push(error.message));
  let socketCount = 0;
  let socketClosed = 0;
  page.on('websocket', (socket) => {
    if (new URL(socket.url()).pathname === '/live/websocket') {
      socketCount += 1;
      socket.on('close', () => { socketClosed += 1; });
    }
  });
  await expect.poll(async () => (await streams(request, { freshness: 'fresh' })).total,
    { timeout: 240_000 }).toBe(500);
  const before = await configurations(request);
  const runnerID = before[0].runner_id;
  expect(before.every((row) => row.parameter_contract === 'export.minimum-bytes.v1')).toBe(true);
  await page.goto('/configuration');
  await expect(page.locator('[id^="configuration-row-"]')).toHaveCount(50);
  await page.locator('#new-shared-rule').click();
  await expect(page.locator('.configuration-group')).toHaveCount(1);
  await expect(page.locator('.configuration-group')).toContainText('500 scheduled checks');
  await page.getByRole('link', { name: 'Use these settings', exact: true }).click();
  await expect(page.locator('#rule-environment-scope')).toHaveValue('all');
  await expect(page.locator('#rule-target-scope')).toHaveValue('all');
  await page.getByRole('button', { name: 'Preview rule', exact: true }).click();
  await expect(page.locator('#rule-preview-summary')).toContainText('500 checks reviewed');
  await expect(page.locator('#rule-preview tbody tr')).toHaveCount(25);
  await checkpoint(page, testInfo, 'shared-rule-discovery-reviews-500-existing-checks');
  await page.goto('/configuration');
  await connected(page);
  await page.locator('[id^="bulk-select-"]').first().check();
  await expect(page.locator('#bulk-selection-count')).toContainText('1 selected');
  const firstPageCheck = await page.locator('[id^="bulk-select-"]').first().getAttribute('id');
  await page.getByRole('link', { name: 'Next', exact: true }).click();
  await expect(page).toHaveURL(/(?:\?|&)page=2(?:&|$)/);
  await expect(page.locator('[id^="bulk-select-"]').first()).not.toHaveAttribute('id', firstPageCheck);
  await expect(page.locator('#bulk-selection-count')).toContainText('1 selected');
  await page.locator('[id^="bulk-select-"]').first().check();
  await expect(page.locator('#bulk-selection-count')).toContainText('2 selected');
  await page.getByRole('button', { name: 'Add all compatible matches', exact: true }).click();
  await expect(page.locator('#bulk-selection-count')).toContainText('500 selected');
  await checkpoint(page, testInfo, 'bulk-fixed-selection-across-pages');
  await page.getByRole('button', { name: 'Review selected checks', exact: true }).click();
  const critical = page.locator('#bulk-param-critical_min_bytes');
  const warning = page.locator('#bulk-param-warn_min_bytes');
  await critical.fill('15');
  await warning.fill('12');
  await keyboardSubmit(page, page.getByRole('button', { name: 'Preview changes', exact: true }));
  await expect(page.locator('#bulk-error')).toBeVisible();
  await critical.fill('2');
  await warning.fill('12');
  await page.keyboard.press('Tab');
  const socketsBefore = socketCount;
  await page.evaluate(() => window.liveSocket.disconnect());
  await expect.poll(() => socketClosed).toBeGreaterThan(0);
  await page.evaluate(() => window.liveSocket.connect());
  await expect.poll(() => socketCount).toBeGreaterThan(socketsBefore);
  await connected(page);
  await expect(page.locator('#bulk-selection-count')).toContainText('500 selected');
  await expect(critical).toHaveValue('2');
  await expect(warning).toHaveValue('12');
  await expect(page.getByRole('button', { name: 'Save reviewed checks', exact: true })).toHaveCount(0);
  await page.setViewportSize({ width: 390, height: 844 });
  await activeStepBeforeInventory(page, '#bulk-editor');
  await checkpoint(page, testInfo, 'bulk-draft-after-real-reconnect-390');
  await page.getByRole('button', { name: 'Preview changes', exact: true }).click();
  await expect(page.locator('#bulk-preview-summary')).toContainText('500 checks will change');
  await expect(page.locator('[id^="bulk-review-"]')).toHaveCount(25);
  await activeStepBeforeInventory(page, '#bulk-preview');
  const firstReview = await page.locator('[id^="bulk-review-"]').evaluateAll((rows) => rows.map((row) => row.id));
  await page.getByRole('button', { name: 'Next review page', exact: true }).click();
  await expect.poll(async () => {
    const secondReview = await page.locator('[id^="bulk-review-"]').evaluateAll((rows) => rows.map((row) => row.id));
    return secondReview.length === 25 && secondReview.every((id) => !firstReview.includes(id));
  }).toBe(true);
  await checkpoint(page, testInfo, 'bulk-exact-paged-preview-390');

  // Another operator changes one check after this review. None of our 500 may save.
  const changed = before[0];
  const concurrent = await request.put(`/api/v1/assignments/${changed.id}`, {
    data: { revision: changed.revision, params: { critical_min_bytes: 1, warn_min_bytes: 12 } },
  });
  expect(concurrent.ok(), await concurrent.text()).toBeTruthy();
  await page.getByRole('button', { name: 'Save reviewed checks', exact: true }).click();
  await expect(page.locator('#bulk-error')).toContainText('changed since review');
  const afterConflict = await configurations(request);
  expect(afterConflict.filter((row) => row.params.critical_min_bytes === 2)).toHaveLength(0);
  expect(afterConflict.filter((row) => row.revision !== before.find((old) => old.id === row.id).revision))
    .toHaveLength(1);
  await checkpoint(page, testInfo, 'bulk-concurrent-edit-preserves-all-other-checks');

  await page.getByRole('button', { name: 'Clear selection and draft', exact: true }).click();
  await selectAll(page);
  await expect(warning).toBeDisabled();
  await page.locator('input[type="checkbox"][name="resolved[warn_min_bytes]"]').check();
  await warning.fill('12');
  await critical.fill('2');
  await mode(request, { offline_installations: [runnerID] });
  const returning = await context.newPage();
  returning.on('pageerror', (error) => errors.push(error.message));
  await returning.setViewportSize({ width: 320, height: 740 });
  try {
    await page.getByRole('button', { name: 'Preview changes', exact: true }).click();
    await page.getByRole('button', { name: 'Save reviewed checks', exact: true }).click();
    await expect(page.locator('#bulk-progress')).toBeVisible();
    await expect(page.locator('#bulk-notice')).toContainText('Saved 500 checks together');
    await expect(page.locator('#bulk-progress')).toContainText('500 pending');
    await activeStepBeforeInventory(page, '#bulk-progress');
    const saved = await configurations(request);
    expect(saved.every((row) => row.params.critical_min_bytes === 2 && row.params.warn_min_bytes === 12)).toBe(true);
    expect(saved.every((row) => row.revision === afterConflict.find((old) => old.id === row.id).revision + 1)).toBe(true);
    await checkpoint(page, testInfo, 'bulk-saved-while-runner-offline');
    // A later visit has no receipt from the original form. Its URL-persistent
    // stage filter must still expose all waiting desired configurations.
    await returning.goto('/configuration');
    await connected(returning);
    await returning.getByLabel('Configuration adoption', { exact: true }).selectOption('saved');
    await expect(returning).toHaveURL(/configuration_stage=saved/);
    await expect(returning.locator('#configuration-adoption-summary strong')).toHaveText('500 matching');
    await returning.reload();
    await connected(returning);
    await expect(returning.getByLabel('Configuration adoption', { exact: true })).toHaveValue('saved');
    await expect(returning.locator('[id^="configuration-row-"]')).toHaveCount(50);
    await expect(returning.locator('#configuration-adoption-summary strong')).toHaveText('500 matching');
    await checkpoint(returning, testInfo, 'bulk-return-to-waiting-configurations-320');
  } finally {
    await mode(request, { offline_installations: [] });
  }
  await expect(page.locator('#bulk-progress')).toContainText('500 measured', { timeout: 240_000 });
  await expect(returning.locator('#configuration-adoption-summary strong')).toHaveText('0 matching');
  await returning.getByLabel('Configuration adoption', { exact: true }).selectOption('measured');
  await expect(returning).toHaveURL(/configuration_stage=measured/);
  await expect(returning.locator('#configuration-adoption-summary strong')).toHaveText('500 matching');
  await expect(returning.locator('[id^="configuration-row-"]')).toHaveCount(50);
  await checkpoint(returning, testInfo, 'bulk-return-to-measured-configurations-320');
  await returning.close();
  const receipts = JSON.parse(await page.locator('input[name="_receipts"]').inputValue());
  expect(receipts).toHaveLength(500);
  await testInfo.attach('exact-saved-configuration-receipts', {
    body: JSON.stringify(receipts, null, 2), contentType: 'application/json',
  });
  await page.setViewportSize({ width: 320, height: 740 });
  await activeStepBeforeInventory(page, '#bulk-progress');
  await checkpoint(page, testInfo, 'bulk-all-saved-versions-measured-320');

  // Saving identical values does not manufacture generations or measurements.
  const stable = await configurations(request);
  await page.getByRole('button', { name: 'Clear selection and draft', exact: true }).click();
  await selectAll(page);
  await page.getByRole('button', { name: 'Preview changes', exact: true }).click();
  await expect(page.locator('#bulk-preview-summary')).toContainText('0 checks will change; 500 already have these values');
  await page.getByRole('button', { name: 'Save reviewed checks', exact: true }).click();
  await expect(page.locator('#bulk-notice')).toContainText('Saved 0 checks together');
  const noOp = await configurations(request);
  expect(noOp.map((row) => [row.id, row.revision, row.desired_generation]))
    .toEqual(stable.map((row) => [row.id, row.revision, row.desired_generation]));

  // A smaller explicit batch crosses a real file-size threshold and produces
  // enough real notifications to exercise both delivery pages. Keep the warning
  // incidents open through retry so the original firing notifications stay relevant.
  const batch = noOp.slice(0, 30);
  const batchIDs = new Set(batch.map((row) => row.id));
  const untouched = noOp.filter((row) => !batchIDs.has(row.id));
  const configurationIdentity = (rows) => rows.map((row) => [
    row.id, row.revision, row.desired_generation, row.params, row.source_revision,
  ]).sort(([left], [right]) => left.localeCompare(right));
  async function setBatch(params) {
    const latest = await configurations(request);
    const selection = batch.map(({ id }) => ({ id, revision: latest.find((row) => row.id === id).revision }));
    const prepared = await postBulk(request, 'prepare', { selection });
    const preview = await postBulk(request, 'preview', { prepare_token: prepared.prepare_token, params });
    const applied = await postBulk(request, 'apply', { review_token: preview.review_token, params });
    expect(applied.changed_count).toBe(30);
    expect(applied.receipts).toHaveLength(30);
    expect(applied.receipts.map((row) => row.id).sort()).toEqual([...batchIDs].sort());
    return applied.receipts;
  }
  expect((await snapshot(request)).occurrences).toEqual([]);
  let failed;
  let firing;
  let retriedID;
  await mode(request, { webhook: 'reject' });
  try {
    const warnedVersions = await setBatch({ critical_min_bytes: 2, warn_min_bytes: 14 });
    await expect.poll(async () => (await streams(request, { health: 'WARN', freshness: 'fresh' })).total,
      { timeout: 180_000 }).toBe(30);
    failed = (await streams(request, { health: 'WARN', freshness: 'fresh' })).items;
    expect(failed.map((row) => row.assignment_id).sort()).toEqual([...batchIDs].sort());
    for (const row of failed) {
      expect(row.current.confirmed_generation).toBe(warnedVersions.find((saved) => saved.id === row.assignment_id).target_generation);
      expect(row.current.confirmed_params).toEqual({ critical_min_bytes: 2, warn_min_bytes: 14 });
    }
    expect((await streams(request, { health: 'OK', freshness: 'fresh' })).total).toBe(470);
    expect(configurationIdentity((await configurations(request)).filter((row) => !batchIDs.has(row.id))))
      .toEqual(configurationIdentity(untouched));
    await page.goto(`/checks/${failed[0].id}`);
    await expect(page.locator('[id^="active-incident-"]')).toHaveCount(1);
    await checkpoint(page, testInfo, 'bulk-parameters-cause-thirty-real-file-warnings');

    await expect.poll(async () => {
      const state = await snapshot(request);
      return state.occurrences.length === 30 && state.occurrences.every((item) =>
        item.kind === 'firing' && batchIDs.has(item.assignment_id)
        && item.status === 'exhausted' && item.attempt_count === 3);
    }, { timeout: 60_000, message: 'All 30 actual firing notifications must exhaust three rejected deliveries' }).toBe(true);
    const exhausted = await snapshot(request);
    firing = exhausted.occurrences;
    expect(new Set(firing.map((item) => item.id)).size).toBe(30);
    expect(firing.map((item) => item.assignment_id).sort()).toEqual([...batchIDs].sort());
    expect(exhausted.incidents.filter((item) => item.status === 'open')).toHaveLength(30);
    expect(firing.every((item) => item.can_retry && item.payload.health === 'WARN'
      && item.latest_attempt.http_status === 503 && item.latest_attempt.status === 'failed_or_ambiguous')).toBe(true);
    expect(firing.map((item) => item.payload.stream_id).sort()).toEqual(failed.map((row) => row.id).sort());
    await testInfo.attach('thirty-real-exhausted-notifications', {
      body: JSON.stringify(firing, null, 2), contentType: 'application/json',
    });

    await page.goto('/notifications');
    await expect(page.getByLabel('Delivery status', { exact: true })).toHaveValue('unresolved');
    await expect(page.locator('#notifications > .panel-heading')).toContainText('30 outstanding');
    const cards = page.locator('#notifications .notifications-table tr[id^="notification-row-"]');
    await expect(cards).toHaveCount(25);
    await expect(page.locator('#notification-pagination')).toContainText('Page 1 of 2');
    await expect(page.locator('#notification-pagination')).toContainText('30 matching notifications');
    await checkpoint(page, testInfo, 'delivery-outstanding-first-page-320');
    await page.getByLabel('Delivery status', { exact: true }).selectOption('exhausted');
    await expect(page).toHaveURL(/notification_status=exhausted/);
    const firstPage = await cards.evaluateAll((rows) => rows.map((row) => row.id.replace('notification-row-', '')));
    await page.getByRole('link', { name: 'Next notifications', exact: true }).click();
    await expect(cards).toHaveCount(5);
    await expect(page.locator('#notification-pagination')).toContainText('Page 2 of 2');
    const secondPage = await cards.evaluateAll((rows) => rows.map((row) => row.id.replace('notification-row-', '')));
    expect(new Set([...firstPage, ...secondPage]).size).toBe(30);
    expect([...firstPage, ...secondPage].sort()).toEqual(firing.map((item) => item.id).sort());
    await page.evaluate(() => window.liveSocket.disconnect());
    await expect(page.locator('[data-phx-main]')).not.toHaveClass(/phx-connected/);
    await page.evaluate(() => window.liveSocket.connect());
    await connected(page);
    await expect(page.locator('#notification-pagination')).toContainText('Page 2 of 2');
    expect(await cards.evaluateAll((rows) => rows.map((row) => row.id.replace('notification-row-', '')))).toEqual(secondPage);
    await checkpoint(page, testInfo, 'delivery-exhausted-second-page-five-notifications-320');

    const original = firing.find((item) => item.id === secondPage[0]);
    retriedID = original.id;
    await page.locator(`#notification-row-${original.id}`).getByRole('link').first().click();
    await expect(page).toHaveURL(new RegExp(`/notifications/${original.id}(?:\\?|$)`));
    const notification = page.locator(`#notification-${original.id}`);
    await notification.getByText('Notification identity and immutable payload', { exact: true }).click();
    expect(JSON.parse(await notification.locator('pre').textContent())).toEqual(original.payload);
    await expect(notification).toContainText(original.destination);
    await mode(request, { webhook: 'ok' });
    const retryForm = notification.locator(`#retry-notification-${original.id}`);
    await keyboardFill(page, retryForm.getByLabel('Retry reason', { exact: true }), 'Local receiver repaired; retry the original notification from page two');
    await keyboardSubmit(page, retryForm.getByRole('button', { name: 'Retry notification', exact: true }));
    await expect.poll(async () => (await snapshot(request)).occurrences.find((item) => item.id === original.id)?.status,
      { timeout: 45_000 }).toBe('delivered');
    const afterRetry = await snapshot(request);
    const accepted = afterRetry.occurrences.find((item) => item.id === original.id);
    expect(accepted.payload).toEqual(original.payload);
    expect(accepted.destination).toBe(original.destination);
    expect(accepted.attempt_count).toBe(4);
    expect(accepted.latest_attempt.http_status).toBe(202);
    expect(afterRetry.occurrences.filter((item) => item.status === 'exhausted')).toHaveLength(29);
    expect(afterRetry.incidents.filter((item) => item.status === 'open')).toHaveLength(30);
    const receiverResponse = await request.get(`${fixtureURL}/records`);
    expect(receiverResponse.ok()).toBeTruthy();
    const received = (await receiverResponse.json()).records;
    expect(received).toHaveLength(1);
    expect(received[0].payload).toEqual(original.payload);
    expect(received[0].behavior).toBe('ok');
    await testInfo.attach('original-notification-accepted-by-local-receiver', {
      body: JSON.stringify({ original, accepted, receipt: received[0] }, null, 2), contentType: 'application/json',
    });
    await page.getByRole('link', { name: 'Back to notifications' }).click();
    await expect(cards).toHaveCount(4);
    await expect(page.locator('#notification-pagination')).toContainText('29 matching notifications');
    await page.getByLabel('Delivery status', { exact: true }).selectOption('delivered');
    await expect(page).toHaveURL(/notification_status=delivered/);
    await expect(cards).toHaveCount(1);
    await expect(page.locator(`#notification-row-${original.id}`)).toContainText('Receiver accepted');
    await expect(page.locator('#notifications > .panel-heading')).toContainText('29 outstanding');
    await expect(page.locator('#notification-pagination')).toContainText('1 matching notification');
    await checkpoint(page, testInfo, 'delivery-original-page-two-notification-accepted-320');
  } finally {
    await mode(request, { webhook: 'ok' });
  }

  // Restoring parameters requires new healthy measurements. The closure reason
  // records a configuration change rather than claiming that the files changed.
  const restoredVersions = await setBatch({ critical_min_bytes: 2, warn_min_bytes: 12 });
  await expect.poll(async () => (await streams(request, { health: 'OK', freshness: 'fresh' })).total,
    { timeout: 180_000 }).toBe(500);
  const finalConfigurations = await configurations(request);
  expect(configurationIdentity(finalConfigurations.filter((row) => !batchIDs.has(row.id))))
    .toEqual(configurationIdentity(untouched));
  expect(finalConfigurations.map((row) => row.id).sort()).toEqual(noOp.map((row) => row.id).sort());
  expect(finalConfigurations.every((row) => row.params.critical_min_bytes === 2 && row.params.warn_min_bytes === 12)).toBe(true);
  const finalState = await snapshot(request);
  expect(finalState.incidents).toHaveLength(30);
  expect(finalState.incidents.every((incident) => incident.status === 'closed' && incident.closure_reason === 'configuration_changed')).toBe(true);
  expect(finalState.incidents.map((incident) => incident.id).sort()).toEqual(firing.map((item) => item.incident_id).sort());
  for (const original of firing) {
    const ended = finalState.occurrences.find((item) => item.id === original.id);
    expect(ended.payload).toEqual(original.payload);
    expect(ended.status).toBe(original.id === retriedID ? 'delivered' : 'superseded');
  }
  await page.goto(`/checks/${failed[0].id}`);
  await expect(page.locator('[id^="active-incident-"]')).toHaveCount(0);
  const selectedResponse = await request.get(`/api/v1/checks/${failed[0].id}`);
  expect(selectedResponse.ok()).toBeTruthy();
  const selected = (await selectedResponse.json()).stream;
  expect(selected.current.confirmed_generation).toBe(restoredVersions.find((saved) => saved.id === selected.assignment_id).target_generation);
  expect(selected.current.confirmed_observation_id).not.toBe(failed[0].current.confirmed_observation_id);
  await checkpoint(page, testInfo, 'bulk-restored-parameters-measured-healthy');
  expect(errors).toEqual([]);
});
