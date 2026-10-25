// Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
// SPDX-License-Identifier: Apache-2.0
import { test, expect } from '@playwright/test';
import {
  attachState, checkpoint, connected, fixtureURL, keyboardFill,
  keyboardSubmit, measured, mode, snapshot, streams,
} from '../support/helpers.mjs';
import { demoAssignments } from '../support/helpers.mjs';

let filesystemId, httpId, consumerId;
test.beforeEach(async ({ request }) => {
  const checks = await demoAssignments(request);
  ({ filesystem: { id: filesystemId }, http: { id: httpId }, consumer: { id: consumerId } } = checks);
});

test('runner-provided monitoring supports configuration, live draft recovery and incident delivery', async ({ page, request }, testInfo) => {
  const pageErrors = [];
  let socketsOpened = 0;
  let socketsClosed = 0;
  page.on('pageerror', (error) => pageErrors.push(error.message));
  page.on('websocket', (socket) => {
    if (new URL(socket.url()).pathname === '/live/websocket') {
      socketsOpened += 1;
      socket.on('close', () => { socketsClosed += 1; });
    }
  });
  await mode(request, { ready: true, webhook: 'ok' });
  await expect.poll(async () => (await streams(request, { freshness: 'fresh' })).total).toBe(3);
  await expect.poll(async () => (await snapshot(request)).assignments.every((item) => !!item.source_id)).toBe(true);
  await page.goto('/');
  await expect(page.getByText('Open target health incidents', { exact: true })).toBeVisible();
  await checkpoint(page, testInfo, 'source-provided-overview');
  await expect(page.locator('#history-retention')).toContainText('100000 receipts');
  await expect(page.locator('#history-retention')).toContainText('not a guaranteed retention duration');
  await page.setViewportSize({ width: 320, height: 740 });
  await page.locator('#history-retention').scrollIntoViewIfNeeded();
  await expect(page.locator('#history-retention')).toBeVisible();
  await checkpoint(page, testInfo, 'effective-retention-mobile-320');
  await page.setViewportSize({ width: 1280, height: 720 });
  await page.goto('/configuration');
  await expect(page.getByRole('link', { name: 'Add check', exact: true })).toHaveCount(0);
  await expect(page.locator('[id^="configuration-row-"]')).toHaveCount(3);
  await checkpoint(page, testInfo, 'scheduled-check-inventory');
  await page.locator(`#configuration-row-${filesystemId}`).getByRole('link').first().click();
  await expect(page).toHaveURL(new RegExp(`/configuration/${filesystemId}(?:\\?|$)`));
  const form = page.locator(`#form-${filesystemId}`);
  const warning = page.locator(`[id="${filesystemId}-warn_percent"]`);
  const critical = page.locator(`[id="${filesystemId}-crit_percent"]`);
  await expect(page.locator('#configuration-adoption-status')).toBeVisible();
  await expect(page.locator('#configuration-adoption-versions')).not.toHaveAttribute('open');
  await expect(page.locator('#configuration-results ul li')).toHaveCount(1);
  await expect(page.locator('#config-source-context')).not.toHaveAttribute('open');
  await page.locator('#config-source-context > summary').click();
  await page.locator('#check-source-revisions summary').click();
  await page.locator('#check-source-lifecycle summary').click();
  await page.waitForTimeout(1500);
  await expect(page.locator('#check-source-revisions')).toHaveAttribute('open', '');
  await expect(page.locator('#check-source-lifecycle')).toHaveAttribute('open', '');
  await expect(page.locator('#check-source-lifecycle')).toContainText('without a recovery measurement');
  await checkpoint(page, testInfo, 'configuration-source-ownership-desktop');
  await page.setViewportSize({ width: 320, height: 740 });
  await page.locator(`#configuration-agent-prompts-${filesystemId}-check summary`).click();
  await expect(page.locator(`#configuration-agent-prompts-${filesystemId}-check-text`)).toContainText(`"check_id":"${filesystemId}"`);
  await checkpoint(page, testInfo, 'configuration-source-ownership-mobile');
  await page.locator(`#configuration-agent-prompts-${filesystemId}-check summary`).click();
  await page.setViewportSize({ width: 1280, height: 720 });
  await keyboardFill(page, warning, '99');
  await keyboardFill(page, critical, '80');
  await keyboardSubmit(page, form.getByRole('button', { name: 'Review settings for this check', exact: true }));
  await expect(page.locator(`#error-${filesystemId}`)).toBeVisible();
  await checkpoint(page, testInfo, 'invalid-threshold-comparison');
  await keyboardFill(page, critical, '100');
  await page.keyboard.press('Tab');
  const previousSockets = socketsOpened;
  await page.evaluate(() => window.liveSocket.disconnect());
  await expect.poll(() => socketsClosed).toBeGreaterThan(0);
  await page.evaluate(() => window.liveSocket.connect());
  await expect.poll(() => socketsOpened).toBeGreaterThan(previousSockets);
  await connected(page);
  await expect(warning).toHaveValue('99');
  await expect(critical).toHaveValue('100');
  await expect(page.locator('#configuration-adoption-versions')).not.toHaveAttribute('open');
  await checkpoint(page, testInfo, 'configuration-draft-after-reconnect');
  await keyboardSubmit(page, form.getByRole('button', { name: 'Review settings for this check', exact: true }));
  await page.locator('#confirm-instance-save').click();
  await expect.poll(async () => {
    const check = (await snapshot(request)).assignments.find((item) => item.id === filesystemId);
    return check.current?.confirmed_params?.warn_percent === 99 && check.current?.confirmed_params?.crit_percent === 100;
  }).toBe(true);
  await expect(page.locator(`#configuration-progress-${filesystemId}`)).toContainText('has produced complete measured evidence');
  await checkpoint(page, testInfo, 'saved-parameters-measured');

  // The fleet inventory separates contact from collection; one runner detail
  // preserves diagnostic provenance without mixing in global delivery work.
  await page.goto('/runners');
  const observer = (await snapshot(request)).runners[0].id;
  await page.locator(`#runner-row-${observer}`).getByRole('link').first().click();
  const coverage = page.locator('#runner-measurements');
  const diagnostics = page.locator('#runner-provenance');
  await expect(coverage).toContainText('3 of 3 active results fresh');
  await expect(diagnostics).not.toHaveAttribute('open');
  await expect(page.locator('#notification-attempt-history')).toHaveCount(0);
  await checkpoint(page, testInfo, 'runner-coverage-primary-desktop');
  await keyboardSubmit(page, diagnostics.locator(':scope > summary'));
  await expect(diagnostics).toHaveAttribute('open', '');
  await page.evaluate(() => window.liveSocket.disconnect());
  await expect(page.locator('[data-phx-main]')).not.toHaveClass(/phx-connected/);
  await page.evaluate(() => window.liveSocket.connect());
  await connected(page);
  await expect(diagnostics).toHaveAttribute('open', '');
  await keyboardSubmit(page, diagnostics.locator(':scope > summary'));
  await page.setViewportSize({ width: 320, height: 740 });
  await keyboardSubmit(page, page.locator('.nav a[href="/notifications"]'));
  await expect(page).toHaveURL(/\/notifications$/);
  await expect(page.getByRole('heading', { name: 'Notifications', exact: true })).toBeInViewport();
  await checkpoint(page, testInfo, 'runner-notification-shortcut-320');
  await page.setViewportSize({ width: 1280, height: 720 });

  const id = httpId;
  const result = (await streams(request)).items.find((item) => item.assignment_id === id);
  await page.goto(`/checks/${result.id}`);
  await mode(request, { ready: false, webhook: 'reject' });
  await measured(request, id, 'CRIT');
  await page.locator('[id^="active-incident-"]').getByRole('link', { name: /Inspect incident/ }).click();
  await expect(page).toHaveURL(/\/incidents\/[0-9a-f-]+(?:\?|$)/);
  const incidentId = new URL(page.url()).pathname.split('/').at(-1);
  await page.locator('#incident-agent-prompts-incident summary').click();
  await expect(page.locator('#incident-agent-prompts-incident-text')).toContainText(incidentId);
  await expect(page.locator('#incident-agent-prompts-incident-text')).toContainText('read-only');
  await checkpoint(page, testInfo, 'incident-investigation-prompt');
  await page.locator('#incident-agent-prompts-incident summary').click();
  await expect(page.locator('#incident-check-now')).toContainText('Critical');
  await expect(page.locator('#incident-attempts')).toContainText('HTTP 503', { timeout: 45_000 });
  await expect.poll(async () => (await snapshot(request)).occurrences.find(
    (item) => item.incident_id === incidentId && item.kind === 'firing',
  )?.status, { timeout: 60_000 }).toBe('exhausted');
  const occurrence = (await snapshot(request)).occurrences.find(
    (item) => item.incident_id === incidentId && item.kind === 'firing',
  );
  expect(occurrence.attempt_count).toBe(3);
  await page.goto('/notifications?notification_status=exhausted');
  await expect(page.getByLabel('Delivery status', { exact: true })).toHaveValue('exhausted');
  await expect(page.locator(`#notification-row-${occurrence.id}`)).toContainText('Retries exhausted');
  await checkpoint(page, testInfo, 'runner-outstanding-delivery-action');
  await page.locator(`#notification-row-${occurrence.id}`).getByRole('link').first().click();
  await expect(page).toHaveURL(new RegExp(`/notifications/${occurrence.id}(?:\\?|$)`));
  await page.locator(`#notification-${occurrence.id} a[href^="/incidents/"]`).click();
  await expect(page).toHaveURL(new RegExp(`/incidents/${incidentId}(?:\\?|$)`));
  const notification = page.locator(`#notification-${occurrence.id}`);
  await expect(notification).toContainText('Retries exhausted');
  await notification.getByText('Notification identity and immutable payload', { exact: true }).click();
  await expect(notification.locator('pre')).toContainText(id);
  await checkpoint(page, testInfo, 'exhausted-notification');
  await mode(request, { webhook: 'ok' });
  const retryForm = page.locator(`#retry-notification-${occurrence.id}`);
  const retryReason = retryForm.getByLabel('Retry reason', { exact: true });
  await keyboardFill(page, retryReason, 'Local receiver restored during browser regression');
  await page.keyboard.press('Tab');
  const beforeRetryTick = await page.locator('.live-indicator').textContent();
  await expect(page.locator('.live-indicator')).not.toHaveText(beforeRetryTick);
  await expect(retryReason).toHaveValue('Local receiver restored during browser regression');
  await keyboardSubmit(page, retryForm.getByRole('button', { name: 'Retry notification', exact: true }));
  await expect(notification).toContainText('Receiver accepted', { timeout: 45_000 });
  const retried = (await snapshot(request)).occurrences.find((item) => item.id === occurrence.id);
  expect(retried.payload).toEqual(occurrence.payload);
  expect(retried.destination).toEqual(occurrence.destination);
  expect(retried.attempt_count).toBe(4);
  const receipts = await (await request.get(`${fixtureURL}/records`)).json();
  expect(receipts.records.some((receipt) => receipt.payload.occurrence_id === occurrence.id)).toBe(true);
  await page.setViewportSize({ width: 390, height: 844 });
  await checkpoint(page, testInfo, 'incident-mobile-390');
  await mode(request, { ready: true });
  await measured(request, id);
  await expect(page.locator('.page-heading')).toContainText('Measured recovery');
  await expect(page.locator('#incident-occurrences')).toContainText('Incident ended notification');
  await checkpoint(page, testInfo, 'recovered-incident');
  await page.goto('/checks?view=list');
  await page.setViewportSize({ width: 320, height: 740 });
  await expect(page.locator('[id^="result-"]')).toHaveCount(3);
  await checkpoint(page, testInfo, 'result-inventory-mobile-320');
  await attachState(request, testInfo, 'final-source-monitoring-state');
  expect(pageErrors).toEqual([]);
});

