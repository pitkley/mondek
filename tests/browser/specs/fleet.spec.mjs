// Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
// SPDX-License-Identifier: Apache-2.0
import { test, expect } from '@playwright/test';
import { checkpoint, connected, fixtureURL, mode, snapshot, streams } from '../support/helpers.mjs';

const fleetURL = process.env.MONDEK_FLEET_FIXTURE_URL || 'http://fleet-runner:8082';

async function fleet(request, changes) {
  const response = changes
    ? await request.post(`${fleetURL}/fleet`, { data: changes, timeout: 60_000 })
    : await request.get(`${fleetURL}/fleet`);
  expect(response.ok(), await response.text()).toBeTruthy();
  return response.json();
}

async function result(request, index) {
  const target = `fleet-node-${String(index).padStart(3, '0')}`;
  return (await streams(request, { search: target })).items.find((row) => row.target.key === target);
}

async function fresh(request, index, health = 'OK') {
  await expect.poll(async () => {
    const row = await result(request, index);
    return row?.current?.knowledge === 'fresh' && row.current.health === health;
  }, { timeout: 90_000, message: `Actual runner ${index} must measure fresh ${health}` }).toBe(true);
  return result(request, index);
}

const liveIndices = Array.from({ length: 12 }, (_, index) => index + 1);
const additionalIndices = Array.from({ length: 38 }, (_, index) => index + 13);

async function activeFresh(request, indices, total = indices.length, previousSessions = new Map()) {
  const targets = new Set(indices.map((index) => `fleet-node-${String(index).padStart(3, '0')}`));
  await expect.poll(async () => {
    const rows = await streams(request, { page_size: '100' });
    const selected = rows.items.filter((row) => targets.has(row.target.key));
    return rows.total === total && selected.length === indices.length
      && selected.every((row) => row.current.knowledge === 'fresh'
        && (!previousSessions.has(row.runner_id) || row.current.session_id !== previousSessions.get(row.runner_id)));
  }, { timeout: 180_000, message: `${indices.length} active real runners must establish fresh measurements` }).toBe(true);
  const processes = (await fleet(request)).processes.filter((row) => row.alive);
  expect(processes.map((row) => row.index).sort((a, b) => a - b)).toEqual([...indices].sort((a, b) => a - b));
  expect(new Set(processes.map((row) => row.pid)).size).toBe(indices.length);
  expect(processes.every((row) => row.sample_requests > 0)).toBe(true);
  return (await streams(request, { page_size: '100' })).items.filter((row) => targets.has(row.target.key));
}

async function filter(page, values) {
  const form = page.locator('#runner-filters');
  for (const [name, value] of Object.entries(values)) {
    const field = form.locator(`[name="${name}"]`);
    if (await field.evaluate((node) => node.tagName) === 'SELECT') await field.selectOption(value);
    else await field.fill(value);
  }
  await form.getByRole('button', { name: 'Apply filters', exact: true }).click();
  await connected(page);
}

