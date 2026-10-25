// Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
// SPDX-License-Identifier: Apache-2.0
import { test, expect } from '@playwright/test';
import { checkpoint, connected, fixtureURL, keyboardSubmit, mode, streams } from '../support/helpers.mjs';

const volumeKey = 'node-a/volume';
const elasticKey = 'service-a/elasticsearch';

async function samples(request, volume = {}, elastic = {}) {
  await mode(request, { grouped_samples: { [volumeKey]: volume, [elasticKey]: elastic } });
}

async function measured(request, source, health, knowledge = 'fresh') {
  let result;
  await expect.poll(async () => {
    result = (await streams(request)).items.find((row) => row.source_id === source);
    return result?.current?.health === health && result?.current?.knowledge === knowledge;
  }, { message: `${source} must report its own ${knowledge} ${health} evidence`, timeout: 60_000 }).toBe(true);
  return result;
}

async function incidents(request, filters = {}) {
  const response = await request.get(`/api/v1/incidents?${new URLSearchParams(filters)}`);
  expect(response.ok(), await response.text()).toBe(true);
  return response.json();
}

async function detail(request, id, filters = {}) {
  const response = await request.get(`/api/v1/incidents/${id}?${new URLSearchParams(filters)}`);
  expect(response.ok(), await response.text()).toBe(true);
  return response.json();
}

async function reset(request) {
  await mode(request, { webhook: 'ok', offline_installations: [] });
  const healthy = { used_percent: 40, writes_blocked: false, available: true, sample_age_seconds: 0 };
  await samples(request, healthy, healthy);
  await measured(request, 'linux-volume-monitoring', 'OK');
  await measured(request, 'elasticsearch-monitoring', 'OK');
  await expect.poll(async () => (await incidents(request)).total).toBe(0);
}

async function opened(request, count) {
  let group;
  await expect.poll(async () => {
    const list = await incidents(request);
    group = list.items[0];
    return list.total === 1 && group.incident_kind === 'condition' && group.open_contribution_count === count;
  }).toBe(true);
  return group;
}

async function acknowledge(page, note) {
  await page.locator('#ack-note').fill(note);
  await keyboardSubmit(page, page.locator('#acknowledgement-form').getByRole('button', { name: 'Acknowledge', exact: true }));
  await expect(page.locator('#active-acknowledgement')).toContainText(note);
}

async function reconnect(page) {
  await page.evaluate(() => window.liveSocket.disconnect());
  await expect(page.locator('[data-phx-main]')).not.toHaveClass(/phx-connected/);
  await page.evaluate(() => window.liveSocket.connect());
  await connected(page);
}

