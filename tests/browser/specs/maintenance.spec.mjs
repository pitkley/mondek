// Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
// SPDX-License-Identifier: Apache-2.0
import { test, expect } from '@playwright/test';
import { checkpoint, connected, fixtureURL, keyboardFill, keyboardSubmit, measured, mode, snapshot } from '../support/helpers.mjs';
import { demoAssignments } from '../support/helpers.mjs';

let filesystemId, httpId, consumerId;
test.beforeEach(async ({ request }) => {
  const checks = await demoAssignments(request);
  ({ filesystem: { id: filesystemId }, http: { id: httpId }, consumer: { id: consumerId } } = checks);
});

function lastSunday(year, month) {
  const day = new Date(Date.UTC(year, month + 1, 0));
  day.setUTCDate(day.getUTCDate() - day.getUTCDay());
  return day.toISOString().slice(0, 10);
}

function shiftDate(date, days) {
  const value = new Date(`${date}T12:00:00Z`);
  value.setUTCDate(value.getUTCDate() + days);
  return value.toISOString().slice(0, 10);
}

function displayedDate(date) {
  return new Date(`${date}T12:00:00Z`).toLocaleDateString('en-GB', {
    day: 'numeric', month: 'short', year: 'numeric', timeZone: 'UTC',
  });
}

async function maintenanceJSON(request, path, data) {
  const response = data === undefined ? await request.get(path) : await request.post(path, { data });
  expect(response.ok(), await response.text()).toBe(true);
  return response.json();
}

async function currentSeries(page, request) {
  await expect(page).toHaveURL(/\/maintenance\/series\/[0-9a-f-]{36}(?:\?.*)?$/);
  const id = new URL(page.url()).pathname.split('/').at(-1);
  return maintenanceJSON(request, `/api/v1/maintenance-series/${id}`);
}

async function disconnect(page) {
  await page.evaluate(() => window.liveSocket.disconnect());
  await expect(page.locator('[data-phx-main]')).not.toHaveClass(/phx-connected/);
}

async function reconnect(page) {
  await page.evaluate(() => window.liveSocket.connect());
  await connected(page);
}

async function formFits(page, selector = '#maintenance-form') {
  const bounds = await page.locator(selector).evaluate((form) => {
    const boundary = form.getBoundingClientRect();
    return {
      width: form.clientWidth, scrollWidth: form.scrollWidth,
      outside: [...form.querySelectorAll('*')].flatMap((element) => {
        const box = element.getBoundingClientRect();
        return box.width && (box.left < boundary.left - 1 || box.right > boundary.right + 1)
          ? [{ tag: element.tagName, id: element.id, left: box.left, right: box.right }] : [];
      }),
      buttons: [...form.querySelectorAll('button')].map((button) => ({
        label: button.innerText, height: button.getBoundingClientRect().height,
      })),
    };
  });
  expect(bounds.outside, 'Maintenance controls must remain inside their panel').toEqual([]);
  expect(bounds.scrollWidth).toBeLessThanOrEqual(bounds.width + 1);
  for (const button of bounds.buttons) expect(button.height, button.label).toBeLessThanOrEqual(88);
}

async function currentWindow(page, request) {
  await expect(page).toHaveURL(/\/maintenance\/[0-9a-f-]{36}$/);
  const id = new URL(page.url()).pathname.split('/').at(-1);
  const response = await request.get(`/api/v1/maintenance/${id}`);
  expect(response.ok(), await response.text()).toBe(true);
  return response.json();
}

async function cancelWindow(page, reason) {
  const active = (await page.locator('#maintenance-cancel').innerText()).includes('End maintenance now');
  await page.locator('#maintenance-cancel').click();
  await page.locator('#maintenance-cancel-reason').fill(reason);
  await keyboardSubmit(page, page.locator('#maintenance-confirm-cancel'));
  await expect(page.locator('#maintenance-saved')).toContainText(active ? 'Ended early' : 'Cancelled');
  await expect(page.locator('#maintenance-saved')).toContainText(active ? 'Ended early at' : 'Cancelled at');
  await expect(page.locator('#maintenance-saved')).toContainText('Scheduled end');
  await expect(page.locator('#maintenance-saved')).toContainText('Planned duration');
  await expect(page.locator('#maintenance-form')).toHaveCount(0);
  await expect(page.locator('#maintenance-history')).toContainText(reason);
}