test('twelve live runners recover while fifty authentically measured fleet identities remain identifiable', async ({ page, request }, testInfo) => {
  const errors = [];
  page.on('pageerror', (error) => errors.push(error.message));
  await activeFresh(request, liveIndices);
  const twelve = (await snapshot(request)).runners;
  expect(twelve).toHaveLength(12);
  await page.goto('/runners');
  await expect(page.locator('#runner-list tbody tr')).toHaveCount(12);
  await expect(page.locator('#runner-fleet-summary')).toContainText('12');
  await checkpoint(page, testInfo, 'twelve-live-runners-desktop');

  const collection = await fresh(request, 2);
  const disconnected = await fresh(request, 4);
  const beforePartition = (await fleet(request)).processes.find((row) => row.index === 4).sample_requests;
  try {
    await fleet(request, { samples: { 2: 'unavailable', 3: 'CRIT' } });
    await mode(request, { offline_installations: [disconnected.runner_id] });
    const critical = await fresh(request, 3, 'CRIT');
    await expect.poll(async () => (await result(request, 2)).current.knowledge, { timeout: 60_000 }).toBe('unavailable');
    await expect(page.locator(`#runner-row-${collection.runner_id}`)).toContainText('Measurement gaps');
    await expect(page.locator(`#runner-row-${disconnected.runner_id}`)).toContainText('Contact overdue', { timeout: 45_000 });
    await expect.poll(async () => (await fleet(request)).processes.find((row) => row.index === 4).sample_requests, { timeout: 45_000 }).toBeGreaterThan(beforePartition);
    await page.setViewportSize({ width: 390, height: 844 });
    await checkpoint(page, testInfo, 'twelve-mixed-collection-and-contact-390');
    await expect(page.locator(`#runner-row-${critical.runner_id}`)).toContainText('All results fresh');
    await filter(page, { collection: 'issues' });
    await expect(page.locator('#runner-list tbody tr')).toHaveCount(1);
    await expect(page.locator(`#runner-row-${collection.runner_id}`)).toBeVisible();
    await filter(page, { collection: 'all', contact: 'overdue' });
    await expect(page.locator('#runner-list tbody tr')).toHaveCount(1);
    await expect(page.locator(`#runner-row-${disconnected.runner_id}`)).toBeVisible();

    await filter(page, { search: 'Shared observer', contact: 'all' });
    await expect(page.locator('#runner-list tbody tr')).toHaveCount(2);
    const duplicateIds = await page.locator('#runner-list tbody tr').evaluateAll((rows) => rows.map((row) => row.id));
    expect(new Set(duplicateIds).size).toBe(2);
    await checkpoint(page, testInfo, 'duplicate-labels-remain-distinct-390');
    const duplicateList = new URL(page.url());
    await page.locator('#runner-list tbody tr').first().getByRole('link').first().click();
    await expect(page).toHaveURL(/\/runners\/[0-9a-f-]+(?:\?|$)/);
    await expect(page.locator('#runner-detail')).toBeVisible();
    await expect(page.locator('#runner-measurements')).toContainText('1');
    await page.locator('a.back').click();
    await expect(page).toHaveURL((url) => url.pathname === '/runners' && url.searchParams.get('search') === duplicateList.searchParams.get('search'));

    // Prove failure recovery and restart with the twelve real active observers.
    await fleet(request, { samples: { 2: 'OK', 3: 'OK' } });
    await mode(request, { offline_installations: [] });
    await fresh(request, 2);
    await fresh(request, 3);
    await fresh(request, 4);
    await activeFresh(request, liveIndices);
    const beforeRestart = (await snapshot(request)).runners.find((row) => row.id === disconnected.runner_id);
    const beforeRestartMeasurement = await result(request, 4);
    await fleet(request, { restart: [4] });
    await expect.poll(async () => (await snapshot(request)).runners.find((row) => row.id === disconnected.runner_id)?.session_id, { timeout: 60_000 }).not.toBe(beforeRestart.session_id);
    await expect.poll(async () => {
      const row = await result(request, 4);
      return row.current.knowledge === 'fresh'
        && row.current.session_id !== beforeRestart.session_id
        && row.current.observation_id !== beforeRestartMeasurement.current.observation_id;
    }, { timeout: 90_000, message: 'Restarted runner must produce its own new measured evidence' }).toBe(true);
    expect((await result(request, 4)).id).toBe(disconnected.id);
    await page.goto(`/runners/${disconnected.runner_id}`);
    await expect(page.locator('#runner-contact')).toContainText('Recent contact');
    await page.setViewportSize({ width: 320, height: 740 });
    await checkpoint(page, testInfo, 'runner-restarted-same-identity-restored-320');
    await activeFresh(request, liveIndices);
    const measuredHistory = [...(await streams(request, { page_size: '100' })).items];

    // Every additional identity is published and measured by the actual CLI.
    // Keep at most twelve processes active on this shared Docker VM, then stop
    // completed batches honestly: their retained contact/measurement ages grow.
    await fleet(request, { stop: liveIndices });
    for (let first = 13; first <= 50; first += 12) {
      const batch = Array.from({ length: Math.min(12, 51 - first) }, (_, offset) => first + offset);
      await fleet(request, { start: batch });
      measuredHistory.push(...await activeFresh(request, batch, batch.at(-1)));
      await fleet(request, { stop: batch });
    }
    expect(measuredHistory).toHaveLength(50);
    expect(new Set(measuredHistory.map((row) => row.runner_id)).size).toBe(50);
    expect(new Set(measuredHistory.map((row) => row.current.confirmed_observation_id)).size).toBe(50);
    expect(measuredHistory.every((row) => row.current.confirmed_observation_id && row.current.source_at)).toBe(true);
    await fleet(request, { start: liveIndices });
    await activeFresh(request, liveIndices, 50, new Map(measuredHistory.slice(0, 12).map((row) => [row.runner_id, row.current.session_id])));
    await expect.poll(async () => {
      const response = await request.get('/api/v1/runners?page_size=50');
      expect(response.ok()).toBeTruthy();
      const listing = await response.json();
      return { recent: listing.counts.recent, overdue: listing.counts.overdue };
    }, { timeout: 45_000 }).toEqual({ recent: 12, overdue: 38 });
    await fleet(request, { samples: { 2: 'unavailable', 3: 'CRIT' } });
    await fresh(request, 3, 'CRIT');
    await expect.poll(async () => (await result(request, 2)).current.knowledge, { timeout: 60_000 }).toBe('unavailable');
    await page.setViewportSize({ width: 1440, height: 1000 });
    await page.goto('/runners?source_id=browser-fleet-checks');
    await filter(page, { sort: 'name' });
    await expect(page.locator('#runner-list tbody tr')).toHaveCount(25);
    await expect(page.locator('#runner-pagination')).toContainText('Page 1 of 2');
    await checkpoint(page, testInfo, 'fifty-real-runners-first-page');
    const first = await page.locator('#runner-list tbody tr').evaluateAll((rows) => rows.map((row) => row.id));
    await page.locator('#runner-pagination').getByRole('link', { name: /Next/ }).click();
    await expect(page.locator('#runner-pagination')).toContainText('Page 2 of 2');
    await expect(page.locator('#runner-list tbody tr')).toHaveCount(25);
    const second = await page.locator('#runner-list tbody tr').evaluateAll((rows) => rows.map((row) => row.id));
    expect(new Set([...first, ...second]).size).toBe(50);
    const expectedOrder = (await snapshot(request)).runners.sort((a, b) => a.label.toLowerCase().localeCompare(b.label.toLowerCase()) || a.id.localeCompare(b.id)).map((row) => `runner-row-${row.id}`);
    expect([...first, ...second]).toEqual(expectedOrder);
    await page.reload();
    await connected(page);
    await expect(page.locator('#runner-pagination')).toContainText('Page 2 of 2');
    await page.evaluate(() => window.liveSocket.disconnect());
    await expect(page.locator('[data-phx-main]')).not.toHaveClass(/phx-connected/);
    await page.evaluate(() => window.liveSocket.connect());
    await connected(page);
    await expect(page.locator('#runner-pagination')).toContainText('Page 2 of 2');
    await page.setViewportSize({ width: 320, height: 740 });
    await checkpoint(page, testInfo, 'fifty-runners-page-two-reconnected-320');

    await page.goto(`/runners/${collection.runner_id}`);
    await expect(page.locator('#runner-contact')).toContainText('Recent contact');
    await expect(page.locator('#runner-measurements')).toContainText('Unavailable');
    await expect(page.locator('#runner-last-report')).toContainText('Last reported execution & upload');
    await expect(page.locator('#runner-provenance')).not.toHaveAttribute('open');
    await page.locator('#runner-provenance > summary').click();
    await checkpoint(page, testInfo, 'selected-runner-collection-investigation-320');
    const allResults = page.locator('#runner-measurements a[href*="runner_id="]').first();
    await allResults.click();
    await expect(page).toHaveURL((url) => url.pathname === '/checks' && url.searchParams.get('runner_id') === collection.runner_id);
    await expect(page.locator('[id^="result-"]')).toHaveCount(1);

    await fleet(request, { samples: { 2: 'OK', 3: 'OK' } });
    await fresh(request, 2);
    await fresh(request, 3);
    await activeFresh(request, liveIndices, 50);
    const processEvidence = await fleet(request);
    expect(processEvidence.processes).toHaveLength(50);
    expect(new Set(processEvidence.processes.map((row) => row.state_directory)).size).toBe(50);
    expect(processEvidence.processes.every((row) => row.sample_requests > 0)).toBe(true);
    await testInfo.attach('fifty-authentic-measurements-with-twelve-live-processes', {
      body: JSON.stringify({ processes: processEvidence, measuredHistory, checks: await streams(request, { page_size: '100' }), runners: (await snapshot(request)).runners }, null, 2), contentType: 'application/json',
    });
    expect(errors).toEqual([]);
  } finally {
    await fleet(request, { stop: additionalIndices });
    await fleet(request, { start: liveIndices, samples: { 2: 'OK', 3: 'OK' } });
    await mode(request, { offline_installations: [], webhook: 'ok' });
  }
});