test('one incident keeps independent evidence, filtered severity and reviewed acknowledgement through corroboration', async ({ page, request }, testInfo) => {
  const errors = [];
  page.on('pageerror', (error) => errors.push(error.message));
  await reset(request);
  await samples(request, { used_percent: 96 });
  const volume = await measured(request, 'linux-volume-monitoring', 'CRIT');
  const group = await opened(request, 1);
  await page.goto(`/incidents/${group.id}`);
  await connected(page);
  await expect(page.locator('#shared-incident-heading')).toContainText('Search storage capacity');
  await expect(page.locator('#condition-contributors .condition-contribution')).toHaveCount(1);
  await expect(page.locator('#condition-other-results')).toContainText('Last confirmed healthy evidence');
  await page.locator('#ack-note').fill('Reviewing independent storage evidence');

  // A later equivalent observer changes membership, without changing reviewed severity or impacts.
  await samples(request, {}, { used_percent: 92 });
  const elastic = await measured(request, 'elasticsearch-monitoring', 'WARN');
  expect((await opened(request, 2)).id).toBe(group.id);
  await expect(page.locator('#condition-contributors .condition-contribution')).toHaveCount(2);
  await expect(page.locator('#ack-note')).toHaveValue('Reviewing independent storage evidence');
  await expect(page.locator('#acknowledgement-form button[type="submit"], #acknowledgement-form button[phx-disable-with]')).toBeEnabled();
  await reconnect(page);
  await expect(page.locator('#ack-note')).toHaveValue('Reviewing independent storage evidence');
  await acknowledge(page, 'Reviewing independent storage evidence');
  await expect(page.locator('#condition-coverage')).toContainText('0 of 2');
  await expect(page.locator('#condition-contributors')).toContainText('Covered by the incident acknowledgement');
  await checkpoint(page, testInfo, 'shared-incident-independent-evidence-desktop');

  // A per-result link remains available for truly individual controls.
  const before = await detail(request, group.id);
  const contribution = before.contributions.find((row) => row.incident.stream_id === volume.id);
  await page.goto(`/incidents/${contribution.incident.id}`);
  await connected(page);
  await expect(page.locator('#contribution-parent')).toContainText('shared incident');
  await expect(page.getByRole('button', { name: 'Acknowledge this result only', exact: true })).toBeVisible();
  await expect(page.locator('#incident-measurements')).toContainText('Contribution measurement history');
  await expect(page.locator('#incident-measurements')).toContainText('Search data volume is 96% used');
  await expect(page.locator('#incident-measurements')).toContainText('Critical');
  await expect(page.locator('#incident-measurements')).not.toContainText('No retained evidence yet');
  await expect(page.locator('#incident-occurrences')).toContainText('Notifications and delivery attempts are recorded on the shared incident.');
  await expect(page.locator('#incident-occurrences')).not.toContainText('No notifications yet');
  await checkpoint(page, testInfo, 'individual-contribution-evidence-and-shared-history');
  await page.locator('#contribution-shared-notifications').click();
  await expect(page).toHaveURL(new RegExp(`/incidents/${group.id}\\?[^#]*notification_status=all[^#]*#incident-occurrences$`));
  await connected(page);
  await expect(page.locator('#shared-incident-heading')).toContainText('Search storage capacity');
  await expect(page.locator('#condition-notification-status')).toHaveValue('all');
  await expect(page.locator('#incident-occurrences .notification-requested-scope')).toContainText('Critical severity');

  await page.goto(`/incidents?runner_id=${elastic.runner_id}`);
  await connected(page);
  const matching = await incidents(request, { runner_id: elastic.runner_id });
  expect(matching.total).toBe(1);
  expect(matching.items[0].health).toBe('CRIT');
  expect(matching.items[0].matching_result_count).toBe(1);
  const link = page.getByRole('link', { name: 'Search storage capacity', exact: true });
  await expect(link).toHaveCount(1);
  await expect(link.locator('xpath=ancestor::tr')).toContainText('Critical');
  await expect(link.locator('xpath=ancestor::tr')).toContainText(/1 of 2/);
  await page.setViewportSize({ width: 390, height: 844 });
  await checkpoint(page, testInfo, 'shared-incident-filtered-list-mobile');
  await link.click();
  await expect(page.locator('#condition-contributors .condition-contribution')).toHaveCount(2);
  await expect(page.getByRole('link', { name: 'Choose maintenance scope', exact: true })).toHaveAttribute('href', '/maintenance/new');
  await page.setViewportSize({ width: 320, height: 740 });
  const investigationOrder = await page.evaluate(() => ({
    evidence: document.querySelector('#condition-contributors .condition-measurement').getBoundingClientRect().top,
    controls: document.querySelector('#incident-controls').getBoundingClientRect().top,
  }));
  expect(investigationOrder.evidence).toBeLessThan(investigationOrder.controls);
  await keyboardSubmit(page, page.locator('#incident-acknowledgement-shortcut'));
  await expect(page.locator('#incident-acknowledgement')).toBeFocused();
  await expect(page.locator('#incident-acknowledgement-heading')).toBeInViewport();
  await checkpoint(page, testInfo, 'shared-incident-acknowledgement-320');
  expect(errors).toEqual([]);
  await reset(request);
});

