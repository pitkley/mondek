import { unpackAPI } from '../support/helpers.mjs';
// Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
// SPDX-License-Identifier: Apache-2.0
import {test, expect} from '@playwright/test';
import {
  attachState, checkpoint, connected, demoAssignments, fixtureURL, keyboardFill,
  keyboardSubmit, measured, mode, reconnect, setFilter, snapshot, streams,
} from '../support/helpers.mjs';

let filesystemId, httpId, consumerId;
test.beforeEach(async ({request}) => {
  const checks = await demoAssignments(request);
  ({filesystem: {id: filesystemId}, http: {id: httpId}, consumer: {id: consumerId}} = checks);
});

const resultPage = id => `/results/${id}/full`;
const incidentPage = id => `/incidents/health/${id}/full`;
const displayedUTC = value => {
  const timestamp = new Date(value);
  const month = new Intl.DateTimeFormat('en-US', {month: 'short', timeZone: 'UTC'}).format(timestamp);
  return `${String(timestamp.getUTCDate()).padStart(2, '0')} ${month}, ${timestamp.toISOString().slice(11, 19)} UTC`;
};

test('runner monitoring supports reviewed configuration, live draft recovery and immutable delivery retry', async ({page, request}, testInfo) => {
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  await mode(request, {ready: true, webhook: 'ok'});
  await expect.poll(async () => (await streams(request, {freshness: 'fresh'})).total).toBe(3);
  await expect.poll(async () => (await snapshot(request)).assignments.every(item => !!item.source_id)).toBe(true);
  await page.goto('/');
  await expect(page.locator('#preview-summary')).toContainText('observations fresh');
  await expect(page.locator('#preview-open-incidents')).toBeVisible();
  await checkpoint(page, testInfo, 'source-provided-overview');
  await page.setViewportSize({width: 320, height: 740});
  await checkpoint(page, testInfo, 'operator-overview-320');
  await page.setViewportSize({width: 1280, height: 900});
  await page.goto('/configuration');
  await expect(page.getByRole('link', {name: 'Add check', exact: true})).toHaveCount(0);
  await expect(page.locator('[id^="configuration-row-"]')).toHaveCount(3);
  await checkpoint(page, testInfo, 'scheduled-check-inventory');
  await page.locator(`#configuration-row-${filesystemId}`).getByRole('link').first().click();
  await expect(page).toHaveURL(new RegExp(`/configuration/${filesystemId}(?:\\?|$)`));
  const form = page.locator(`#form-${filesystemId}`);
  const warning = page.locator(`[id="${filesystemId}-warn_percent"]`);
  const critical = page.locator(`[id="${filesystemId}-crit_percent"]`);
  await expect(page.locator('#configuration-adoption-status')).toBeVisible();
  await expect(page.locator('#configuration-results tbody tr')).toHaveCount(1);
  await page.locator('#check-source-revisions summary').click();
  await expect(page.locator('#check-source-revisions')).toContainText(filesystemId);
  await expect(page.locator('#configuration-scope')).toContainText('operator');
  await checkpoint(page, testInfo, 'configuration-source-ownership-desktop');
  const prompt = page.locator(`#configuration-agent-prompts-${filesystemId}-check`);
  await page.setViewportSize({width: 320, height: 740});
  await prompt.locator('summary').click();
  await expect(prompt.locator('textarea')).toContainText(`"check_id":"${filesystemId}"`);
  await checkpoint(page, testInfo, 'configuration-source-ownership-mobile');
  await prompt.locator('summary').click();
  await page.setViewportSize({width: 1280, height: 900});
  await keyboardFill(page, warning, '99');
  await keyboardFill(page, critical, '80');
  await keyboardSubmit(page, form.getByRole('button', {name: 'Review settings for this check', exact: true}));
  await expect(page.locator(`#error-${filesystemId}`)).toBeVisible();
  await checkpoint(page, testInfo, 'invalid-threshold-comparison');
  await keyboardFill(page, critical, '100');
  await page.keyboard.press('Tab');
  await reconnect(page);
  await expect(warning).toHaveValue('99');
  await expect(critical).toHaveValue('100');
  await expect(page.locator('#check-source-revisions')).toHaveAttribute('open', '');
  await checkpoint(page, testInfo, 'configuration-draft-after-reconnect');
  await keyboardSubmit(page, form.getByRole('button', {name: 'Review settings for this check', exact: true}));
  await expect(page.locator('#instance-save-review')).toContainText('99');
  await page.locator('#confirm-instance-save').click();
  await expect.poll(async () => {
    const check = (await snapshot(request)).assignments.find(item => item.id === filesystemId);
    return check.current?.confirmed_params?.warn_percent === 99 && check.current?.confirmed_params?.crit_percent === 100;
  }).toBe(true);
  await expect(page.locator(`#configuration-progress-${filesystemId}`)).toContainText('has produced complete measured evidence');
  await checkpoint(page, testInfo, 'saved-parameters-measured');

  await page.goto('/runners');
  const observer = (await snapshot(request)).runners[0].id;
  await page.locator(`#runner-row-${observer}`).getByRole('link').first().click();
  await expect(page.locator('#runner-measurements')).toContainText('3 of 3 active results fresh');
  const diagnostics = page.locator('#runner-provenance');
  await expect(diagnostics).not.toHaveAttribute('open');
  await keyboardSubmit(page, diagnostics.locator(':scope > summary'));
  await reconnect(page);
  await expect(diagnostics).toHaveAttribute('open', '');
  await checkpoint(page, testInfo, 'runner-coverage-provenance-desktop');
  await page.setViewportSize({width: 320, height: 740});
  await page.locator('#overview-panel [data-overview-close]').click();
  await page.getByRole('navigation', {name: 'Main navigation'}).getByRole('link', {name: 'Notifications', exact: true}).click();
  await expect(page).toHaveURL(/\/notifications$/);
  await checkpoint(page, testInfo, 'runner-notification-shortcut-320');
  await page.setViewportSize({width: 1280, height: 900});

  const result = (await streams(request)).items.find(item => item.assignment_id === httpId);
  await page.goto(resultPage(result.id));
  await mode(request, {ready: false, webhook: 'reject'});
  await measured(request, httpId, 'CRIT');
  await page.getByRole('link', {name: 'View incident', exact: true}).click();
  await expect(page.locator('#overview-panel')).toContainText('Recorded failure');
  const incidentId = (await snapshot(request)).incidents.find(item => item.stream_id === result.id && item.status === 'open').id;
  for (const width of [1280, 320, 390]) {
    await page.setViewportSize({width, height: 844});
    await page.goto(incidentPage(incidentId));
    await checkpoint(page, testInfo, `incident-check-navigation-${width}`);
    await page.getByRole('link', {name: /View latest check result/}).first().click();
    await expect(page.locator('#overview-panel')).toContainText(result.result_key);
    await page.locator('#overview-panel').getByRole('link', {name: 'View check configuration', exact: true}).click();
    await expect(page).toHaveURL(new RegExp(`/configuration/${httpId}\\?`));
    await page.locator('a.back').click();
    await expect(page.locator('#overview-panel')).toBeVisible();
    await page.locator('#overview-panel [data-overview-close]').click();
    await expect(page.locator('#incident-page')).toContainText('Recorded failure');
  }
  await page.setViewportSize({width: 1280, height: 900});
  const incidentPrompt = page.locator('#incident-agent-prompts-incident');
  await incidentPrompt.locator('summary').click();
  await expect(incidentPrompt.locator('textarea')).toContainText(incidentId);
  await expect(incidentPrompt.locator('textarea')).toContainText('read-only');
  await checkpoint(page, testInfo, 'incident-investigation-prompt');
  await incidentPrompt.locator('summary').click();
  await expect.poll(async () => (await snapshot(request)).occurrences.find(
    item => item.incident_id === incidentId && item.kind === 'firing',
  )?.status, {timeout: 60_000}).toBe('exhausted');
  const occurrence = (await snapshot(request)).occurrences.find(item => item.incident_id === incidentId && item.kind === 'firing');
  expect(occurrence.attempt_count).toBe(3);
  await page.goto('/notifications?notification_status=exhausted');
  await expect(page.getByRole('button', {name: /Edit Status filter: Exhausted retries/})).toBeVisible();
  await expect(page.locator(`#notification-row-${occurrence.id}`)).toContainText('Retries exhausted');
  await page.locator(`#notification-row-${occurrence.id}`).getByRole('link').first().click();
  const notification = page.locator('#overview-panel');
  await expect(notification).toContainText('HTTP 503');
  await notification.getByText('Original notification payload', {exact: true}).click();
  await expect(notification.locator('[id$="notification-payload"] pre')).toContainText(httpId);
  await checkpoint(page, testInfo, 'exhausted-notification');
  await mode(request, {webhook: 'ok'});
  const retryForm = notification.locator('form[phx-submit=retry_notification]');
  const reason = retryForm.getByLabel('Reason for retry', {exact: true});
  await keyboardFill(page, reason, 'Local receiver restored during browser regression');
  await page.keyboard.press('Tab');
  await reconnect(page);
  await expect(reason).toHaveValue('Local receiver restored during browser regression');
  await keyboardSubmit(page, retryForm.getByRole('button', {name: 'Retry notification', exact: true}));
  await expect(notification).toContainText('Receiver accepted', {timeout: 45_000});
  const retried = (await snapshot(request)).occurrences.find(item => item.id === occurrence.id);
  expect(retried.payload).toEqual(occurrence.payload);
  expect(retried.destination).toEqual(occurrence.destination);
  expect(retried.attempt_count).toBe(4);
  const receipts = await (await request.get(`${fixtureURL}/records`)).json().then(unpackAPI);
  expect(receipts.records.some(receipt => receipt.payload.occurrence_id === occurrence.id)).toBe(true);
  await mode(request, {ready: true});
  await measured(request, httpId);
  await page.goto(incidentPage(incidentId));
  await expect(page.locator('#incident-page')).toContainText('Measured recovery');
  await expect.poll(async () => (await snapshot(request)).occurrences.find(
    item => item.incident_id === incidentId && item.kind === 'resolved',
  )?.status).toBe('delivered');
  await expect(page.locator('section[aria-labelledby=preview-delivery-heading]')).toContainText('Resolved');
  await checkpoint(page, testInfo, 'recovered-incident');
  await page.goto('/checks');
  await page.setViewportSize({width: 320, height: 740});
  await expect(page.locator('#preview-check-results tbody tr')).toHaveCount(3);
  await checkpoint(page, testInfo, 'result-inventory-mobile-320');
  await attachState(request, testInfo, 'final-source-monitoring-state');
  expect(errors).toEqual([]);
});