test('schedule exact civil times, preserve drafts through reconnect and review conflicting edits', async ({ page, request }, testInfo) => {
  const year = new Date().getUTCFullYear() + 1;
  const spring = lastSunday(year, 2);
  const autumn = lastSunday(year, 9);
  const errors = [];
  page.on('pageerror', (error) => errors.push(error.message));
  await mode(request, { ready: true, webhook: 'ok' });
  await measured(request, httpId);
  await page.goto('/maintenance');
  await connected(page);
  await page.getByRole('link', { name: 'Schedule maintenance', exact: true }).click();
  await page.locator('#maintenance-search').fill('Local HTTP');
  await expect(page.locator('#maintenance-check-chooser').getByRole('link', { name: 'Schedule just this check', exact: true })).toHaveCount(1);
  await page.locator('#maintenance-check-chooser').getByRole('link', { name: 'Schedule just this check', exact: true }).click();
  await expect(page.locator('#maintenance-form')).toBeVisible();
  await keyboardFill(page, page.locator('#maintenance-name'), 'Autumn deployment window');
  await page.locator('#maintenance-reason').fill('Deploy the service during the repeated local hour');
  await page.locator('#maintenance-scope').selectOption({ index: 1 });
  await expect(page.locator('#maintenance-dynamic-scope')).toContainText('Future matching results');
  await page.locator('#maintenance-timezone').fill('Europe/Berlin');
  await page.locator('#maintenance-start-mode').selectOption('scheduled');
  // datetime-local canonicalizes an all-zero seconds component away.
  await page.locator('#maintenance-start').fill(`${spring}T02:30`);
  await page.locator('#maintenance-end').fill(`${spring}T04:00`);
  await page.locator('#maintenance-preview-button').click();
  await expect(page.locator('#maintenance-error')).toContainText('does not exist');
  await expect(page.locator('#maintenance-name')).toHaveValue('Autumn deployment window');
  await page.locator('#maintenance-start').fill(`${autumn}T02:45`);
  await page.locator('#maintenance-end').fill(`${autumn}T02:15`);
  await expect(page.locator('input[name="window[start_fold]"]')).toHaveCount(2);
  await expect(page.locator('input[name="window[end_fold]"]')).toHaveCount(2);
  await page.locator('input[name="window[start_fold]"][value="earlier"]').check();
  await page.locator('input[name="window[end_fold]"][value="later"]').check();
  await page.setViewportSize({ width: 390, height: 844 });
  await formFits(page);
  await checkpoint(page, testInfo, 'ambiguous-maintenance-times-mobile');

  await page.evaluate(() => window.liveSocket.disconnect());
  await expect(page.locator('[data-phx-main]')).not.toHaveClass(/phx-connected/);
  await page.evaluate(() => window.liveSocket.connect());
  await connected(page);
  await expect(page.locator('#maintenance-name')).toHaveValue('Autumn deployment window');
  await expect(page.locator('input[name="window[start_fold]"][value="earlier"]')).toBeChecked();
  await expect(page.locator('input[name="window[end_fold]"][value="later"]')).toBeChecked();
  await page.locator('#maintenance-preview-button').click();
  await expect(page.locator('#maintenance-preview')).toContainText(String(year));
  await expect(page.locator('#maintenance-preview')).toContainText('00:45');
  await expect(page.locator('#maintenance-preview')).toContainText('01:15');
  await expect(page.locator('#maintenance-preview-summary')).toContainText('1 result across 1 scheduled check');
  await page.setViewportSize({ width: 320, height: 740 });
  await formFits(page);
  await checkpoint(page, testInfo, 'review-maintenance-exact-UTC-320');
  await keyboardSubmit(page, page.locator('#maintenance-save'));
  await expect(page.locator('#maintenance-saved')).toContainText('Upcoming');
  const saved = await currentWindow(page, request);
  expect(Date.parse(saved.starts_at)).toBe(Date.parse(`${autumn}T00:45:00Z`));
  expect(Date.parse(saved.ends_at)).toBe(Date.parse(`${autumn}T01:15:00Z`));
  expect(saved.scope).toBe('target');
  await expect(page.locator('input[name="window[start_fold]"][value="earlier"]')).toBeChecked();
  await expect(page.locator('input[name="window[end_fold]"][value="later"]')).toBeChecked();

  await page.locator('#maintenance-reason').fill('My preserved revision proposal');
  await page.locator('#maintenance-preview-button').click();
  const concurrentPreview = await request.post('/api/v1/maintenance/preview', {
    data: { proposal: { ...saved.proposal, reason: 'Concurrent reviewed maintenance edit' } },
  });
  expect(concurrentPreview.ok(), await concurrentPreview.text()).toBe(true);
  const reviewed = await concurrentPreview.json();
  const changed = await request.post('/api/v1/maintenance/apply', {
    data: { proposal: reviewed.proposal, review_token: reviewed.review_token },
  });
  expect(changed.ok(), await changed.text()).toBe(true);
  await expect(page.locator('#maintenance-stale')).toBeVisible();
  await expect(page.locator('#maintenance-save')).toBeDisabled();
  await page.locator('#maintenance-review-current').click();
  await expect(page.locator('#maintenance-reason')).toHaveValue('My preserved revision proposal');
  await page.locator('#maintenance-preview-button').click();
  await page.locator('#maintenance-save').click();
  await expect(page.locator('#maintenance-saved')).toContainText('My preserved revision proposal');
  const updated = await currentWindow(page, request);
  expect(updated.starts_at).toBe(saved.starts_at);
  expect(updated.ends_at).toBe(saved.ends_at);
  await cancelWindow(page, 'Deployment cancelled after review');
  await page.setViewportSize({ width: 1280, height: 800 });
  await checkpoint(page, testInfo, 'cancelled-maintenance-history-desktop');
  await page.goto(`/maintenance?assignment_id=${httpId}&status=history`);
  await connected(page);
  await expect(page.locator('#maintenance-list')).toContainText('Autumn deployment window');
  expect(errors).toEqual([]);
});