test('dedicated notification investigation retries a real rejected delivery without losing list context or evidence', async ({ page, request }, testInfo) => {
  const check = await fresh(request, 5);
  try {
    await mode(request, { webhook: 'reject' });
    await fleet(request, { samples: { 5: 'CRIT' } });
    await fresh(request, 5, 'CRIT');
    await expect.poll(async () => (await snapshot(request)).occurrences.find((row) => row.assignment_id === check.assignment_id && row.kind === 'firing')?.status, { timeout: 90_000 }).toBe('exhausted');
    const original = (await snapshot(request)).occurrences.find((row) => row.assignment_id === check.assignment_id && row.kind === 'firing');
    expect(original.attempt_count).toBe(3);
    await page.goto('/notifications?notification_status=exhausted');
    await expect(page.locator(`#notification-row-${original.id}`)).toContainText('Retries exhausted');
    await checkpoint(page, testInfo, 'dedicated-notifications-exhausted-desktop');
    await page.locator(`#notification-row-${original.id}`).getByRole('link').first().click();
    await expect(page).toHaveURL(new RegExp(`/notifications/${original.id}(?:\\?|$)`));
    const notification = page.locator(`#notification-${original.id}`);
    await expect(notification).toContainText('HTTP 503');
    await notification.getByText('Notification identity and immutable payload', { exact: true }).click();
    expect(JSON.parse(await notification.locator('pre').textContent())).toEqual(original.payload);
    // Delivery and incident investigation now have separate LiveView processes.
    // Preserve the exact notification/list return context across that boundary.
    const detailURL = page.url();
    await notification.locator('a[href^="/incidents/"]').first().click();
    await connected(page);
    await expect(page).toHaveURL(/\/incidents\//);
    await page.getByRole('link', { name: 'Back to notification', exact: true }).click();
    await connected(page);
    await expect(page).toHaveURL(detailURL);
    await expect(notification).toContainText('HTTP 503');
    const form = page.locator(`#retry-notification-${original.id}`);
    await form.getByLabel('Retry reason', { exact: true }).fill('Local receiver repaired after fleet delivery investigation');
    await page.evaluate(() => window.liveSocket.disconnect());
    await expect(page.locator('[data-phx-main]')).not.toHaveClass(/phx-connected/);
    await page.evaluate(() => window.liveSocket.connect());
    await connected(page);
    await expect(form.getByLabel('Retry reason', { exact: true })).toHaveValue('Local receiver repaired after fleet delivery investigation');
    await page.setViewportSize({ width: 320, height: 740 });
    await checkpoint(page, testInfo, 'notification-detail-retry-draft-reconnected-320');
    await mode(request, { webhook: 'ok' });
    await form.getByRole('button', { name: 'Retry notification', exact: true }).click();
    await expect(notification).toContainText('Receiver accepted', { timeout: 45_000 });
    const delivered = (await snapshot(request)).occurrences.find((row) => row.id === original.id);
    expect(delivered.attempt_count).toBe(4);
    expect(delivered.payload).toEqual(original.payload);
    expect(delivered.destination).toBe(original.destination);
    const receipts = (await (await request.get(`${fixtureURL}/records`)).json()).records;
    expect(receipts.some((row) => row.payload.occurrence_id === original.id)).toBe(true);
    await page.getByRole('link', { name: 'Back to notifications' }).click();
    await expect(page).toHaveURL((url) => url.pathname === '/notifications' && url.searchParams.get('notification_status') === 'exhausted');
    await expect(page.locator(`#notification-row-${original.id}`)).toHaveCount(0);
    await page.goto('/notifications?notification_status=delivered');
    await expect(page.locator(`#notification-row-${original.id}`)).toBeVisible();
    await checkpoint(page, testInfo, 'accepted-notification-retained-list-320');
    await fleet(request, { samples: { 5: 'OK' } });
    await fresh(request, 5);
    await expect.poll(async () => (await snapshot(request)).occurrences.some((row) => row.assignment_id === check.assignment_id && row.kind === 'resolved' && row.status === 'delivered'), { timeout: 45_000 }).toBe(true);
  } finally {
    await fleet(request, { samples: { 5: 'OK' } });
    await mode(request, { webhook: 'ok' });
  }
});
