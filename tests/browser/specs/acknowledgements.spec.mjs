// Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
// SPDX-License-Identifier: Apache-2.0
import { test, expect } from '@playwright/test';
import { reviewedMaintenance, cancelReviewedMaintenance, checkpoint, connected, fixtureURL, incidentNavigation, keyboardFill, keyboardSubmit, measured, mode, sectionTabs, snapshot, streams } from '../support/helpers.mjs';
import { demoAssignments } from '../support/helpers.mjs';

let filesystemId, httpId, consumerId;
test.beforeEach(async ({ request }) => {
  const checks = await demoAssignments(request);
  ({ filesystem: { id: filesystemId }, http: { id: httpId }, consumer: { id: consumerId } } = checks);
});

// This UI journey needs a healthy unrelated filesystem, independently of the
// Docker VM's real utilization. Keep real collection and require a fresh result.
test.beforeEach(async ({ request }) => {
  const filesystem = (await snapshot(request)).assignments.find((row) => row.id === filesystemId);
  const response = await request.put(`/api/v1/assignments/${filesystemId}`, {
    data: { revision: filesystem.revision, params: { ...filesystem.params, warn_percent: 99, crit_percent: 100 } },
  });
  expect(response.ok(), await response.text()).toBe(true);
  await measured(request, filesystemId);
});

async function acknowledgementFits(page) {
  const layout = await page.locator('#acknowledgement-form').evaluate((form) => {
    const boundary = form.getBoundingClientRect();
    const outside = [...form.querySelectorAll('*')].flatMap((element) => {
      const box = element.getBoundingClientRect();
      return box.width && (box.left < boundary.left - 1 || box.right > boundary.right + 1)
        ? [{ tag: element.tagName, id: element.id, left: box.left, right: box.right }]
        : [];
    });
    const submit = form.querySelector('button[phx-disable-with]');
    return { outside, width: form.clientWidth, scrollWidth: form.scrollWidth,
      submitHeight: submit.getBoundingClientRect().height };
  });
  expect(layout.outside, 'Acknowledgement controls must not be clipped inside their panel').toEqual([]);
  expect(layout.scrollWidth).toBeLessThanOrEqual(layout.width + 1);
  expect(layout.submitHeight, 'The submit label must fit a normal button').toBeLessThanOrEqual(88);
}

