import { unpackAPI } from '../support/helpers.mjs';
// Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
// SPDX-License-Identifier: Apache-2.0
import { test, expect } from '@playwright/test';
import { readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { attachState, checkpoint, connected, fixtureURL, incidentNavigation, keyboardSubmit, measured, mode, snapshot, streams, setFilter, expectInvestigationReturn } from '../support/helpers.mjs';
import { demoAssignments } from '../support/helpers.mjs';

let filesystemId, httpId, consumerId;
test.beforeEach(async ({ request }) => {
  const checks = await demoAssignments(request);
  ({ filesystem: { id: filesystemId }, http: { id: httpId }, consumer: { id: consumerId } } = checks);
  // These journeys assert exact attention counts. Measure a healthy unrelated
  // filesystem even when the real Docker VM exceeds the demo warning default.
  const filesystem = checks.filesystem;
  const response = await request.put(`/api/v1/assignments/${filesystemId}/configuration`, {
    data: { revision: filesystem.revision, params: { ...filesystem.params, warn_percent: 99, crit_percent: 100 } },
  });
  expect(response.ok(), await response.text()).toBe(true);
  await measured(request, filesystemId);
});

const phase = process.env.MONDEK_BROWSER_PHASE;
const restartStatePath = process.env.MONDEK_BROWSER_RESTART_STATE || path.join(process.env.MONDEK_BROWSER_OUTPUT || '.', 'controller-restart.json');

async function incidents(request, filters = {}) {
  const response = await request.get(`/api/v1/incidents/monitoring-loss?${new URLSearchParams(filters)}`);
  expect(response.ok(), await response.text()).toBe(true);
  return response.json().then(unpackAPI);
}

async function detail(request, id) {
  const response = await request.get(`/api/v1/incidents/monitoring-loss/${id}`);
  expect(response.ok(), await response.text()).toBe(true);
  return response.json().then(unpackAPI);
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
  await page.locator('#preview-incident-ack-form textarea[name=note]').fill(note);
  await keyboardSubmit(page, page.locator('#preview-incident-ack-form').getByRole('button', { name: 'Save acknowledgement', exact: true }));
  await expect(page.getByRole('table', { name: 'Active acknowledgement', exact: true })).toContainText(note);
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
    await incidentNavigation(page, request, { health: 0, monitoring: 1 });
    await setFilter(page, 'type', 'loss');
    await expect(page.locator('[id^="preview-incident-loss-"]')).toHaveCount(1);
    await page.locator(`#preview-incident-loss-${episode.id}`).getByRole('link').click();
    await connected(page);
    await expect(page.locator('#preview-loss-evidence > div.preview-incident-evidence')).toHaveCount(1);
    await expect(page.locator('#preview-loss-evidence')).toContainText('Collection unavailable');
    const lossURL = page.url();
    await page.getByRole('link', { name: 'View latest check result', exact: true }).click();
    await connected(page);
    await expect(page.locator('#overview-panel')).toContainText('worker execution timed out');
    await expect(page.locator('#overview-panel')).toContainText('Healthy');
    await page.locator('#overview-panel [data-overview-close]').click();
    await expectInvestigationReturn(page, lossURL, `loss:${episode.id}`);
    await checkpoint(page, testInfo, 'collection-loss-retains-target-health');

    // Exhaust the real HTTP 503 deliveries. An operator retry while acknowledged
    // must keep both the immutable notification and the explicit hold.
    await expect.poll(async () => (await occurrence(request, episode.id))?.status, { timeout: 60_000 }).toBe('exhausted');
    const exhausted = await occurrence(request, episode.id);
    expect(exhausted.attempt_count).toBe(3);
    await expect(page.locator('section[aria-labelledby=preview-delivery-heading]')).toContainText('HTTP 503');
    await page.locator('#preview-incident-ack-form textarea[name=note]').fill('Investigating this runner and later affected results');
    await reconnect(page);
    await expect(page.locator('#preview-incident-ack-form textarea[name=note]')).toHaveValue('Investigating this runner and later affected results');
    await acknowledge(page, 'Investigating this runner and later affected results');
    await page.goto('/incidents?type=loss');
    await connected(page);
    await expect(page.locator(`#preview-incident-loss-${episode.id}`)).toContainText('Acknowledged');
    await incidentNavigation(page, request, { health: 0, monitoring: 0 });
    await checkpoint(page, testInfo, 'acknowledged-monitoring-loss-inventory');
    await page.locator(`#preview-incident-loss-${episode.id}`).getByRole('link').click();
    await connected(page);
    await mode(request, { webhook: 'ok' });
    const retry = page.locator(`#preview-retry-${opening.id}`);
    await retry.getByLabel('Reason for retry', { exact: true }).fill('Local receiver repaired; keep acknowledgement active');
    await reconnect(page);
    await expect(retry.getByLabel('Reason for retry', { exact: true })).toHaveValue('Local receiver repaired; keep acknowledgement active');
    await keyboardSubmit(page, retry.getByRole('button', { name: 'Retry notification', exact: true }));
    await expect(page.locator('section[aria-labelledby=preview-delivery-heading]')).toContainText('Acknowledgement');
    expect((await occurrence(request, episode.id)).attempt_count).toBe(3);

    // The runner keeps executing while controller transport is partitioned.
    // Its other two results join the same acknowledged monitoring episode.
    const blockedAt = Date.now();
    await mode(request, { offline_installations: [runner.id] });
    expect((await grouped(request, 3)).id).toBe(episode.id);
    await expect(page.locator('#preview-loss-evidence > div.preview-incident-evidence')).toHaveCount(3);
    await expect(page.getByRole('table', { name: 'Active acknowledgement', exact: true })).toBeVisible();
    expect((await detail(request, episode.id)).acknowledgement_mode).toBe('until_incident_ends');
    expect((await snapshot(request)).occurrences.filter((row) => row.monitoring_incident_id === episode.id && row.kind === 'firing')).toHaveLength(1);
    expect((await occurrence(request, episode.id)).attempt_count).toBe(3);
    await page.setViewportSize({ width: 320, height: 740 });
    await checkpoint(page, testInfo, 'runner-outage-one-acknowledged-episode-320');
    await page.reload();
    await connected(page);
    await expect(page.getByRole('table', { name: 'Active acknowledgement', exact: true })).toBeVisible();

    await keyboardSubmit(page, page.getByRole('button', { name: 'End acknowledgement', exact: true }));
    await expect.poll(async () => (await occurrence(request, episode.id))?.status, { timeout: 45_000 }).toBe('delivered');
    const delivered = await occurrence(request, episode.id);
    expect(delivered.id).toBe(exhausted.id);
    expect(delivered.payload).toEqual(exhausted.payload);
    expect(delivered.destination).toBe(exhausted.destination);
    expect(delivered.attempt_count).toBe(4);
    const receipts = await (await request.get(`${fixtureURL}/records`)).json().then(unpackAPI);
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
    await expect(page.locator('#incident-page, #overview-panel').filter({has: page.locator('#preview-loss-evidence')})).toContainText('Monitoring restored');
    await expect(page.getByRole('table', { name: 'Active acknowledgement', exact: true })).toHaveCount(0);
    const ended = await detail(request, episode.id);
    expect(ended.status).toBe('closed');
    expect(ended.closure_reason).toBe('monitoring_restored');
    expect(ended.acknowledgement_mode).toBeNull();
    expect(ended.closing_evidence.length).toBeGreaterThan(0);
    expect(ended.closing_evidence.every((row) => row.knowledge === 'fresh' && row.observation_id && row.source_at)).toBe(true);
    await expect.poll(async () => {
      const records = (await (await request.get(`${fixtureURL}/transport-records`)).json().then(unpackAPI)).records;
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
    await page.goto('/incidents');
    await connected(page);
    const healthRow = page.locator(`#preview-incident-health-${health.id}`);
    const lossRow = page.locator(`#preview-incident-loss-${loss.id}`);
    await expect(healthRow).toContainText('Health failure');
    await expect(lossRow).toContainText('Monitoring loss');
    await expect(page.getByRole('table', {name: 'Incidents'}).locator('tbody tr').first()).toHaveAttribute('id', `preview-incident-health-${health.id}`);
    await expect(healthRow.locator('td').first()).toHaveText('Critical');
    await checkpoint(page, testInfo, 'next-incidents-mixed');
    const search = page.getByRole('combobox', {name: 'Search incidents'});
    await search.click();
    await page.getByRole('option', {name: 'Severity', exact: true}).click();
    await page.getByRole('option', {name: /^Critical/}).click();
    await expect(healthRow).toBeVisible();
    await expect(lossRow).toHaveCount(0);
    await page.getByRole('link', {name: 'Remove Severity filter'}).click();
    await expect(lossRow).toBeVisible();
    await search.click();
    await page.getByRole('option', {name: 'Acknowledgement', exact: true}).click();
    await page.getByRole('option', {name: /^Acknowledged/}).click();
    await expect(page.getByText('No incidents match these filters.')).toBeVisible();
    await page.getByRole('link', {name: 'Remove Acknowledgement filter'}).click();
    await expect(healthRow).toBeVisible();
    await search.click();
    await page.getByRole('option', {name: 'Opened', exact: true}).click();
    await page.getByRole('option', {name: /^Last 24 hours/}).click();
    await expect(healthRow).toBeVisible();
    await expect(lossRow).toBeVisible();
    await page.getByRole('link', {name: 'Remove Opened filter'}).click();
    await expect(page.getByRole('link', {name: 'Remove Opened filter'})).toHaveCount(0);
    await search.fill('does not match any incident');
    await search.press('Enter');
    await expect(page.getByText('No incidents match these filters.')).toBeVisible();
    await page.getByRole('button', {name: 'Edit Status filter: Open'}).click();
    await page.getByRole('option', {name: /^Closed/}).click();
    await expect(page.getByRole('button', {name: 'Edit Status filter: Closed'})).toBeVisible();
    await expect(page.getByRole('link', {name: 'Clear search text'})).toBeVisible();
    await page.getByRole('link', {name: 'Remove Status filter'}).click();
    await expect(page).toHaveURL(/status=all/);
    await search.click();
    await page.getByRole('option', {name: 'Status', exact: true}).click();
    await page.getByRole('option', {name: /^Open/}).click();
    await expect(page.getByRole('button', {name: 'Edit Status filter: Open'})).toBeVisible();
    await page.getByRole('link', {name: 'Clear search text'}).click();
    await expect(lossRow).toBeVisible();
    await search.click();
    await page.getByRole('option', {name: 'Type', exact: true}).click();
    await page.getByRole('option', {name: /Monitoring loss/}).click();
    await expect(healthRow).toHaveCount(0);
    await search.press('ArrowLeft');
    const typeEditor = page.getByRole('combobox', {name: 'Type', exact: true});
    await expect(typeEditor).toHaveValue('Monitoring loss');
    await typeEditor.press('ArrowLeft');
    const statusEditor = page.getByRole('combobox', {name: 'Status', exact: true});
    await expect(statusEditor).toHaveValue('Open');
    await statusEditor.press('ArrowRight');
    await expect(typeEditor).toHaveValue('Monitoring loss');
    await typeEditor.press('ArrowRight');
    await expect(search).toBeFocused();
    await search.press('Escape');
    await lossRow.getByRole('link').click();
    const incidentPanel = page.getByRole('dialog');
    await expect(incidentPanel.getByRole('heading', {name: 'Affected results'})).toBeVisible();
    await expect(lossRow).toBeVisible();
    await incidentPanel.getByRole('heading', {level: 2}).press('Escape');
    await expect(incidentPanel).toHaveCount(0);
    await expect(lossRow.getByRole('link')).toBeFocused();
    await lossRow.getByRole('link').click();
    await expect(page.locator('main')).toContainText('Collection unavailable');
    const lossURL = page.url();
    await incidentPanel.getByRole('link', {name: 'View latest check result'}).click();
    await expect(page.locator('#overview-panel .preview-result-measurement')).toContainText('Collection unavailable');
    await expect(page).toHaveURL(url => url.searchParams.get('inspect')?.split(',').at(-1) === `result:${stream.id}`);
    await page.locator('#overview-panel [data-overview-close]').click();
    await expectInvestigationReturn(page, lossURL, `loss:${loss.id}`);
    await connected(page);
    await page.locator('#overview-panel [data-overview-close]').click();
    const typeChip = page.getByRole('button', {name: 'Edit Type filter: Monitoring loss'});
    await expect(typeChip).toBeVisible();
    await typeChip.click();
    await page.getByRole('option', {name: /Health failure/}).click();
    await search.press('Escape');
    await healthRow.getByRole('link').click();
    await expect(page.getByRole('heading', {name: 'Recorded failure'})).toBeVisible();
    await expect(page.locator('main')).toContainText('Critical');
    await expect(page.locator('main')).toContainText('Measured');
    await page.setViewportSize({width: 320, height: 844});
    await expect(incidentPanel).toHaveAttribute('aria-modal', 'true');
    await checkpoint(page, testInfo, 'next-health-incident-320');
    await page.setViewportSize({width: 1280, height: 900});
    await overview.goto('/');
    await connected(overview);
    const row = overview.locator(`#preview-attention #result-row-${stream.id}`);
    await expect(row).toContainText('Critical');
    await expect(row).toContainText('Collection unavailable');
    await incidentNavigation(overview, request, { health: 1, monitoring: 1 });
    await checkpoint(overview, testInfo, 'overview-independent-health-and-monitoring-desktop');

    // Every shared shell must preserve both live counts on direct load and
    // reconnect, including views that formerly built their own navigation.
    for (const route of ['/coverage', '/coverage/publishers', '/maintenance', '/maintenance/new', '/configuration/rules', '/configuration/rules/new', '/runners', '/notifications', '/guide']) {
      await navigation.goto(route);
      await connected(navigation);
      await incidentNavigation(navigation, request, { health: 1, monitoring: 1 });
      await reconnect(navigation);
      await incidentNavigation(navigation, request, { health: 1, monitoring: 1 });
    }
    await navigation.goto('/coverage');
    await connected(navigation);

    await page.goto(`/incidents/health/${health.id}/full`);
    await connected(page);
    await acknowledge(page, 'Health investigation does not acknowledge collection loss');
    await expect(page.getByRole('table', { name: 'Active acknowledgement', exact: true })).toBeVisible();
    await expect(row).toBeVisible();
    await incidentNavigation(overview, request, { health: 0, monitoring: 1 });
    await incidentNavigation(navigation, request, { health: 0, monitoring: 1 });
    await overview.setViewportSize({ width: 390, height: 844 });
    await checkpoint(overview, testInfo, 'overview-acknowledged-health-still-needs-monitoring-390');

    await page.goto(`/incidents/loss/${loss.id}/full`);
    await connected(page);
    await acknowledge(page, 'Collection investigation acknowledged independently');
    await expect(row).toContainText('Critical');
    await incidentNavigation(overview, request, { health: 0, monitoring: 0 });
    await incidentNavigation(navigation, request, { health: 0, monitoring: 0 });
    await overview.reload();
    await connected(overview);
    await reconnect(overview);
    await expect(row).toContainText('Critical');
    expect((await streams(request)).items.find((item) => item.id === stream.id).current.health).toBe('CRIT');

    await page.goto(`/incidents/health/${health.id}/full`);
    await connected(page);
    await page.getByRole('button', { name: 'End acknowledgement', exact: true }).click();
    await expect(page.getByRole('table', { name: 'Active acknowledgement', exact: true })).toHaveCount(0);
    await expect(row).toContainText('Critical');
    await incidentNavigation(overview, request, { health: 1, monitoring: 0 });
    await overview.setViewportSize({ width: 320, height: 740 });
    await checkpoint(overview, testInfo, 'overview-acknowledged-monitoring-still-needs-health-320');
    await acknowledge(page, 'Resume health investigation');
    await expect(page.getByRole('table', { name: 'Active acknowledgement', exact: true })).toBeVisible();
    await expect(row).toContainText('Critical');

    await page.goto(`/incidents/loss/${loss.id}/full`);
    await connected(page);
    await page.getByRole('button', { name: 'End acknowledgement', exact: true }).click();
    await expect(page.getByRole('table', { name: 'Active acknowledgement', exact: true })).toHaveCount(0);
    await expect(row).toContainText('Collection unavailable');
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
    await page.goto(`/incidents/loss/${episode.id}/full`);
    await connected(page);
    await expect(page.locator('section[aria-labelledby=preview-delivery-heading]')).toContainText('Maintenance');
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
    await expect(page.locator('#incident-page, #overview-panel').filter({has: page.locator('#preview-loss-evidence')})).toContainText('Monitoring restored');
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
    await page.goto(`/incidents/loss/${episode.id}/full`);
    await connected(page);
    await page.getByLabel('Note (optional)', { exact: true }).fill('Preserve this acknowledged monitoring episode across controller restart');
    await keyboardSubmit(page, page.getByRole('button', { name: 'Save acknowledgement', exact: true }));
    await expect(page.getByRole('table', { name: 'Active acknowledgement', exact: true })).toContainText('Preserve this acknowledged monitoring episode');
    const retry = page.locator(`#preview-retry-${original.id}`);
    await retry.getByLabel('Reason for retry', { exact: true }).fill('Retry after controller restart; acknowledgement remains in effect');
    await keyboardSubmit(page, retry.getByRole('button', { name: 'Retry notification', exact: true }));
    await expect(page.locator('section[aria-labelledby=preview-delivery-heading]').getByRole('status'))
      .toContainText('Notification retry requested');
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

    await page.goto(`/incidents/loss/${episode.id}/full`);
    await connected(page);
    await expect(page.getByRole('table', { name: 'Active acknowledgement', exact: true })).toContainText('Preserve this acknowledged monitoring episode across controller restart');
    await expect(page.locator('section[aria-labelledby=preview-delivery-heading]')).toContainText('Acknowledgement');
    await page.setViewportSize({ width: 320, height: 740 });
    await checkpoint(page, testInfo, 'controller-restarted-with-original-held-notification-320');
    await keyboardSubmit(page, page.getByRole('button', { name: 'End acknowledgement', exact: true }));
    await expect.poll(async () => (await occurrence(request, episode.id))?.status).toBe('delivered');
    const delivered = await occurrence(request, episode.id);
    expect(delivered.payload).toEqual(saved.occurrence.payload);
    expect(delivered.attempt_count).toBe(4);
    await healthy(request);
    await expect(page.locator('#incident-page, #overview-panel').filter({has: page.locator('#preview-loss-evidence')})).toContainText('Monitoring restored');
    await expect.poll(async () => (await occurrence(request, episode.id, 'resolved'))?.status).toBe('delivered');
    await checkpoint(page, testInfo, 'monitoring-recovery-after-controller-restart-320');
    await testInfo.attach('monitoring-episode-after-controller-restart', { body: JSON.stringify(await detail(request, episode.id), null, 2), contentType: 'application/json' });
  } finally {
    await healthy(request);
  }
});