test('default immediate window previews, independent overlaps hold real delivery and ending releases original work', async ({ page, request }, testInfo) => {
  await mode(request, { ready: true, webhook: 'ok' });
  await measured(request, httpId);
  await page.goto(`/maintenance/new?check_id=${httpId}`);
  await connected(page);
  await page.locator('#maintenance-name').fill('Service deployment');
  await page.locator('#maintenance-reason').fill('Keep default time controls usable');
  // Preserve default end time: native input validity must allow ordinary submission.
  await page.locator('#maintenance-preview-button').click();
  await expect(page.locator('#maintenance-preview')).toBeVisible();
  await page.locator('#maintenance-save').click();
  await expect(page.locator('#maintenance-saved')).toContainText('Active');
  const first = await currentWindow(page, request);
  await page.goto(`/maintenance/new?check_id=${httpId}`);
  await connected(page);
  await page.locator('#maintenance-name').fill('Independent overlapping work');
  await page.locator('#maintenance-reason').fill('Both windows must end independently');
  await page.locator('#maintenance-end').fill(new Date(Date.now() + 90 * 86400_000).toISOString().slice(0, 19).replace(/:00$/, ''));
  await page.locator('#maintenance-preview-button').click();
  await expect(page.locator('#maintenance-overlaps')).toContainText('Service deployment');
  await page.setViewportSize({ width: 320, height: 740 });
  await formFits(page);
  await checkpoint(page, testInfo, 'independent-overlap-preview-320');
  await page.locator('#maintenance-save').click();
  let second = await currentWindow(page, request);
  const originalStart = second.starts_at;
  await page.locator('#maintenance-reason').fill('Update an active window without moving its original start');
  const shorterEnd = new Date(Date.now() + 7 * 86400_000).toISOString().slice(0, 19);
  await page.locator('#maintenance-end').fill(shorterEnd.replace(/:00$/, ''));
  await page.locator('#maintenance-preview-button').click();
  await expect(page.locator('#maintenance-preview')).toBeVisible();
  await page.locator('#maintenance-save').click();
  await expect(page.locator('#maintenance-saved')).toContainText('Update an active window');
  second = await currentWindow(page, request);
  expect(second.starts_at).toBe(originalStart);
  expect(Date.parse(second.ends_at)).toBe(Date.parse(`${shorterEnd}Z`));
  await mode(request, { ready: false });
  await measured(request, httpId, 'CRIT');
  const state = await snapshot(request);
  const incident = state.incidents.find((item) => item.assignment_id === httpId && item.status === 'open');
  const held = state.occurrences.find((item) => item.incident_id === incident.id && item.kind === 'firing');
  expect(held.attempt_count).toBe(0);
  await page.goto(`/maintenance/${first.id}`);
  await connected(page);
  await cancelWindow(page, 'First independent activity completed');
  await page.goto(`/incidents/${incident.id}`);
  await connected(page);
  await expect(page.locator('#incident-occurrences')).toContainText('Maintenance');
  await expect(page.locator(`#maintenance-summary-${httpId}`)).toContainText('Independent overlapping work');
  const sequence = (await snapshot(request)).assignments.find((a) => a.id === httpId).last_sequence;
  await expect.poll(async () => (await snapshot(request)).assignments.find((a) => a.id === httpId).last_sequence).toBeGreaterThan(sequence + 1);
  const stillHeld = (await snapshot(request)).occurrences.find((item) => item.id === held.id);
  expect(stillHeld.attempt_count).toBe(0);
  await page.goto(`/maintenance/${second.id}`);
  await connected(page);
  await cancelWindow(page, 'Final independent activity completed');
  await expect.poll(async () => (await snapshot(request)).occurrences.find((item) => item.id === held.id).status).toBe('delivered');
  const delivered = (await snapshot(request)).occurrences.find((item) => item.id === held.id);
  expect(delivered.payload).toEqual(held.payload);
  expect(delivered.attempt_count).toBe(1);
  const receipts = await (await request.get(`${fixtureURL}/records`)).json();
  expect(receipts.records.some((item) => item.payload.occurrence_id === held.id)).toBe(true);
  await page.setViewportSize({ width: 1280, height: 800 });
  await checkpoint(page, testInfo, 'maintenance-end-retained-history');
  await mode(request, { ready: true });
  await measured(request, httpId);
  await testInfo.attach('final-state', { body: JSON.stringify(await snapshot(request), null, 2), contentType: 'application/json' });
});

async function selectedChoice(page, predicate) {
  let key;
  await expect.poll(async () => {
    const values = await page.locator('.maintenance-picker-rows input[type="checkbox"]').evaluateAll((inputs) => inputs.map((input) => input.value));
    key = values.find((value) => predicate(JSON.parse(Buffer.from(value, 'base64url').toString())));
    return Boolean(key);
  }).toBe(true);
  return page.locator(`.maintenance-picker-rows input[value="${key}"]`);
}