test('acknowledgements preserve reviewed drafts, support long holds and release original notifications', async ({ page, request }, testInfo) => {
  const errors = [];
  page.on('pageerror', (error) => errors.push(error.message));
  await mode(request, { ready: true, webhook: 'ok' });
  await measured(request, httpId);
  const maintenance = await reviewedMaintenance(request, httpId, 7200, 'Browser acknowledgement review');
  await mode(request, { ready: false });
  await measured(request, httpId, 'CRIT');
  const incident = (await snapshot(request)).incidents.find((item) => item.assignment_id === httpId && item.status === 'open');
  async function currentIncident() {
    return (await snapshot(request)).incidents.find((item) => item.id === incident.id);
  }
  const listing = await page.context().newPage();
  const overview = await page.context().newPage();
  const result = (await streams(request)).items.find((row) => row.assignment_id === httpId);
  await overview.goto('/');
  await connected(overview);
  await expect(overview.locator(`#overview-attention #result-${result.id}`)).toBeVisible();
  await expect(overview.locator('#overview-attention .checks-results-table')).toHaveCount(1);
  await incidentNavigation(overview, request, { health: 1, monitoring: 0 });
  await checkpoint(overview, testInfo, 'overview-unacknowledged-compact-result-desktop');
  await overview.locator(`#result-${result.id} .checks-result-link`).click();
  await expect(overview).toHaveURL((url) => url.pathname === `/checks/${result.id}` && url.searchParams.get('return_to') === '/');
  await overview.locator('a.back').click();
  await expect(overview).toHaveURL((url) => url.pathname === '/');
  await connected(overview);
  await listing.goto('/incidents');
  await connected(listing);
  await sectionTabs(listing, 'Incidents', 'Incident views', 'Target health');
  // A rebuilt deployment must bypass previously cached, unversioned assets.
  await expect(listing.locator('link[rel="stylesheet"]')).toHaveAttribute('href', /\/assets\/app-[a-f0-9]+\.css\?vsn=d$/);
  await expect(listing.locator('script[src]')).toHaveAttribute('src', /\/assets\/app-[a-f0-9]+\.js\?vsn=d$/);
  await expect(listing.locator('#incident-attention-count')).toHaveText('1');
  await page.goto(`/incidents/${incident.id}`);
  await connected(page);
  const form = page.locator('#acknowledgement-form');
  await expect(page.locator('#ack-mode')).toHaveValue('until_incident_ends');
  await keyboardFill(page, page.locator('#ack-note'), 'Investigating until the incident ends');
  await keyboardSubmit(page, form.getByRole('button', { name: 'Acknowledge', exact: true }));
  await expect(page.locator('#active-acknowledgement')).toContainText('Investigating until the incident ends');
  await expect(page.locator('#acknowledgement-lifetime')).toContainText('Until this incident ends');
  expect((await currentIncident()).acknowledged_until).toBeNull();
  await acknowledgementFits(page);
  await checkpoint(page, testInfo, 'indefinite-acknowledgement-desktop');
  await expect(listing.locator(`#incident-row-${incident.id}`)).toHaveClass('incident-acknowledged');
  await expect(listing.locator(`#incident-row-${incident.id} .badge.acknowledged`)).toHaveText('Acknowledged');
  await expect(listing.locator(`#incident-row-${incident.id} .badge.crit`)).toContainText('Critical');
  await expect(listing.locator(`#incident-row-${incident.id} .badge.open`)).toHaveText('Open');
  const openedText = await listing.locator(`#incident-row-${incident.id} td`).nth(3).textContent();
  expect(openedText).toMatch(/Opened\s+\S/);
  await expect(listing.locator('#incident-attention-count')).toHaveText('0');
  await expect(overview.locator(`#overview-attention #result-${result.id}`)).toHaveCount(0);
  await expect(overview.locator('#overview-attention')).toContainText('No results currently need attention');
  await incidentNavigation(overview, request, { health: 0, monitoring: 0 });
  await overview.reload();
  await connected(overview);
  await overview.evaluate(() => window.liveSocket.disconnect());
  await expect(overview.locator('[data-phx-main]')).not.toHaveClass(/phx-connected/);
  await overview.evaluate(() => window.liveSocket.connect());
  await connected(overview);
  await expect(overview.locator(`#overview-attention #result-${result.id}`)).toHaveCount(0);
  const retained = (await streams(request)).items.find((row) => row.id === result.id);
  expect(retained.current.health).toBe('CRIT');
  await overview.setViewportSize({ width: 390, height: 844 });
  await checkpoint(overview, testInfo, 'overview-acknowledged-result-hidden-after-reconnect-390');
  await listing.reload();
  await connected(listing);
  await expect(listing.locator('#incident-navigation')).toHaveAttribute('aria-label', 'Incidents · 0 unacknowledged open incidents');
  await checkpoint(listing, testInfo, 'acknowledged-incident-list');

  await page.locator('#ack-mode').selectOption('duration');
  await page.locator('#ack-duration').selectOption('custom');
  await page.locator('#ack-days').fill('90');
  await page.locator('#ack-hours').fill('3');
  await page.locator('#ack-note').fill('Long investigation with a reviewed deadline');
  await page.keyboard.press('Tab');
  const beforeTick = await page.locator('.live-indicator').innerText();
  await expect(page.locator('.live-indicator')).not.toHaveText(beforeTick);
  await expect(page.locator('#ack-days')).toHaveValue('90');
  await page.evaluate(() => window.liveSocket.disconnect());
  await expect(page.locator('[data-phx-main]')).not.toHaveClass(/phx-connected/);
  await page.evaluate(() => window.liveSocket.connect());
  await connected(page);
  await expect(page.locator('#ack-days')).toHaveValue('90');
  await expect(page.locator('#ack-hours')).toHaveValue('3');
  await expect(page.locator('#ack-note')).toHaveValue('Long investigation with a reviewed deadline');

  // Another operator action invalidates this review, preserving the proposed form.
  const beforeConcurrent = await currentIncident();
  const concurrent = await request.post(`/api/v1/incidents/${incident.id}/acknowledge`, {
    data: { mode: 'duration', seconds: 604800, note: 'Concurrent one-week acknowledgement',
      revision: beforeConcurrent.acknowledgement_revision, attention_revision: beforeConcurrent.attention_revision },
  });
  expect(concurrent.ok(), await concurrent.text()).toBe(true);
  await expect(page.locator('#ack-error')).toContainText('changed');
  await expect(form.getByRole('button', { name: 'Update acknowledgement', exact: true })).toBeDisabled();
  await expect(page.locator('#end-acknowledgement')).toBeDisabled();
  await expect(page.locator('#ack-days')).toHaveValue('90');
  await page.setViewportSize({ width: 390, height: 844 });
  await acknowledgementFits(page);
  await checkpoint(page, testInfo, 'stale-acknowledgement-review-mobile');
  await page.locator('#review-acknowledgement').click();
  await expect(page.locator('#ack-note')).toHaveValue('Long investigation with a reviewed deadline');
  const beforeLongSave = Date.now();
  await keyboardSubmit(page, form.getByRole('button', { name: 'Update acknowledgement', exact: true }));
  await expect.poll(async () => (await currentIncident()).acknowledgement_note).toBe('Long investigation with a reviewed deadline');
  const longDeadline = Date.parse((await currentIncident()).acknowledged_until);
  const duration = (90 * 86400 + 3 * 3600) * 1000;
  expect(longDeadline).toBeGreaterThanOrEqual(beforeLongSave + duration);
  expect(longDeadline).toBeLessThanOrEqual(Date.now() + duration);
  await acknowledgementFits(page);
  await checkpoint(page, testInfo, 'long-acknowledgement-mobile');

  await page.locator('#ack-mode').selectOption('until');
  // datetime-local normalizes zero seconds away; Chromium rejects a fill
  // whose supplied value does not survive that normalization unchanged.
  const expiry = new Date(Date.now() + 86400_000).toISOString().slice(0, 16);
  await page.locator('#ack-expires-at').fill(expiry);
  await page.locator('#ack-note').fill('Explicit UTC expiry checked in the browser');
  await expect(page.getByLabel('Expiry date and time (UTC)')).toBeVisible();
  await page.setViewportSize({ width: 320, height: 740 });
  await acknowledgementFits(page);
  await checkpoint(page, testInfo, 'explicit-UTC-expiry-320');
  await keyboardSubmit(page, form.getByRole('button', { name: 'Update acknowledgement', exact: true }));
  await expect.poll(async () => Date.parse((await currentIncident()).acknowledged_until)).toBe(Date.parse(`${expiry}Z`));
  await expect(page.locator('#active-acknowledgement')).toContainText('Local operator');
  await acknowledgementFits(page);

  await page.locator('#end-acknowledgement').click();
  await expect(page.locator('#active-acknowledgement')).toHaveCount(0);
  await expect(listing.locator(`#incident-row-${incident.id}`)).not.toHaveClass('incident-acknowledged');
  await expect(listing.locator('#incident-attention-count')).toHaveText('1');
  await expect(overview.locator(`#overview-attention #result-${result.id}`)).toBeVisible();
  await incidentNavigation(overview, request, { health: 1, monitoring: 0 });
  await overview.setViewportSize({ width: 320, height: 740 });
  await checkpoint(overview, testInfo, 'overview-ended-acknowledgement-attention-restored-320');
  await overview.close();
  await checkpoint(listing, testInfo, 'incident-attention-restored');
  await listing.close();
  await expect(page.locator('#incident-occurrences')).toContainText('Maintenance');
  await expect(page.locator('#incident-control-history')).toContainText('Explicit UTC expiry checked in the browser');
  const held = (await snapshot(request)).occurrences.find((item) => item.incident_id === incident.id && item.kind === 'firing');
  expect(held.attempt_count).toBe(0);
  await cancelReviewedMaintenance(request, maintenance, 'Finished browser review');
  await expect(page.locator('#incident-occurrences')).toContainText('Receiver accepted', { timeout: 30_000 });
  const delivered = (await snapshot(request)).occurrences.find((item) => item.id === held.id);
  expect(delivered.payload).toEqual(held.payload);
  expect(delivered.attempt_count).toBe(1);
  const receipts = await (await request.get(`${fixtureURL}/records`)).json();
  expect(receipts.records.some((item) => item.payload.occurrence_id === held.id)).toBe(true);
  await page.setViewportSize({ width: 1280, height: 720 });

  await page.locator('#ack-mode').selectOption('until_incident_ends');
  await page.locator('#ack-note').fill('Waiting for confirmed recovery');
  await keyboardSubmit(page, form.getByRole('button', { name: 'Acknowledge', exact: true }));
  await expect(page.locator('#active-acknowledgement')).toBeVisible();
  await mode(request, { ready: true });
  await measured(request, httpId);
  await expect(page.locator('#incident-summary')).toContainText('Measured recovery');
  await expect(page.locator('#acknowledgement-form')).toHaveCount(0);
  await expect(page.locator('#incident-acknowledgement')).toContainText('This incident has ended');
  await expect(page.locator('#incident-control-history')).toContainText('Waiting for confirmed recovery');
  await checkpoint(page, testInfo, 'recovery-ends-acknowledgement-history-retained');
  expect(errors).toEqual([]);
  await testInfo.attach('final-state', { body: JSON.stringify(await snapshot(request), null, 2), contentType: 'application/json' });
});