test('maintained new impact ends shared acknowledgement while individual evidence and delivery scope stay clear', async ({ page, request }, testInfo) => {
  await reset(request);
  await samples(request, { used_percent: 96 }, { used_percent: 96 });
  const volume = await measured(request, 'linux-volume-monitoring', 'CRIT');
  const elastic = await measured(request, 'elasticsearch-monitoring', 'CRIT');
  const group = await opened(request, 2);

  // Create the hold through the real maintenance selection/review flow.
  await page.goto(`/maintenance/new?check_id=${elastic.assignment_id}`);
  await connected(page);
  await page.locator('#maintenance-name').fill('Elasticsearch storage work');
  await page.locator('#maintenance-reason').fill('Only the service-side observer is maintained');
  await page.locator('#maintenance-preview-button').click();
  await expect(page.locator('#maintenance-preview-summary')).toContainText('1 result');
  await page.locator('#maintenance-save').click();
  await expect(page.locator('#maintenance-saved')).toContainText('Active');
  const maintenanceURL = page.url();

  await page.goto(`/incidents/${group.id}`);
  await connected(page);
  await acknowledge(page, 'Reviewing capacity while service maintenance continues');
  await samples(request, {}, { writes_blocked: true });
  await expect.poll(async () => (await detail(request, group.id)).incident.impacts.map((impact) => impact.key)).toEqual(['writes-blocked']);
  await expect(page.locator('#active-acknowledgement')).toHaveCount(0);
  await expect(page.locator('#ack-error')).toContainText('changed');
  await expect(page.locator('.flash').filter({ hasText: 'Acknowledgement recorded.' })).toHaveCount(0);
  await expect(page.locator('#condition-impacts')).toContainText('Search index writes are blocked');
  await expect(page.locator('#condition-coverage')).toContainText('1 of 2');
  await expect(page.locator('#condition-contributors')).toContainText('Elasticsearch storage work');
  const current = await detail(request, group.id);
  const impact = current.occurrences.find((notice) => notice.payload.requested_fact?.key === 'writes-blocked');
  expect(impact.gates).toContain('maintenance');
  expect(impact.attempt_count).toBe(0);
  await page.setViewportSize({ width: 390, height: 844 });
  await checkpoint(page, testInfo, 'new-impact-partial-maintenance-mobile');
  await page.locator('#review-acknowledgement').click();
  await expect(page.locator('#ack-reviewed-impacts')).toContainText('Search index writes are blocked');

  // Ending just that hold releases the same immutable impact occurrence.
  await page.goto(maintenanceURL);
  await connected(page);
  await page.locator('#maintenance-cancel').click();
  await page.locator('#maintenance-cancel-reason').fill('Service-side storage work completed');
  await page.locator('#maintenance-confirm-cancel').click();
  await expect(page.locator('#maintenance-saved')).toContainText('Ended early');
  await expect.poll(async () => {
    const view = await detail(request, group.id, { notification_status: 'all' });
    return view.occurrences.find((notice) => notice.id === impact.id)?.status;
  }).toBe('delivered');
  const receipts = await (await request.get(`${fixtureURL}/records`)).json();
  expect(receipts.records.some((receipt) => receipt.payload.occurrence_id === impact.id)).toBe(true);

  await samples(request, { available: false });
  await measured(request, 'linux-volume-monitoring', 'CRIT', 'unavailable');
  await page.goto(`/incidents/${group.id}`);
  await connected(page);
  await expect(page.locator('#condition-contributors')).toContainText('Collection is unavailable');
  expect((await detail(request, group.id)).counts.open).toBe(2);
  await samples(request, { available: true, used_percent: 40 });
  await measured(request, 'linux-volume-monitoring', 'OK');
  await expect(page.locator('#shared-incident-heading')).toContainText('1 currently failing');
  await page.getByRole('link', { name: 'Recovered & withdrawn (1)', exact: true }).click();
  await expect(page.locator('#condition-contributors')).toContainText('Measured recovery');
  await page.setViewportSize({ width: 1280, height: 800 });
  await checkpoint(page, testInfo, 'partial-recovery-retained-contribution');
  await reset(request);
  await page.goto(`/incidents/${group.id}`);
  await connected(page);
  await expect(page.locator('#condition-status')).toContainText('Measured recovery');
  await samples(request, { used_percent: 96 });
  const recurringVolume = await measured(request, 'linux-volume-monitoring', 'CRIT');
  const recurrence = await opened(request, 1);
  expect(recurrence.id).not.toBe(group.id);
  expect((await detail(request, recurrence.id)).incident.acknowledgement_mode).toBeNull();
  await expect(page.locator('#condition-status')).toContainText('Measured recovery');
  await checkpoint(page, testInfo, 'closed-episode-does-not-borrow-recurrence');
  const closed = await detail(request, group.id, { state: 'history' });
  const closedVolume = closed.contributions.find((row) => row.incident.stream_id === volume.id);
  await page.goto(`/incidents/${closedVolume.incident.id}`);
  await connected(page);
  await expect(page.locator('#incident-measurements')).toContainText('Search data volume is 96% used');
  await expect(page.locator('#incident-measurements')).toContainText('Search data volume is 40% used');
  await expect(page.locator('#incident-measurements')).not.toContainText('No retained evidence yet');
  expect(recurringVolume.current.confirmed_observation_id).toMatch(/^[0-9a-f-]{36}$/);
  await expect(page.locator(`#incident-measurements #evidence-${recurringVolume.current.confirmed_observation_id}`)).toHaveCount(0);
  await reset(request);
});