test('one explicit selection survives unsent reconnect, reviews overlap drift and releases original held delivery', async ({ page, request }, testInfo) => {
  const errors = [];
  page.on('pageerror', (error) => errors.push(error.message));
  await mode(request, { ready: true, webhook: 'ok' });
  await measured(request, httpId);
  const initial = await snapshot(request);
  const httpCheck = initial.assignments.find((item) => item.id === httpId);
  const filesystem = initial.assignments.find((item) => item.id === filesystemId);
  const httpTarget = httpCheck.outputs[0].target;
  const fileTarget = filesystem.outputs[0].target;
  await page.goto('/maintenance/new');
  await connected(page);
  const observingRunner = initial.runners.find((item) => (item.id || item.installation_id) === httpCheck.runner_id);
  await expect(page.locator(`#maintenance-runner-options option[value="${httpCheck.runner_id}"]`))
    .toHaveText(observingRunner.label);
  await expect(page.getByLabel('Observing runner', { exact: true })).toHaveAttribute('list', 'maintenance-runner-options');
  await expect(page.getByLabel('Monitored environment', { exact: true })).toHaveAttribute('list', 'maintenance-environment-options');
  await page.getByLabel('Observing runner', { exact: true }).fill(httpCheck.runner_id);
  await expect.poll(async () => (await page.locator('.maintenance-picker-rows').innerText()).includes(httpCheck.label)).toBe(true);
  await page.getByLabel('Observing runner', { exact: true }).fill('');
  await expect(page.locator('#maintenance-settings')).toBeHidden();
  await (await selectedChoice(page, (item) => item.scope === 'check' && item.assignment_id === httpId)).check();
  await expect(page.locator('#maintenance-selected-count')).toHaveText('1 selection');
  await page.locator('#maintenance-name').fill('Selected service work');
  await page.locator('#maintenance-reason').fill('One shared window for service and storage');
  await (await selectedChoice(page, (item) => item.scope === 'check' && item.assignment_id === filesystemId)).check();
  await expect(page.locator('#maintenance-selected-count')).toHaveText('2 selections');
  await page.locator('#maintenance-review-selected').click();
  await page.locator('.maintenance-picker-rows li').filter({ hasText: filesystem.label }).getByRole('button', { name: /^Remove / }).click();
  await expect(page.locator('#maintenance-selected-count')).toHaveText('1 selection');
  await page.locator('#maintenance-clear-selection').click();
  await expect(page.locator('#maintenance-selected-count')).toHaveText('0 selections');
  await expect(page.locator('#maintenance-settings')).toBeHidden();
  await expect(page.locator('#maintenance-name')).toHaveValue('Selected service work');
  await page.getByRole('button', { name: 'Available choices', exact: true }).click();
  await (await selectedChoice(page, (item) => item.scope === 'check' && item.assignment_id === httpId)).check();
  await (await selectedChoice(page, (item) => item.scope === 'check' && item.assignment_id === filesystemId)).check();
  await page.locator('#maintenance-kind').selectOption('target');
  await (await selectedChoice(page, (item) => item.scope === 'target' && item.target_key === httpTarget.key && item.target_kind === httpTarget.kind)).check();
  await expect(page.locator('#maintenance-selected-count')).toHaveText('3 selections');
  await expect(page.locator('#maintenance-check-chooser')).toContainText('does not include separately named disks');
  const unsentTarget = await selectedChoice(page, (item) => item.scope === 'target' && item.target_key === fileTarget.key && item.target_kind === fileTarget.kind);
  await page.setViewportSize({ width: 390, height: 844 });
  await formFits(page, '#maintenance-selection-form');
  await formFits(page);
  await checkpoint(page, testInfo, 'mixed-maintenance-selection-390');

  await page.evaluate(() => window.liveSocket.disconnect());
  await expect(page.locator('[data-phx-main]')).not.toHaveClass(/phx-connected/);
  await page.locator('#maintenance-name').fill('Unsent shared maintenance draft');
  await page.locator('#maintenance-reason').fill('Both forms changed while the live connection was down');
  await unsentTarget.check();
  await page.evaluate(() => window.liveSocket.connect());
  await connected(page);
  await expect(page.locator('#maintenance-selected-count')).toHaveText('4 selections');
  await expect(page.locator('#maintenance-name')).toHaveValue('Unsent shared maintenance draft');
  await expect(page.locator('#maintenance-reason')).toHaveValue('Both forms changed while the live connection was down');
  await expect(page.locator('#maintenance-kind')).toHaveValue('target');
  const recovered = JSON.parse(await page.locator('#maintenance-form input[name="_proposal"]').inputValue());
  expect(recovered.selections.filter((item) => item.scope === 'check').map((item) => item.assignment_id).sort()).toEqual([filesystemId, httpId].sort());
  expect(recovered.selections.filter((item) => item.scope === 'target').map((item) => item.target_key).sort()).toEqual([httpTarget.key, fileTarget.key].sort());
  await page.locator('#maintenance-preview-button').click();
  await expect(page.locator('#maintenance-preview-summary')).toContainText('2 results across 2 scheduled checks');
  await expect(page.locator('#maintenance-saved-selection li')).toHaveCount(4);
  const inspector = page.locator('#maintenance-selection-details');
  const inspectorToggle = inspector.locator(':scope > summary');
  await expect(inspector).not.toHaveAttribute('open');
  await expect(inspectorToggle).toHaveText('Inspect selected checks and targets (4)');
  await inspectorToggle.click();
  await expect(page.locator('#maintenance-saved-selection li').first()).toBeVisible();
  await inspectorToggle.click();

  // A real independently saved window changes the reviewed overlap set.
  const seedResponse = await request.get(`/api/v1/maintenance/seed/${httpId}`);
  expect(seedResponse.ok(), await seedResponse.text()).toBe(true);
  const seed = await seedResponse.json();
  const concurrentReview = await request.post('/api/v1/maintenance/preview', {
    data: { proposal: { ...seed.proposal, name: 'Concurrent service hold', reason: 'Overlap changed after the other preview' } },
  });
  expect(concurrentReview.ok(), await concurrentReview.text()).toBe(true);
  const review = await concurrentReview.json();
  const concurrentSave = await request.post('/api/v1/maintenance/apply', { data: { proposal: review.proposal, review_token: review.review_token } });
  expect(concurrentSave.ok(), await concurrentSave.text()).toBe(true);
  const otherWindow = await concurrentSave.json();
  await expect(page.locator('#maintenance-error')).toContainText('changed after your preview');
  await expect(page.locator('#maintenance-save')).toHaveCount(0);
  await expect(page.locator('#maintenance-name')).toHaveValue('Unsent shared maintenance draft');
  await page.locator('#maintenance-preview-button').click();
  await expect(page.locator('#maintenance-overlaps')).toContainText('Concurrent service hold');
  await expect(inspector).not.toHaveAttribute('open');
  await expect(page.locator('#maintenance-preview-matches')).not.toHaveAttribute('open');
  await page.setViewportSize({ width: 320, height: 740 });
  expect((await inspector.boundingBox()).height).toBeLessThan(140);
  await formFits(page);
  await checkpoint(page, testInfo, 'mixed-selection-reviewed-union-320');
  await page.locator('#maintenance-save').click();
  const shared = await currentWindow(page, request);
  expect(shared.scope).toBe('selection');
  expect(shared.selections).toHaveLength(4);
  expect(shared.match_count).toBe(2);
  await expect(page.locator('#maintenance-saved')).toContainText('One window covering 4 selected checks or targets');
  await expect(inspector).not.toHaveAttribute('open');
  await expect(page.locator('#maintenance-include-more')).toHaveCount(0);
  await expect(page.locator('#maintenance-scope')).toHaveCount(0);
  const immutable = await request.post('/api/v1/maintenance/preview', {
    data: { proposal: { ...shared.proposal, selections: shared.selections.slice(1) } },
  });
  expect(immutable.ok()).toBe(false);
  expect((await (await request.get(`/api/v1/maintenance/${shared.id}`)).json()).selections).toEqual(shared.selections);
  const cancelOther = await request.post(`/api/v1/maintenance/${otherWindow.id}/cancel`, {
    data: { revision: otherWindow.revision, reason: 'Independent overlapping activity completed' },
  });
  expect(cancelOther.ok(), await cancelOther.text()).toBe(true);

  await mode(request, { ready: false });
  await measured(request, httpId, 'CRIT');
  const failed = await snapshot(request);
  const incident = failed.incidents.find((item) => item.assignment_id === httpId && item.status === 'open');
  const held = failed.occurrences.find((item) => item.incident_id === incident.id && item.kind === 'firing');
  expect(held.attempt_count).toBe(0);
  await page.goto(`/incidents/${incident.id}`);
  await connected(page);
  await expect(page.locator(`#maintenance-summary-${httpId}`)).toContainText('Unsent shared maintenance draft');
  await page.goto(`/maintenance/${shared.id}`);
  await connected(page);
  await cancelWindow(page, 'The single selected maintenance activity is complete');
  await expect.poll(async () => (await snapshot(request)).occurrences.find((item) => item.id === held.id).status).toBe('delivered');
  const delivered = (await snapshot(request)).occurrences.find((item) => item.id === held.id);
  expect(delivered.payload).toEqual(held.payload);
  expect(delivered.attempt_count).toBe(1);
  await expect(page.locator('#maintenance-history')).toContainText('4 selected checks or targets');
  await page.setViewportSize({ width: 1280, height: 800 });
  await checkpoint(page, testInfo, 'shared-selection-ended-history');
  await mode(request, { ready: true });
  await measured(request, httpId);
  expect(errors).toEqual([]);
});

