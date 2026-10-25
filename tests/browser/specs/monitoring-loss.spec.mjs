// Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
// SPDX-License-Identifier: Apache-2.0
import { test, expect } from '@playwright/test';
import { readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { attachState, checkpoint, connected, fixtureURL, incidentNavigation, keyboardSubmit, measured, mode, sectionTabs, snapshot, streams } from '../support/helpers.mjs';
import { demoAssignments } from '../support/helpers.mjs';

let filesystemId, httpId, consumerId;
test.beforeEach(async ({ request }) => {
  const checks = await demoAssignments(request);
  ({ filesystem: { id: filesystemId }, http: { id: httpId }, consumer: { id: consumerId } } = checks);
  // These journeys assert exact attention counts. Measure a healthy unrelated
  // filesystem even when the real Docker VM exceeds the demo warning default.
  const filesystem = checks.filesystem;
  const response = await request.put(`/api/v1/assignments/${filesystemId}`, {
    data: { revision: filesystem.revision, params: { ...filesystem.params, warn_percent: 99, crit_percent: 100 } },
  });
  expect(response.ok(), await response.text()).toBe(true);
  await measured(request, filesystemId);
});

const phase = process.env.MONDEK_BROWSER_PHASE;
const restartStatePath = process.env.MONDEK_BROWSER_RESTART_STATE || path.join(process.env.MONDEK_BROWSER_OUTPUT || '.', 'controller-restart.json');

async function incidents(request, filters = {}) {
  const response = await request.get(`/api/v1/monitoring-incidents?${new URLSearchParams(filters)}`);
  expect(response.ok(), await response.text()).toBe(true);
  return response.json();
}

async function detail(request, id) {
  const response = await request.get(`/api/v1/monitoring-incidents/${id}`);
  expect(response.ok(), await response.text()).toBe(true);
  return response.json();
}

async function occurrence(request, incidentId, kind = 'firing') {
  return (await snapshot(request)).occurrences.find((row) => row.monitoring_incident_id === incidentId && row.kind === kind);
}

async function healthy(request) {
  await mode(request, { ready: true, backlog: 2, processing_enabled: true, data_mode: 'ok', offline_installations: [], webhook: 'ok' });
  await expect.poll(async () => (await streams(request, { freshness: 'fresh' })).total).toBe(3);
  await measured(request, consumerId);
  await expect.poll(async () => (await incidents(request)).total).toBe(0);
}

async function unavailable(request) {
  let result;
  await expect.poll(async () => {
    result = (await streams(request)).items.find((row) => row.assignment_id === consumerId);
    return result?.current?.knowledge === 'unavailable';
  }, { timeout: 45_000, intervals: [100, 250, 500] }).toBe(true);
  return result;
}

async function grouped(request, members) {
  let incident;
  await expect.poll(async () => {
    const listing = await incidents(request);
    incident = listing.items[0];
    return listing.total === 1 && incident.scope_kind === 'runner' && incident.member_count === members;
  }, { timeout: 45_000, message: `One runner episode must contain ${members} affected results` }).toBe(true);
  return incident;
}

async function reconnect(page) {
  await page.evaluate(() => window.liveSocket.disconnect());
  await expect(page.locator('[data-phx-main]')).not.toHaveClass(/phx-connected/);
  await page.evaluate(() => window.liveSocket.connect());
  await connected(page);
}

async function acknowledge(page, note) {
  await page.locator('#monitoring-ack-note').fill(note);
  await keyboardSubmit(page, page.locator('#monitoring-acknowledgement-form').getByRole('button', { name: 'Acknowledge monitoring loss', exact: true }));
  await expect(page.locator('#active-monitoring-acknowledgement')).toContainText(note);
}

test('real monitoring failures debounce, group by runner, hold original delivery and restore through fresh measurements', async ({ page, request }, testInfo) => {
  test.skip(phase === 'after-restart', 'Already verified before the actual controller restart');
  const errors = [];
  page.on('pageerror', (error) => errors.push(error.message));
  await healthy(request);
  const baseline = (await streams(request)).items.find((row) => row.assignment_id === consumerId);
  const runner = (await snapshot(request)).runners.find((row) => row.id === baseline.runner_id);
  const before = await incidents(request, { status: 'all' });

  try {
    // An actual failed worker run, followed by its next healthy scheduled run,
    // stays inside the six-second grace. No synthetic evidence is inserted.
    await mode(request, { data_mode: 'crash' });
    const brief = await unavailable(request);
    expect(brief.current.health).toBe('OK');
    await mode(request, { data_mode: 'ok' });
    await measured(request, consumerId);
    expect((await incidents(request, { status: 'all' })).total).toBe(before.total);

    await mode(request, { data_mode: 'slow', webhook: 'reject' });
    const failed = await unavailable(request);
    expect(failed.current.health).toBe('OK');
    expect(failed.current.diagnostic).toContain('worker execution timed out');
    const episode = await grouped(request, 1);
    expect(episode.runner_id).toBe(runner.id);
    expect((await snapshot(request)).incidents.filter((row) => row.status === 'open')).toEqual([]);
    const opening = await occurrence(request, episode.id);
    expect(opening.payload.incident_type).toBe('monitoring_loss');
    expect(opening.payload.monitoring_incident_id).toBe(episode.id);
    expect(opening.incident_id).toBeNull();
    expect(opening.payload.member_count).toBe(1);
    expect(opening.payload.member_snapshot[0].stream_id).toBe(baseline.id);

    await page.goto('/incidents');
    await connected(page);
    await sectionTabs(page, 'Incidents', 'Incident views', 'Target health');
    await incidentNavigation(page, request, { health: 0, monitoring: 1 });
    const lossTab = page.getByRole('navigation', { name: 'Incident views' }).getByRole('link', { name: /Monitoring loss/ });
    await lossTab.click();
    await connected(page);
    await sectionTabs(page, 'Incidents', 'Incident views', 'Monitoring loss');
    await expect(page.locator('.monitoring-loss-row')).toHaveCount(1);
    await page.locator(`#monitoring-incident-${episode.id} h3 a`).click();
    await expect(page).toHaveURL(new RegExp(`/monitoring-incidents/${episode.id}(?:\\?|$)`));
    await connected(page);
    await expect(page.locator('#monitoring-members .monitoring-loss-member')).toHaveCount(1);
    await expect(page.locator('#monitoring-members')).toContainText('Unavailable');
    const investigate = page.locator('#monitoring-members a').first();
    const investigationURL = new URL(await investigate.getAttribute('href'), page.url());
    expect(investigationURL.pathname).toBe(`/checks/${baseline.id}/diagnostics`);
    expect(investigationURL.searchParams.get('return_to')).toBe(`/monitoring-incidents/${episode.id}`);
    await investigate.click();
    await connected(page);
    await expect(page.locator('#latest-execution')).toContainText('worker execution timed out');
    await expect(page.locator('#investigation-back')).toContainText('Back to monitoring incident');
    await page.locator('#investigation-back').click();
    await connected(page);
    await expect(page).toHaveURL(new RegExp(`/monitoring-incidents/${episode.id}(?:\\?|$)`));
    await expect(page.locator('#monitoring-loss-summary')).toContainText('Target-health incidents');
    await checkpoint(page, testInfo, 'collection-loss-retains-target-health');

    // Exhaust the real HTTP 503 deliveries. An operator retry while acknowledged
    // must keep both the immutable notification and the explicit hold.
    await expect.poll(async () => (await occurrence(request, episode.id))?.status, { timeout: 60_000 }).toBe('exhausted');
    const exhausted = await occurrence(request, episode.id);
    expect(exhausted.attempt_count).toBe(3);
    await expect(page.locator(`#notification-${opening.id}`)).toContainText('HTTP 503');
    await page.locator('#monitoring-ack-note').fill('Investigating this runner and later affected results');
    await reconnect(page);
    await expect(page.locator('#monitoring-ack-note')).toHaveValue('Investigating this runner and later affected results');
    await acknowledge(page, 'Investigating this runner and later affected results');
    await page.goto('/monitoring-incidents');
    await connected(page);
    await expect(page.locator(`#monitoring-incident-${episode.id}`)).toHaveClass(/monitoring-loss-acknowledged/);
    await expect(page.locator('#monitoring-incident-list .panel-heading')).toContainText('0 unacknowledged');
    await checkpoint(page, testInfo, 'acknowledged-monitoring-loss-inventory');
    await page.locator(`#monitoring-incident-${episode.id} h3 a`).click();
    await connected(page);
    await mode(request, { webhook: 'ok' });
    const retry = page.locator(`#retry-monitoring-notification-${opening.id}`);
    await retry.getByLabel('Retry reason', { exact: true }).fill('Local receiver repaired; keep acknowledgement active');
    await reconnect(page);
    await expect(retry.getByLabel('Retry reason', { exact: true })).toHaveValue('Local receiver repaired; keep acknowledgement active');
    await keyboardSubmit(page, retry.getByRole('button', { name: 'Retry notification', exact: true }));
    await expect(page.locator(`#notification-${opening.id}`)).toContainText('held by acknowledgement');
    expect((await occurrence(request, episode.id)).attempt_count).toBe(3);

    // The runner keeps executing while controller transport is partitioned.
    // Its other two results join the same acknowledged monitoring episode.
    const blockedAt = Date.now();
    await mode(request, { offline_installations: [runner.id] });
    expect((await grouped(request, 3)).id).toBe(episode.id);
    await expect(page.locator('#monitoring-members .monitoring-loss-member')).toHaveCount(3);
    await expect(page.locator('#active-monitoring-acknowledgement')).toBeVisible();
    expect((await detail(request, episode.id)).acknowledgement_mode).toBe('until_incident_ends');
    expect((await snapshot(request)).occurrences.filter((row) => row.monitoring_incident_id === episode.id && row.kind === 'firing')).toHaveLength(1);
    expect((await occurrence(request, episode.id)).attempt_count).toBe(3);
    await page.setViewportSize({ width: 320, height: 740 });
    await checkpoint(page, testInfo, 'runner-outage-one-acknowledged-episode-320');
    await page.reload();
    await connected(page);
    await expect(page.locator('#active-monitoring-acknowledgement')).toBeVisible();

    await keyboardSubmit(page, page.locator('#end-monitoring-acknowledgement'));
    await expect.poll(async () => (await occurrence(request, episode.id))?.status, { timeout: 45_000 }).toBe('delivered');
    const delivered = await occurrence(request, episode.id);
    expect(delivered.id).toBe(exhausted.id);
    expect(delivered.payload).toEqual(exhausted.payload);
    expect(delivered.destination).toBe(exhausted.destination);
    expect(delivered.attempt_count).toBe(4);
    const receipts = await (await request.get(`${fixtureURL}/records`)).json();
    expect(receipts.records.some((row) => row.payload.occurrence_id === opening.id && row.payload.monitoring_incident_id === episode.id)).toBe(true);
    await acknowledge(page, 'Awaiting fresh evidence after transport returns');

    // Produce WARN while disconnected. Reconnection must preserve original
    // report ages, restore monitoring and independently open target-health work.
    const changedAt = Date.now();
    await mode(request, { data_mode: 'ok', backlog: 6 });
    await expect.poll(() => Date.now() - changedAt, { intervals: [1000] }).toBeGreaterThan(7000);
    expect((await grouped(request, 3)).id).toBe(episode.id);
    const resumedAt = Date.now();
    await mode(request, { offline_installations: [] });
    await measured(request, consumerId, 'WARN');
    await expect(page.locator('#monitoring-loss-summary h2')).toHaveText('Monitoring restored');
    await expect(page.locator('#active-monitoring-acknowledgement')).toHaveCount(0);
    const ended = await detail(request, episode.id);
    expect(ended.status).toBe('closed');
    expect(ended.closure_reason).toBe('monitoring_restored');
    expect(ended.acknowledgement_mode).toBeNull();
    expect(ended.closing_evidence.length).toBeGreaterThan(0);
    expect(ended.closing_evidence.every((row) => row.knowledge === 'fresh' && row.observation_id && row.source_at)).toBe(true);
    await expect.poll(async () => {
      const records = (await (await request.get(`${fixtureURL}/transport-records`)).json()).records;
      return records.flatMap((row) => row.request.reports).some((report) => report.assignment_id === consumerId
        && Date.parse(report.started_at) > changedAt && Date.parse(report.started_at) > blockedAt
        && Date.parse(report.started_at) < resumedAt
        && report.results.some((result) => result.key === 'backlog' && result.health === 'WARN'));
    }, { message: 'Buffered real measurements retain their execution times after reconnect' }).toBe(true);
    const current = (await streams(request)).items.find((row) => row.id === baseline.id);
    expect(current.current.session_id).toBe(baseline.current.session_id);
    expect((await snapshot(request)).incidents.some((row) => row.assignment_id === consumerId && row.status === 'open' && row.health === 'WARN')).toBe(true);
    await expect.poll(async () => (await occurrence(request, episode.id, 'resolved'))?.status).toBe('delivered');
    expect((await occurrence(request, episode.id, 'resolved')).payload.closing_evidence).toEqual(ended.closing_evidence);
    await page.setViewportSize({ width: 1280, height: 900 });
    await checkpoint(page, testInfo, 'monitoring-restored-with-warning-target');
    await attachState(request, testInfo, 'monitoring-loss-delivery-and-restoration');
    await testInfo.attach('restored-monitoring-episode', { body: JSON.stringify(await detail(request, episode.id), null, 2), contentType: 'application/json' });
    expect(errors).toEqual([]);
  } finally {
    await healthy(request);
  }
});

test('overview keeps independently unacknowledged health and monitoring problems with consistent navigation', async ({ page, request }, testInfo) => {
  test.skip(phase === 'after-restart', 'Already verified before the actual controller restart');
  await healthy(request);
  const overview = await page.context().newPage();
  const navigation = await page.context().newPage();
  try {
    await mode(request, { backlog: 20 });
    await measured(request, consumerId, 'CRIT');
    const stream = (await streams(request)).items.find((row) => row.assignment_id === consumerId);
    const health = (await snapshot(request)).incidents.find((row) => row.assignment_id === consumerId && row.status === 'open');
    await mode(request, { data_mode: 'slow' });
    const failed = await unavailable(request);
    expect(failed.current.health).toBe('CRIT');
    const loss = await grouped(request, 1);
    await overview.goto('/');
    await connected(overview);
    const row = overview.locator(`#overview-attention #result-${stream.id}`);
    await expect(row).toContainText('Critical');
    await expect(row).toContainText('Unavailable');
    await incidentNavigation(overview, request, { health: 1, monitoring: 1 });
    await checkpoint(overview, testInfo, 'overview-independent-health-and-monitoring-desktop');

    // Every shared shell must preserve both live counts on direct load and
    // reconnect, including views that formerly built their own navigation.
    for (const route of ['/coverage', '/coverage/diagnostics', '/coverage/publishers', '/maintenance', '/maintenance/new', '/configuration/rules', '/configuration/rules/new', '/runners', '/notifications', '/guide']) {
      await navigation.goto(route);
      await connected(navigation);
      await incidentNavigation(navigation, request, { health: 1, monitoring: 1 });
      if (route === '/coverage/publishers') {
        await navigation.getByRole('link', { name: 'Manage publication', exact: true }).first().click();
        await expect(navigation).toHaveURL(/\/coverage\/publishers\/[^/?]+$/);
        await expect(navigation.locator('#publisher-heading')).toBeVisible();
        await connected(navigation);
        await incidentNavigation(navigation, request, { health: 1, monitoring: 1 });
      }
      await reconnect(navigation);
      await incidentNavigation(navigation, request, { health: 1, monitoring: 1 });
    }
    await navigation.goto('/coverage');
    await connected(navigation);

    await page.goto(`/incidents/${health.id}`);
    await connected(page);
    await page.locator('#ack-note').fill('Health investigation does not acknowledge collection loss');
    await page.locator('#acknowledgement-form').getByRole('button', { name: 'Acknowledge', exact: true }).click();
    await expect(page.locator('#active-acknowledgement')).toBeVisible();
    await expect(row).toBeVisible();
    await incidentNavigation(overview, request, { health: 0, monitoring: 1 });
    await incidentNavigation(navigation, request, { health: 0, monitoring: 1 });
    await overview.setViewportSize({ width: 390, height: 844 });
    await checkpoint(overview, testInfo, 'overview-acknowledged-health-still-needs-monitoring-390');

    await page.goto(`/monitoring-incidents/${loss.id}`);
    await connected(page);
    await acknowledge(page, 'Collection investigation acknowledged independently');
    await expect(row).toHaveCount(0);
    await incidentNavigation(overview, request, { health: 0, monitoring: 0 });
    await incidentNavigation(navigation, request, { health: 0, monitoring: 0 });
    await overview.reload();
    await connected(overview);
    await reconnect(overview);
    await expect(row).toHaveCount(0);
    expect((await streams(request)).items.find((item) => item.id === stream.id).current.health).toBe('CRIT');

    await page.goto(`/incidents/${health.id}`);
    await connected(page);
    await page.locator('#end-acknowledgement').click();
    await expect(page.locator('#active-acknowledgement')).toHaveCount(0);
    await expect(row).toContainText('Critical');
    await incidentNavigation(overview, request, { health: 1, monitoring: 0 });
    await overview.setViewportSize({ width: 320, height: 740 });
    await checkpoint(overview, testInfo, 'overview-acknowledged-monitoring-still-needs-health-320');
    await page.locator('#ack-note').fill('Resume health investigation');
    await page.locator('#acknowledgement-form').getByRole('button', { name: 'Acknowledge', exact: true }).click();
    await expect(page.locator('#active-acknowledgement')).toBeVisible();
    await expect(row).toHaveCount(0);

    await page.goto(`/monitoring-incidents/${loss.id}`);
    await connected(page);
    await page.locator('#end-monitoring-acknowledgement').click();
    await expect(page.locator('#active-monitoring-acknowledgement')).toHaveCount(0);
    await expect(row).toContainText('Unavailable');
    await incidentNavigation(overview, request, { health: 0, monitoring: 1 });
    await incidentNavigation(navigation, request, { health: 0, monitoring: 1 });
    await healthy(request);
    await expect(row).toHaveCount(0);
    await incidentNavigation(overview, request, { health: 0, monitoring: 0 });
  } finally {
    await healthy(request);
    await overview.close();
    await navigation.close();
  }
});

test('maintenance holds a new monitoring episode until uncovered results join its runner scope', async ({ page, request }, testInfo) => {
  test.skip(phase === 'after-restart', 'Already verified before the actual controller restart');
  await healthy(request);
  const baseline = (await streams(request)).items.find((row) => row.assignment_id === consumerId);
  let maintenanceURL;
  try {
    await page.goto(`/maintenance/new?check_id=${consumerId}`);
    await connected(page);
    await page.locator('#maintenance-name').fill('Consumer datasource work');
    await page.locator('#maintenance-reason').fill('Only this check is intentionally unavailable');
    await page.locator('#maintenance-preview-button').click();
    await expect(page.locator('#maintenance-preview-summary')).toContainText('1 result');
    await page.locator('#maintenance-save').click();
    await expect(page.locator('#maintenance-saved')).toContainText('Active');
    maintenanceURL = page.url();

    await mode(request, { data_mode: 'slow' });
    await unavailable(request);
    const episode = await grouped(request, 1);
    expect(episode.acknowledgement_mode).toBeNull();
    const held = await occurrence(request, episode.id);
    await page.goto(`/monitoring-incidents/${episode.id}`);
    await connected(page);
    await expect(page.locator(`#notification-${held.id}`)).toContainText('held by maintenance');
    expect((await occurrence(request, episode.id)).attempt_count).toBe(0);
    await checkpoint(page, testInfo, 'all-affected-results-maintained');

    await mode(request, { offline_installations: [baseline.runner_id] });
    expect((await grouped(request, 3)).id).toBe(episode.id);
    await expect.poll(async () => (await occurrence(request, episode.id))?.status).toBe('delivered');
    const released = await occurrence(request, episode.id);
    expect(released.id).toBe(held.id);
    expect(released.payload).toEqual(held.payload);
    expect(released.attempt_count).toBe(1);
    await page.setViewportSize({ width: 390, height: 844 });
    await checkpoint(page, testInfo, 'partial-maintenance-releases-original-notification');

    await healthy(request);
    await expect(page.locator('#monitoring-loss-summary h2')).toHaveText('Monitoring restored');
    expect((await detail(request, episode.id)).closure_reason).toBe('monitoring_restored');
  } finally {
    await healthy(request);
    if (maintenanceURL) {
      await page.goto(maintenanceURL);
      await connected(page);
      await page.locator('#maintenance-cancel').click();
      await page.locator('#maintenance-cancel-reason').fill('Local browser verification completed');
      await page.locator('#maintenance-confirm-cancel').click();
      await expect(page.locator('#maintenance-saved')).toContainText('Ended early');
    }
  }
});

test('prepare acknowledged monitoring loss and held delivery before controller restart', async ({ page, request }, testInfo) => {
  test.skip(phase !== 'before-restart', 'The host wrapper coordinates the actual controller restart');
  await healthy(request);
  try {
    await mode(request, { data_mode: 'slow', webhook: 'reject' });
    await unavailable(request);
    const episode = await grouped(request, 1);
    await expect.poll(async () => (await occurrence(request, episode.id))?.status, { timeout: 60_000 }).toBe('exhausted');
    const original = await occurrence(request, episode.id);
    await page.goto(`/monitoring-incidents/${episode.id}`);
    await connected(page);
    await acknowledge(page, 'Preserve this acknowledged monitoring episode across controller restart');
    const retry = page.locator(`#retry-monitoring-notification-${original.id}`);
    await retry.getByLabel('Retry reason', { exact: true }).fill('Retry after controller restart; acknowledgement remains in effect');
    await keyboardSubmit(page, retry.getByRole('button', { name: 'Retry notification', exact: true }));
    await expect(page.locator(`#notification-${original.id}`)).toContainText('held by acknowledgement');
    const persisted = await detail(request, episode.id);
    await writeFile(restartStatePath, JSON.stringify({ episode: persisted, occurrence: await occurrence(request, episode.id) }, null, 2));
    await checkpoint(page, testInfo, 'persisted-acknowledgement-before-controller-restart');
  } catch (error) {
    await healthy(request);
    throw error;
  }
});

test('acknowledged monitoring loss and original delivery survive actual controller restart', async ({ page, request }, testInfo) => {
  test.skip(phase !== 'after-restart', 'Runs in a new browser after the host restarts the controller');
  const saved = JSON.parse(await readFile(restartStatePath, 'utf8'));
  try {
    await mode(request, { webhook: 'ok' });
    const episode = await grouped(request, 1);
    expect(episode.id).toBe(saved.episode.id);
    expect(episode.opened_at).toBe(saved.episode.opened_at);
    expect(episode.acknowledgement_mode).toBe('until_incident_ends');
    expect(episode.acknowledgement_revision).toBe(saved.episode.acknowledgement_revision);
    const retained = await occurrence(request, episode.id);
    expect(retained.id).toBe(saved.occurrence.id);
    expect(retained.payload).toEqual(saved.occurrence.payload);
    expect(retained.attempt_count).toBe(saved.occurrence.attempt_count);
    expect(retained.attempt_count).toBe(3);

    await page.goto(`/monitoring-incidents/${episode.id}`);
    await connected(page);
    await expect(page.locator('#active-monitoring-acknowledgement')).toContainText('Preserve this acknowledged monitoring episode across controller restart');
    await expect(page.locator(`#notification-${retained.id}`)).toContainText('held by acknowledgement');
    await page.setViewportSize({ width: 320, height: 740 });
    await checkpoint(page, testInfo, 'controller-restarted-with-original-held-notification-320');
    await keyboardSubmit(page, page.locator('#end-monitoring-acknowledgement'));
    await expect.poll(async () => (await occurrence(request, episode.id))?.status).toBe('delivered');
    const delivered = await occurrence(request, episode.id);
    expect(delivered.payload).toEqual(saved.occurrence.payload);
    expect(delivered.attempt_count).toBe(4);
    await healthy(request);
    await expect(page.locator('#monitoring-loss-summary h2')).toHaveText('Monitoring restored');
    await expect.poll(async () => (await occurrence(request, episode.id, 'resolved'))?.status).toBe('delivered');
    await checkpoint(page, testInfo, 'monitoring-recovery-after-controller-restart-320');
    await testInfo.attach('monitoring-episode-after-controller-restart', { body: JSON.stringify(await detail(request, episode.id), null, 2), contentType: 'application/json' });
  } finally {
    await healthy(request);
  }
});