test('shared chip filters remain readable and usable across inventories', async ({page}, testInfo) => {
  for (const path of ['/checks', '/configuration', '/incidents']) {
    await page.goto(path);
    await connected(page);
    for (const width of [1280, 390, 320]) {
      await page.setViewportSize({width, height: 844});
      const input = page.getByRole('combobox');
      await expect(input).toBeVisible();
      const box = await input.boundingBox();
      expect(box.x).toBeGreaterThanOrEqual(0);
      expect(box.x + box.width).toBeLessThanOrEqual(width + 1);
      await input.click();
      await expect(page.getByRole('listbox')).toBeVisible();
      await input.press('Escape');
      await checkpoint(page, testInfo, `${path.slice(1)}-shared-filter-${width}`);
    }
    if (path === '/checks') {
      await setFilter(page, 'health', 'not_measured');
      await expect(page).toHaveURL(/health=not_measured/);
      await expect(page.locator('#preview-check-results')).toHaveCount(0);
      await page.getByRole('link', {name: 'Remove Health filter', exact: true}).click();
      await expect(page.locator('#preview-check-results tbody tr')).toHaveCount(3);
    }
  }
});

test('consumer findings keep their own confirmed measurement when later collection fails', async ({page, request}, testInfo) => {
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  const consumer = async () => (await snapshot(request)).assignments.find(item => item.id === consumerId);
  const criticalFinding = '[CRIT] Processing is disabled while queued work remains';
  let incidentId;
  let result;
  try {
    await mode(request, {backlog: 2, processing_enabled: true, data_mode: 'ok', webhook: 'ok'});
    await measured(request, consumerId);
    result = (await streams(request)).items.find(item => item.assignment_id === consumerId);
    await page.goto(resultPage(result.id));
    await mode(request, {backlog: 6, processing_enabled: false});
    await measured(request, consumerId, 'CRIT');
    const confirmed = await consumer();
    expect(confirmed.current.summary).toBe('6 queued items');
    expect(confirmed.current.confirmed_params).toMatchObject({warn_count: 5, crit_count: 10});
    const measurement = page.locator('.preview-result-measurement');
    const details = measurement.locator('.preview-check-details');
    await expect(details).toContainText('Warning at: 5 items');
    await expect(details).toContainText('Critical at: 10 items');
    await expect(details).toContainText('Processing enabled: False');
    await expect(details).toContainText(criticalFinding);
    await page.locator('#result-measurement-provenance > summary').click();
    await expect(page.getByRole('table', {name: 'Confirmed result provenance', exact: true})
      .getByRole('row').filter({has: page.getByRole('rowheader', {name: 'Confirmed configuration version', exact: true})})
      .getByRole('cell')).toHaveText(String(confirmed.current.confirmed_generation));
    const time = measurement.locator('time[datetime]');
    const first = await time.getAttribute('datetime');
    await expect(time).not.toHaveAttribute('datetime', first);
    await reconnect(page);
    await expect(page.locator('#result-measurement-provenance')).toHaveAttribute('open', '');
    await expect(details).toContainText(criticalFinding);
    await checkpoint(page, testInfo, 'consumer-composite-findings');
    await mode(request, {data_mode: 'crash'});
    let unavailable;
    await expect.poll(async () => {
      const row = await consumer();
      if (row.current.knowledge !== 'unavailable' || !row.current.diagnostic?.includes('worker crashed (exit 17)')) return false;
      unavailable = row;
      return true;
    }, {timeout: 45_000}).toBe(true);
    expect(unavailable.current.health).toBe('CRIT');
    expect(unavailable.current.details).toBe(confirmed.current.details);
    expect(unavailable.current.confirmed_observation_id).not.toBe(unavailable.current.observation_id);
    const state = await snapshot(request);
    const retained = state.evidence.find(item => item.id === unavailable.current.confirmed_observation_id);
    const retainedResult = retained.payload.results.find(item => item.key === 'backlog');
    expect(retainedResult.details).toBe(unavailable.current.details);
    expect(retainedResult.source_at).toBe(unavailable.current.source_at);
    expect(retained.payload.generation).toBe(unavailable.current.confirmed_generation);
    await expect(measurement).toContainText('Collection unavailable');
    await expect(measurement).toContainText('worker crashed (exit 17)');
    await expect(details).toContainText(criticalFinding);
    await expect(time).toHaveAttribute('datetime', retainedResult.source_at);
    await page.setViewportSize({width: 390, height: 844});
    await checkpoint(page, testInfo, 'consumer-retained-findings-mobile-390');
    await page.goto(`/runners/${unavailable.runner_id}/full`);
    await expect(page.locator('#runner-contact')).toContainText('Recent contact');
    await expect(page.locator('#runner-measurements')).toContainText('2 of 3 active results fresh');
    await page.locator('#runner-measurements a[href*="freshness=unavailable"]').click();
    await expect(page.getByRole('button', {name: /Edit Runner filter:/})).toBeVisible();
    await expect(page.locator('#preview-check-results tbody tr')).toHaveCount(1);
    await expect(page.locator('#preview-check-results')).toContainText('Critical');
    await page.locator(`#open-result-${result.id}`).click();
    await page.locator('#overview-panel').getByRole('link', {name: 'View incident', exact: true}).click();
    incidentId = (await snapshot(request)).incidents.find(item => item.stream_id === result.id && item.status === 'open').id;
    await page.goto(incidentPage(incidentId));
    await expect(page.locator('#preview-health-evidence')).toContainText(criticalFinding);
    await page.locator(`#preview-measurements-${incidentId} > summary`).click();
    const incidentState = await snapshot(request);
    const firing = incidentState.occurrences.find(item => item.incident_id === incidentId && item.kind === 'firing');
    const opening = incidentState.evidence.find(item => item.id === firing.payload.observation_id).payload;
    const openingResult = opening.results.find(item => item.key === 'backlog');
    const historical = page.locator(`#preview-measurements-${incidentId} [data-observation-id="${opening.id}"]`);
    await expect(historical).toHaveCount(1);
    await expect(historical).toContainText(criticalFinding);
    await historical.getByText('Timing and identity', {exact: true}).click();
    const identity = historical.getByRole('table', {name: 'Historical measurement identity', exact: true});
    const fact = name => identity.getByRole('row').filter({has: page.getByRole('rowheader', {name, exact: true})}).getByRole('cell');
    await expect(fact('Observation')).toHaveText(opening.id);
    await expect(fact('Configuration version')).toHaveText(String(opening.generation));
    await expect(fact('Source time')).toHaveText(displayedUTC(openingResult.source_at));
    await page.setViewportSize({width: 320, height: 740});
    await checkpoint(page, testInfo, 'consumer-incident-findings-mobile-320');
    await attachState(request, testInfo, 'consumer-findings-after-collection-failure');
  } finally {
    await mode(request, {backlog: 2, processing_enabled: true, data_mode: 'ok', webhook: 'ok'});
    await measured(request, consumerId);
  }
  const recovered = (await snapshot(request)).incidents.find(item => item.id === incidentId);
  expect(recovered.status).toBe('closed');
  expect(recovered.closure_reason).toBe('measured_recovery');
  await expect(page.locator('#incident-page')).toContainText('Measured recovery');
  await expect(page.locator('#preview-health-evidence')).toContainText(criticalFinding);
  await page.getByRole('link', {name: /View latest check result/}).first().click();
  await expect(page.locator('#overview-panel')).toContainText('Processing enabled: True');
  await expect(page.locator('#overview-panel .preview-result-measurement')).not.toContainText(criticalFinding);
  await checkpoint(page, testInfo, 'consumer-recovered-with-preserved-findings');
  expect(errors).toEqual([]);
});