test('weekly civil dates reject later gaps, resolve later folds and retain cancellation drafts across stale reviews', async ({ page, request }, testInfo) => {
  const errors = [];
  page.on('pageerror', (error) => errors.push(error.message));
  const year = new Date().getUTCFullYear() + 1;
  const spring = lastSunday(year, 2);
  const autumn = lastSunday(year, 9);
  const firstAutumn = shiftDate(autumn, -7);
  await mode(request, { ready: true, webhook: 'ok' });
  await measured(request, httpId);
  await page.goto(`/maintenance/new?check_id=${httpId}`);
  await connected(page);
  await page.locator('#maintenance-name').fill('Weekly deployment in local civil time');
  await page.locator('#maintenance-reason').fill('Review every actual date before scheduling');
  await page.locator('#maintenance-repeat').selectOption('weekly');
  await expect(page.locator('#maintenance-start-mode')).toHaveValue('scheduled');
  await page.locator('#maintenance-timezone').fill('Europe/Berlin');
  await page.locator('#maintenance-repeat-count').fill('3');
  await page.locator('#maintenance-start').fill(`${shiftDate(spring, -7)}T02:30`);
  await page.locator('#maintenance-end').fill(`${shiftDate(spring, -7)}T03:30`);
  await page.locator('#maintenance-preview-button').click();
  await expect(page.locator('#maintenance-error')).toContainText('Window 2 start');
  await expect(page.locator('#maintenance-error')).toContainText('does not exist');
  await expect(page.locator('#maintenance-save')).toHaveCount(0);

  await page.locator('#maintenance-start').fill(`${firstAutumn}T02:10`);
  await page.locator('#maintenance-end').fill(`${firstAutumn}T02:50`);
  await page.locator('#maintenance-preview-button').click();
  await expect(page.locator('#maintenance-error')).toContainText('Window 2 start');
  await expect(page.locator('#maintenance-error')).toContainText('occurs twice');
  await page.locator('#maintenance-repeat-start-fold').selectOption('earlier');
  await page.locator('#maintenance-repeat-end-fold').selectOption('later');
  await page.locator('#maintenance-repeat-ending').selectOption('date');
  await page.locator('#maintenance-repeat-until').fill(shiftDate(autumn, 7));
  await disconnect(page);
  await page.locator('#maintenance-reason').fill('Unsent plan includes the repeated autumn hour');
  await page.locator('#maintenance-repeat-until').fill(shiftDate(autumn, 14));
  await reconnect(page);
  await expect(page.locator('#maintenance-reason')).toHaveValue('Unsent plan includes the repeated autumn hour');
  await expect(page.locator('#maintenance-repeat-ending')).toHaveValue('date');
  await expect(page.locator('#maintenance-repeat-until')).toHaveValue(shiftDate(autumn, 14));
  await expect(page.locator('#maintenance-repeat-start-fold')).toHaveValue('earlier');
  await expect(page.locator('#maintenance-repeat-end-fold')).toHaveValue('later');
  await page.setViewportSize({ width: 390, height: 844 });
  await formFits(page);
  await checkpoint(page, testInfo, 'weekly-civil-date-draft-reconnect-390');
  await page.locator('#maintenance-preview-button').click();
  await expect(page.locator('#maintenance-series-preview-summary')).toContainText('4 windows');
  await expect(page.locator('#maintenance-series-preview-dates')).not.toHaveAttribute('open', '');
  await page.locator('#maintenance-series-preview-dates > summary').click();
  const dates = page.locator('#maintenance-series-preview [data-window-index]');
  await expect(dates).toHaveCount(4);
  const folded = page.locator('#maintenance-series-preview [data-window-index="2"]');
  await expect(folded).toContainText('00:10');
  await expect(folded).toContainText('01:50');
  await expect(page.locator('#maintenance-series-preview [data-window-index="4"]')).toContainText(displayedDate(shiftDate(autumn, 14)));
  const canonical = JSON.parse(await page.locator('#maintenance-form input[name="_proposal"]').inputValue());
  expect(canonical.recurrence).toEqual({ frequency: 'weekly', interval: 1, end_mode: 'date', count: null, until_date: shiftDate(autumn, 14) });
  await disconnect(page);
  await reconnect(page);
  await expect(page.locator('#maintenance-save')).toHaveCount(0);
  await expect(page.locator('#maintenance-form input[name="_review_token"]')).toHaveCount(0);
  await expect(page.locator('#maintenance-repeat-until')).toHaveValue(shiftDate(autumn, 14));
  await page.locator('#maintenance-preview-button').click();
  await expect(page.locator('#maintenance-series-preview-summary')).toContainText('4 windows');
  await expect(page.locator('#maintenance-series-preview-dates')).not.toHaveAttribute('open', '');
  await page.setViewportSize({ width: 320, height: 740 });
  await formFits(page);
  await checkpoint(page, testInfo, 'weekly-all-resolved-dates-review-320');
  await keyboardSubmit(page, page.locator('#maintenance-save'));
  const saved = await currentSeries(page, request);
  expect(saved.occurrence_total).toBe(4);
  expect(saved.upcoming_count).toBe(4);
  const repeatedHour = saved.occurrences.find((row) => row.index === 2);
  expect(Date.parse(repeatedHour.starts_at)).toBe(Date.parse(`${autumn}T00:10:00Z`));
  expect(Date.parse(repeatedHour.ends_at)).toBe(Date.parse(`${autumn}T01:50:00Z`));
  await page.locator('#maintenance-series-windows [data-window-index="2"]').getByRole('link', { name: 'Inspect or change this window', exact: true }).click();
  await connected(page);
  await expect(page.locator('#maintenance-series-membership')).toContainText('changes only this window');
  await expect(page.locator('#maintenance-repeat')).toHaveCount(0);
  await page.locator('#maintenance-reason').fill('This one deployment has separate reviewed work');
  await page.locator('#maintenance-preview-button').click();
  await page.locator('#maintenance-save').click();
  await expect(page.locator('#maintenance-saved')).toContainText('This one deployment has separate reviewed work');
  const changedChild = await currentWindow(page, request);
  expect(changedChild.starts_at).toBe(repeatedHour.starts_at);
  expect(changedChild.ends_at).toBe(repeatedHour.ends_at);
  expect(changedChild.exception).toBe(true);
  await page.locator('#maintenance-series-membership').getByRole('link', { name: 'Inspect the series', exact: true }).click();
  await connected(page);
  await expect(page.locator('#maintenance-series-windows [data-window-index="2"]')).toContainText('Changed from original');
  await page.locator('#maintenance-series-cancel').click();
  await page.locator('#maintenance-series-cancel-reason').fill('Draft cancellation reason');
  await disconnect(page);
  await page.locator('#maintenance-series-cancel-reason').fill('Unsent cancellation keeps historical evidence');
  await reconnect(page);
  await expect(page.locator('#maintenance-series-cancel-reason')).toHaveValue('Unsent cancellation keeps historical evidence');
  await page.locator('#maintenance-series-cancel-confirm').click();
  await expect(page.locator('#maintenance-series-cancel-summary')).toContainText('Cancel 4 upcoming windows');
  await expect(page.locator('#maintenance-series-cancel-dates')).not.toHaveAttribute('open', '');
  await page.locator('#maintenance-series-cancel-dates > summary').click();
  await expect(page.locator('#maintenance-series-cancel-preview [data-window-index]')).toHaveCount(4);
  await page.locator('#maintenance-series-cancel-dates > summary').click();
  const cancellationToken = await page.locator('#maintenance-series-cancel-form input[name="_review_token"]').inputValue();

  // A concurrent reviewed child edit changes the exact set/revisions reviewed for cancellation.
  const another = await maintenanceJSON(request, `/api/v1/maintenance/${saved.occurrences[0].id}`);
  const changedPreview = await maintenanceJSON(request, '/api/v1/maintenance/preview', {
    proposal: { ...another.proposal, reason: 'Concurrent operator changed one future window' },
  });
  await maintenanceJSON(request, '/api/v1/maintenance/apply', {
    proposal: changedPreview.proposal, review_token: changedPreview.review_token,
  });
  await expect(page.locator('#maintenance-series-cancel-preview')).toHaveCount(0);
  await expect(page.locator('#maintenance-error')).toBeVisible();
  await expect(page.locator('#maintenance-series-cancel-reason')).toHaveValue('Unsent cancellation keeps historical evidence');
  const stale = await request.post(`/api/v1/maintenance-series/${saved.id}/cancel`, {
    data: { review_token: cancellationToken, reason: 'Unsent cancellation keeps historical evidence' },
  });
  expect(stale.status()).toBe(409);
  expect((await currentSeries(page, request)).upcoming_count).toBe(4);
  await page.locator('#maintenance-series-cancel-current').click();
  await expect(page.locator('#maintenance-series-cancel-reason')).toHaveValue('Unsent cancellation keeps historical evidence');
  await page.locator('#maintenance-series-cancel-confirm').click();
  await expect(page.locator('#maintenance-series-cancel-preview')).toBeVisible();
  await expect(page.locator('#maintenance-series-cancel-dates')).not.toHaveAttribute('open', '');
  await formFits(page, '#maintenance-series-cancel-form');
  await checkpoint(page, testInfo, 'weekly-upcoming-cancellation-reviewed-320');
  await keyboardSubmit(page, page.locator('#maintenance-series-cancel-confirm'));
  await expect(page.locator('#maintenance-series-saved')).toContainText('Cancelled');
  await expect(page.locator('#maintenance-series-cancel-preview')).toHaveCount(0);
  const cancelled = await currentSeries(page, request);
  expect(cancelled.upcoming_count).toBe(0);
  expect(cancelled.cancelled_count).toBe(4);
  await expect(page.locator('#maintenance-series-history')).toContainText('Unsent cancellation keeps historical evidence');
  await page.setViewportSize({ width: 1280, height: 800 });
  await checkpoint(page, testInfo, 'weekly-child-exception-and-series-history-desktop');
  expect(errors).toEqual([]);
});