test('real contributor returns paginate history without losing reviewed drafts or duplicating incidents', async ({ page, request }, testInfo) => {
  await reset(request);
  await samples(request, { used_percent: 96 });
  await measured(request, 'linux-volume-monitoring', 'CRIT');
  const group = await opened(request, 1);
  await page.goto(`/incidents/${group.id}`);
  await connected(page);
  await acknowledge(page, 'Shared condition remains under investigation');
  for (let index = 0; index < 26; index += 1) {
    await samples(request, {}, { used_percent: 96 });
    await measured(request, 'elasticsearch-monitoring', 'CRIT');
    await samples(request, {}, { used_percent: 40 });
    await measured(request, 'elasticsearch-monitoring', 'OK');
  }
  const populated = await detail(request, group.id);
  expect(populated.counts.total).toBe(27);
  expect(populated.counts.open).toBe(1);
  expect(populated.counts.recovered).toBe(26);
  expect(populated.incident.acknowledgement_mode).toBe('until_incident_ends');
  expect((await incidents(request)).total).toBe(1);
  await page.locator('#ack-mode').selectOption('duration');
  await page.locator('#ack-duration').selectOption('custom');
  await page.locator('#ack-days').fill('14');
  await page.locator('#ack-note').fill('Preserve this reviewed draft through contribution pages');
  await page.getByRole('link', { name: 'Recovered & withdrawn (26)', exact: true }).click();
  await expect(page.locator('#condition-contributors .condition-contribution')).toHaveCount(25);
  await page.locator('#contributions-top').getByRole('link', { name: /Next/ }).click();
  await expect(page.locator('#condition-contributors .condition-contribution')).toHaveCount(1);
  await expect(page.locator('#ack-days')).toHaveValue('14');
  await expect(page.locator('#ack-note')).toHaveValue('Preserve this reviewed draft through contribution pages');
  await reconnect(page);
  await expect(page.locator('#condition-contributors .condition-contribution')).toHaveCount(1);
  await expect(page.locator('#ack-days')).toHaveValue('14');
  await expect(page.locator('#ack-note')).toHaveValue('Preserve this reviewed draft through contribution pages');
  await page.setViewportSize({ width: 320, height: 740 });
  await checkpoint(page, testInfo, 'bounded-contribution-history-reconnect-320');
  await page.locator('#condition-notification-status').selectOption('all');
  await expect(page.locator('#ack-days')).toHaveValue('14');
  await expect(page.locator('#ack-note')).toHaveValue('Preserve this reviewed draft through contribution pages');
  const after = await detail(request, group.id, { notification_status: 'all' });
  expect(after.notification_counts.total).toBe(populated.notification_counts.total);
  await reset(request);
});