test('shared filters align and remain usable on inventory, configuration and incidents', async ({ page }, testInfo) => {
  for (const path of ['/checks', '/configuration', '/incidents']) {
    await page.goto(path);
    await connected(page);
    for (const width of [1280, 390, 320]) {
      await page.setViewportSize({ width, height: 844 });
      const controls = await page.locator('#inventory-filters').evaluate((form) => {
        const rect = (element) => {
          const box = element.getBoundingClientRect();
          return { id: element.id || element.textContent.trim(), top: box.top, bottom: box.bottom, left: box.left, right: box.right, height: box.height };
        };
        const primary = form.querySelector('.checks-primary-filters') || form;
        const help = form.querySelector('#inventory-environment-help');
        return {
          fields: [...primary.querySelectorAll('input, select')].map(rect),
          actions: [...primary.querySelectorAll('button, a')].map(rect),
          help: help ? rect(help) : null,
        };
      });
      const controlHeight = path === '/checks' ? 42 : 44;
      for (const item of [...controls.fields, ...controls.actions]) {
        expect(item.height, `${path} ${width}px: ${item.id} height`).toBeCloseTo(controlHeight, 0);
        expect(item.left).toBeGreaterThanOrEqual(0);
        expect(item.right).toBeLessThanOrEqual(width + 1);
      }
      const environment = controls.fields.find((item) => item.id === 'inventory-environment');
      const sameRow = [...controls.fields, ...controls.actions].filter((item) => Math.abs(item.top - environment.top) < controlHeight);
      for (const peer of sameRow) {
        expect(peer.top, `Environment aligns with ${peer.id}`).toBeCloseTo(environment.top, 0);
        expect(peer.bottom).toBeCloseTo(environment.bottom, 0);
      }
      if (path === '/checks') {
        expect(controls.help).toBeNull();
      } else {
        expect(controls.actions[0].top).toBeCloseTo(controls.actions[1].top, 0);
        expect(controls.help.top).toBeGreaterThanOrEqual(Math.max(...controls.actions.map((item) => item.bottom)));
      }
      await checkpoint(page, testInfo, `${path.slice(1)}-aligned-filters-${width}`);
    }
    if (path === '/checks') {
      await page.locator('#inventory-view-list').click();
      await page.locator('#inventory-more-filters > summary').click();
      await page.getByLabel('Last measured health', { exact: true }).selectOption('not_measured');
      await expect(page).toHaveURL(/health=not_measured/);
      await expect(page.locator('[id^="result-"]')).toHaveCount(0);
      await expect(page.getByLabel('Last measured health', { exact: true })).toHaveValue('not_measured');
      await page.getByRole('button', { name: 'Clear all filters', exact: true }).click();
      await expect(page.locator('[id^="result-"]')).toHaveCount(3);
    }
  }
});