test('finite count schedules expose every reviewed date through bounded pages and require review after reconnect', async ({ page, request }, testInfo) => {
  const year = new Date().getUTCFullYear() + 1;
  await page.goto(`/maintenance/new?check_id=${httpId}`);
  await connected(page);
  await page.locator('#maintenance-name').fill('Twenty-six scheduled service deployments');
  await page.locator('#maintenance-reason').fill('Review the entire finite schedule, including its last page');
  await page.locator('#maintenance-repeat').selectOption('weekly');
  await page.locator('#maintenance-repeat-interval').selectOption('2');
  await page.locator('#maintenance-repeat-count').fill('26');
  await page.locator('#maintenance-timezone').fill('UTC');
  await page.locator('#maintenance-start').fill(`${year}-01-03T10:00`);
  await page.locator('#maintenance-end').fill(`${year}-01-03T11:00`);
  await page.locator('#maintenance-preview-button').click();
  await expect(page.locator('#maintenance-series-preview-summary')).toContainText('26 windows');
  await expect(page.locator('#maintenance-series-preview-dates')).not.toHaveAttribute('open', '');
  await page.locator('#maintenance-series-preview-dates > summary').click();
  await expect(page.locator('#maintenance-series-preview [data-window-index]')).toHaveCount(25);
  const token = await page.locator('#maintenance-form input[name="_review_token"]').inputValue();
  const reviewedIndices = await page.locator('#maintenance-series-preview [data-window-index]').evaluateAll((rows) => rows.map((row) => Number(row.dataset.windowIndex)));
  await page.getByRole('navigation', { name: 'Reviewed maintenance dates', exact: true }).getByRole('button', { name: 'Next dates', exact: true }).click();
  await expect(page.locator('#maintenance-series-preview [data-window-index]')).toHaveCount(1);
  await expect(page.locator('#maintenance-series-preview-dates')).toHaveAttribute('open', '');
  reviewedIndices.push(...await page.locator('#maintenance-series-preview [data-window-index]').evaluateAll((rows) => rows.map((row) => Number(row.dataset.windowIndex))));
  expect(reviewedIndices).toEqual(Array.from({ length: 26 }, (_, index) => index + 1));
  await expect(page.locator('#maintenance-form input[name="_review_token"]')).toHaveValue(token);
  await disconnect(page);
  await reconnect(page);
  await expect(page.locator('#maintenance-save')).toHaveCount(0);
  await expect(page.locator('#maintenance-form input[name="_review_token"]')).toHaveCount(0);
  await expect(page.locator('#maintenance-repeat-count')).toHaveValue('26');
  await expect(page.locator('#maintenance-repeat-interval')).toHaveValue('2');
  await page.locator('#maintenance-preview-button').click();
  await expect(page.locator('#maintenance-series-preview-summary')).toContainText('26 windows');
  await page.locator('#maintenance-series-preview-dates > summary').click();
  await page.getByRole('navigation', { name: 'Reviewed maintenance dates', exact: true }).getByRole('button', { name: 'Next dates', exact: true }).click();
  await expect(page.locator('#maintenance-series-preview [data-window-index="26"]')).toBeVisible();
  await page.locator('#maintenance-series-preview-dates > summary').click();
  await page.setViewportSize({ width: 320, height: 740 });
  await formFits(page);
  await checkpoint(page, testInfo, 'bounded-weekly-date-review-reconnect-320');
  await page.locator('#maintenance-save').click();
  const saved = await currentSeries(page, request);
  expect(saved.occurrence_total).toBe(26);
  expect(saved.occurrences).toHaveLength(25);
  const lastPage = await maintenanceJSON(request, `/api/v1/maintenance-series/${saved.id}?occurrence_page=2`);
  expect(lastPage.occurrences).toHaveLength(1);
  expect(lastPage.occurrences[0].index).toBe(26);
  expect(Date.parse(lastPage.occurrences[0].starts_at) - Date.parse(saved.occurrences[0].starts_at)).toBe(25 * 14 * 86400_000);
  await page.getByRole('navigation', { name: 'Saved maintenance dates', exact: true }).getByRole('link', { name: 'Next dates', exact: true }).click();
  await expect(page).toHaveURL(/occurrence_page=2/);
  await expect(page.locator('#maintenance-series-windows [data-window-index]')).toHaveCount(1);
  await expect(page.locator('#maintenance-series-windows [data-window-index="26"]')).toBeVisible();
  await page.locator('#maintenance-series-cancel').click();
  await page.locator('#maintenance-series-cancel-reason').fill('End the complete finite schedule after inspecting every page');
  await page.locator('#maintenance-series-cancel-confirm').click();
  await expect(page.locator('#maintenance-series-cancel-preview [data-window-index]')).toHaveCount(25);
  await expect(page.locator('#maintenance-series-cancel-dates')).not.toHaveAttribute('open', '');
  await page.locator('#maintenance-series-cancel-dates > summary').click();
  const cancelToken = await page.locator('#maintenance-series-cancel-form input[name="_review_token"]').inputValue();
  await page.getByRole('navigation', { name: 'Windows reviewed for cancellation', exact: true }).getByRole('button', { name: 'Next dates', exact: true }).click();
  await expect(page.locator('#maintenance-series-cancel-preview [data-window-index="26"]')).toBeVisible();
  await expect(page.locator('#maintenance-series-cancel-dates')).toHaveAttribute('open', '');
  await expect(page.locator('#maintenance-series-cancel-form input[name="_review_token"]')).toHaveValue(cancelToken);
  await formFits(page, '#maintenance-series-cancel-form');
  await checkpoint(page, testInfo, 'bounded-weekly-cancellation-last-page-320');
  await page.locator('#maintenance-series-cancel-confirm').click();
  await expect(page.locator('#maintenance-series-saved')).toContainText('Cancelled');
  await expect(page.locator('#maintenance-series-cancel-preview')).toHaveCount(0);
  const ended = await currentSeries(page, request);
  expect(ended.cancelled_count).toBe(26);
  expect(ended.upcoming_count).toBe(0);
  await testInfo.attach('finite-series-calendar-evidence', {
    body: JSON.stringify({ saved, lastPage, ended }, null, 2), contentType: 'application/json',
  });
});