test('acknowledged critical incidents follow unacknowledged warnings through reload and reconnect', async ({ page, request }, testInfo) => {
  await mode(request, { ready: false, backlog: 6, processing_enabled: true });
  await measured(request, httpId, 'CRIT');
  await measured(request, consumerId, 'WARN');
  const incidents = (await snapshot(request)).incidents.filter((item) => item.status === 'open');
  const critical = incidents.find((item) => item.assignment_id === httpId);
  const warning = incidents.find((item) => item.assignment_id === consumerId);
  const rows = () => page.locator('#incident-list tbody tr').evaluateAll((items) => items.map((item) => item.id));
  await page.goto('/incidents');
  await connected(page);
  await expect.poll(rows).toEqual([`incident-row-${critical.id}`, `incident-row-${warning.id}`]);
  await expect(page.locator('#incident-attention-count')).toHaveText('2');
  await page.locator(`#incident-row-${critical.id} a`).first().click();
  await page.locator('#ack-note').fill('Already investigating this critical incident');
  await page.locator('#acknowledgement-form').getByRole('button', { name: 'Acknowledge', exact: true }).click();
  await expect(page.locator('#active-acknowledgement')).toBeVisible();
  await page.goto('/incidents');
  await connected(page);
  await expect.poll(rows).toEqual([`incident-row-${warning.id}`, `incident-row-${critical.id}`]);
  await expect(page.locator('#incident-attention-count')).toHaveText('1');
  await checkpoint(page, testInfo, 'warning-before-acknowledged-critical');
  await page.reload();
  await connected(page);
  await page.evaluate(() => window.liveSocket.disconnect());
  await expect(page.locator('[data-phx-main]')).not.toHaveClass(/phx-connected/);
  await page.evaluate(() => window.liveSocket.connect());
  await connected(page);
  await expect.poll(rows).toEqual([`incident-row-${warning.id}`, `incident-row-${critical.id}`]);
  await page.setViewportSize({ width: 390, height: 844 });
  await expect(page.locator('#incident-list').getByRole('columnheader')).toHaveCount(5);
  await checkpoint(page, testInfo, 'acknowledged-list-mobile');
  await page.setViewportSize({ width: 320, height: 740 });
  await checkpoint(page, testInfo, 'acknowledged-list-320');
  await page.setViewportSize({ width: 1280, height: 720 });
  await page.locator(`#incident-row-${critical.id} a`).first().click();
  await page.locator('#end-acknowledgement').click();
  await expect(page.locator('#active-acknowledgement')).toHaveCount(0);
  await page.goto('/incidents');
  await connected(page);
  await expect.poll(rows).toEqual([`incident-row-${critical.id}`, `incident-row-${warning.id}`]);
  await expect(page.locator('#incident-attention-count')).toHaveText('2');
  await mode(request, { ready: true, backlog: 2 });
  await measured(request, httpId);
  await measured(request, consumerId);
  await expect(page.locator('#incident-attention-count')).toHaveText('0');
});