test('consumer-authored findings retain their measurement provenance when later collection fails', async ({ page, request }, testInfo) => {
  const pageErrors = [];
  page.on('pageerror', (error) => pageErrors.push(error.message));
  const currentConsumer = async () => (await snapshot(request)).assignments.find(
    (item) => item.id === consumerId,
  );
  const warningFinding = '[WARN] Queued count reached the warning threshold';
  const criticalFinding = '[CRIT] Processing is disabled while queued work remains';
  let incidentId;

  try {
    await mode(request, { backlog: 2, processing_enabled: true, data_mode: 'ok', webhook: 'ok' });
    await measured(request, consumerId);
    const result = (await streams(request)).items.find((item) => item.assignment_id === consumerId);
    await page.goto(`/checks/${result.id}`);
    await mode(request, { backlog: 6, processing_enabled: false });
    await measured(request, consumerId, 'CRIT');
    const confirmed = await currentConsumer();
    expect(confirmed.current.summary).toBe('6 queued items');
    expect(confirmed.current.confirmed_params).toMatchObject({ warn_count: 5, crit_count: 10 });

    const details = page.locator('#confirmed-result-details');
    await expect(details.locator('pre')).toBeVisible();
    await expect(details.locator('summary')).toHaveCount(0);
    await expect(page.locator('#check-execution-history')).not.toHaveAttribute('open');
    await expect(details.locator('pre')).toHaveText(confirmed.current.details);
    await expect(details).toContainText('Warning at: 5 items');
    await expect(details).toContainText('Critical at: 10 items');
    await expect(details).toContainText('Processing enabled: False');
    await expect(details).toContainText(warningFinding);
    await expect(details).toContainText(criticalFinding);
    await keyboardSubmit(page, page.locator('#measurement-provenance > summary'));
    await expect(page.locator('#confirmed-configuration')).toBeVisible();
    await expect(page.locator('#confirmed-configuration')).toHaveText(`v${confirmed.current.confirmed_generation}`);
    await expect(page.locator('#check-source')).toContainText(confirmed.source_id);
    await expect(page.locator('#check-source')).toContainText(confirmed.source_revision);
    await expect(page.locator('#check-source')).toContainText(confirmed.definition_revision);

    // A new real measurement forces a patch; primary details stay visible and
    // the operator's optional provenance disclosure stays open.
    const sourceTime = page.locator('#result-measurement time[datetime]');
    const firstSourceTime = await sourceTime.getAttribute('datetime');
    await expect(sourceTime).not.toHaveAttribute('datetime', firstSourceTime);
    await expect(page.locator('#measurement-provenance')).toHaveAttribute('open', '');
    await expect(details.locator('pre')).toHaveText(confirmed.current.details);
    await page.evaluate(() => window.liveSocket.disconnect());
    await expect(page.locator('[data-phx-main]')).not.toHaveClass(/phx-connected/);
    await page.evaluate(() => window.liveSocket.connect());
    await connected(page);
    await expect(details.locator('pre')).toBeVisible();
    await expect(page.locator('#measurement-provenance')).toHaveAttribute('open', '');
    await keyboardSubmit(page, page.locator('#measurement-provenance > summary'));
    await checkpoint(page, testInfo, 'consumer-composite-findings');

    await mode(request, { data_mode: 'crash' });
    let unavailable;
    await expect.poll(async () => {
      const row = await currentConsumer();
      if (row.current.knowledge !== 'unavailable'
        || !row.current.diagnostic?.includes('worker crashed (exit 17)')) return false;
      unavailable = row;
      return true;
    }, { message: 'The injected worker crash must reach the controller', timeout: 45_000 }).toBe(true);
    expect(unavailable.current.health).toBe('CRIT');
    expect(unavailable.current.details).toBe(confirmed.current.details);
    expect(unavailable.current.confirmed_observation_id).not.toBe(unavailable.current.observation_id);
    expect(unavailable.current.execution_details).toBeNull();

    // Compare the retained findings and age with their exact stored observation,
    // not with the crashed run's timestamp or its collection diagnostic.
    const state = await snapshot(request);
    const retained = state.evidence.find((item) => item.id === unavailable.current.confirmed_observation_id);
    expect(retained).toBeTruthy();
    const retainedReport = retained.payload;
    const retainedResult = retainedReport.results.find((item) => item.key === 'backlog');
    expect(retainedResult.details).toBe(unavailable.current.details);
    expect(retainedResult.source_at).toBe(unavailable.current.source_at);
    expect(retainedReport.generation).toBe(unavailable.current.confirmed_generation);

    await expect(page.locator(`#measurement-notice-${consumerId}`)).toContainText('Last measured health is retained');
    await expect(page.locator(`#measurement-notice-${consumerId}`)).toContainText('worker crashed (exit 17)');
    await expect(page.locator('#check-execution-history')).not.toHaveAttribute('open');
    await expect(details.locator('pre')).toBeVisible();
    await expect(details.locator('pre')).toHaveText(retainedResult.details);
    await page.setViewportSize({ width: 390, height: 844 });
    await checkpoint(page, testInfo, 'consumer-retained-findings-mobile-390');

    await page.goto(`/runners/${unavailable.runner_id}`);
    const runnerCoverage = page.locator('#runner-measurements');
    await expect(page.locator('#runner-contact')).toContainText('Recent contact');
    await expect(runnerCoverage).toContainText('2 of 3 active results fresh');
    const unavailableLink = runnerCoverage.locator('a[href*="freshness=unavailable"]');
    await expect(unavailableLink).toBeVisible();
    await expect(unavailableLink).toContainText('1');
    await checkpoint(page, testInfo, 'connected-runner-missing-measurement-390');
    await unavailableLink.click();
    await expect(page.getByLabel('Observing runner', { exact: true })).toHaveValue(unavailable.runner_id);
    await expect(page.locator('[id^="result-"]')).toHaveCount(1);
    await expect(page.locator('[id^="result-"]')).toContainText('Critical');
    await page.locator('[id^="result-"]').getByRole('link').first().click();
    await expect(page).toHaveURL(new RegExp(`/checks/${result.id}(?:\\?|$)`));

    await page.locator('[id^="active-incident-"]').getByRole('link', { name: /Inspect incident/ }).click();
    await expect(page).toHaveURL(/\/incidents\/[0-9a-f-]+(?:\?|$)/);
    incidentId = new URL(page.url()).pathname.split('/').at(-1);
    const incidentState = await snapshot(request);
    const firing = incidentState.occurrences.find(
      (item) => item.incident_id === incidentId && item.kind === 'firing',
    );
    const opening = incidentState.evidence.find((item) => item.id === firing.payload.observation_id).payload;
    const openingResult = opening.results.find((item) => item.key === 'backlog');
    await expect(page.locator('#incident-check-now')).toContainText('Measurement unavailable');
    await expect(page.locator('#incident-current-details pre')).toBeVisible();
    await expect(page.locator('#incident-check-now h2')).toHaveText('Latest measurement');
    await expect(page.locator('#incident-measurements')).not.toHaveAttribute('open', '');
    await keyboardSubmit(page, page.locator('#incident-measurements > summary'));
    const incidentEvidence = page.locator('#incident-measurements .resource').filter({
      hasText: opening.id,
    });
    await expect(incidentEvidence).toHaveCount(1);
    const incidentDetails = incidentEvidence.locator('.diagnostic-details');
    await keyboardSubmit(page, incidentDetails.locator('summary'));
    await expect(incidentDetails).toHaveAttribute('open', '');
    await expect(incidentDetails.locator('summary')).toHaveText('Result details: backlog');
    await expect(incidentDetails).toContainText(warningFinding);
    await expect(incidentDetails).toContainText(criticalFinding);
    const originalEvidence = incidentEvidence.locator('details').filter({
      has: page.getByText('Inspect evidence and original timestamps', { exact: true }),
    });
    await keyboardSubmit(page, originalEvidence.locator('summary'));
    await expect(originalEvidence.locator('pre')).toContainText(opening.id);
    await expect(originalEvidence.locator('pre')).toContainText(`"source_at": "${openingResult.source_at}"`);
    await expect(originalEvidence.locator('pre')).toContainText(`"generation": ${opening.generation}`);
    await page.setViewportSize({ width: 320, height: 740 });
    await keyboardSubmit(page, page.locator('#incident-acknowledgement-shortcut'));
    await expect(page.locator('#incident-acknowledgement')).toBeFocused();
    await expect(page.locator('#incident-acknowledgement-heading')).toBeInViewport();
    await expect(page.locator('#active-acknowledgement')).toHaveCount(0);
    await checkpoint(page, testInfo, 'consumer-incident-findings-mobile-320');
    await attachState(request, testInfo, 'consumer-findings-after-collection-failure');
  } finally {
    await mode(request, { backlog: 2, processing_enabled: true, data_mode: 'ok', webhook: 'ok' });
    await measured(request, consumerId);
  }

  await expect(page.locator('.page-heading')).toContainText('Measured recovery');
  const recovered = (await snapshot(request)).incidents.find((item) => item.id === incidentId);
  expect(recovered.status).toBe('closed');
  expect(recovered.closure_reason).toBe('measured_recovery');
  await expect(page.locator('#incident-current-details')).toContainText('Processing enabled: True');
  await expect(page.locator('#incident-current-details')).not.toContainText(criticalFinding);
  await expect(page.locator('#incident-measurements')).toContainText(criticalFinding);
  await checkpoint(page, testInfo, 'consumer-recovered-with-preserved-findings');
  expect(pageErrors).toEqual([]);
});
