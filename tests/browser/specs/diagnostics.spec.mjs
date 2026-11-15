import { unpackAPI } from '../support/helpers.mjs';
// Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
// SPDX-License-Identifier: Apache-2.0
import { test, expect } from '@playwright/test';
import { checkpoint, connected, fixtureURL, measured, mode, snapshot, streams, expectInvestigationReturn } from '../support/helpers.mjs';
import { demoAssignments } from '../support/helpers.mjs';

let filesystemId, httpId, consumerId;
test.beforeEach(async ({ request }) => {
  const checks = await demoAssignments(request);
  ({ filesystem: { id: filesystemId }, http: { id: httpId }, consumer: { id: consumerId } } = checks);
});

async function backlogResult(request) {
  return (await streams(request)).items.find((item) => item.assignment_id === consumerId);
}

test('measurement investigation distinguishes collection failure from lost runner contact and follows real recovery', async ({ page, request }, testInfo) => {
  const errors = [];
  page.on('pageerror', (error) => errors.push(error.message));
  await mode(request, {
    ready: true, backlog: 2, processing_enabled: true, data_mode: 'ok',
    offline_installations: [], webhook: 'ok',
  });
  await measured(request, consumerId);
  const baseline = await backlogResult(request);
  expect(baseline.source_id).toBe('mondek-demo');
  const runner = (await snapshot(request)).runners.find((item) => item.id === baseline.runner_id);
  const filteredPath = `/checks?${new URLSearchParams({
    freshness: 'unavailable', runner_id: runner.id,
  })}`;

  try {
    // This changes the real HTTP datasource response. Its installed Python
    // worker exceeds its execution deadline and reports incomplete collection.
    await mode(request, { data_mode: 'slow' });
    let unavailable;
    await expect.poll(async () => {
      const result = await backlogResult(request);
      if (result.current.knowledge !== 'unavailable'
        || !result.current.diagnostic?.includes('worker execution timed out')) return false;
      unavailable = result;
      return true;
    }, { timeout: 45_000, message: 'The actual datasource timeout must reach the controller' }).toBe(true);
    expect(unavailable.current.health).toBe('OK');
    expect(unavailable.current.confirmed_observation_id).not.toBe(unavailable.current.observation_id);

    await page.goto(filteredPath);
    await connected(page);
    await expect(page.locator('#preview-check-results tbody tr')).toHaveCount(1);
    await page.locator(`#open-result-${baseline.id}`).click();
    await expect(page.locator('#overview-panel')).toBeVisible();
    const selectedResultURL = page.url();
    const selectedResult = page.locator('#overview-panel');
    await expect(selectedResult).toContainText('Collection unavailable');
    await expect(selectedResult.locator('section[id$="collection-diagnostics"]')).toContainText(unavailable.current.diagnostic);
    await selectedResult.getByRole('link', {name: 'Open as page', exact: true}).click();
    await connected(page);
    await expect(page.locator('#preview-result-page')).toBeVisible();
    await expect(page).toHaveURL(url => url.searchParams.get('surface') === 'page' || url.pathname.endsWith('/full'));
    const investigationURL = page.url();
    const assessment = page.locator('#preview-result-page section[id$="collection-diagnostics"]');
    await expect(assessment).toContainText('Collection unavailable');
    await expect(assessment).toContainText(runner.label);
    await expect(page.locator('#preview-result-page')).toContainText('retained');
    await checkpoint(page, testInfo, 'collection-timeout-with-owning-runner');

    // Copyable context excludes raw datasource URLs, parameters and execution
    // diagnostics, even though those details are available in the investigation.
    const prompt = page.locator('[id$="collection-agent-prompt"]');
    await prompt.locator(':scope > summary').click();
    const promptText = page.locator('[id$="collection-agent-prompt-text"]');
    const shared = await promptText.inputValue();
    expect(shared).toContain(runner.id);
    expect(shared).toContain(`"check_id":"${consumerId}"`);
    expect(shared).toContain('read-only');
    expect(shared).not.toContain('http://target:8080/data');
    expect(shared).not.toContain(unavailable.current.diagnostic);
    expect(shared).not.toContain('"params"');
    await page.locator('[id$="collection-agent-prompt-select"]').click();
    await expect(promptText).toBeFocused();
    expect(await promptText.evaluate((element) => element.selectionEnd - element.selectionStart)).toBe(shared.length);
    await page.setViewportSize({ width: 320, height: 740 });
    await checkpoint(page, testInfo, 'collection-investigation-prompt-320');

    await page.evaluate(() => window.liveSocket.disconnect());
    await expect(page.locator('[data-phx-main]')).not.toHaveClass(/phx-connected/);
    await page.evaluate(() => window.liveSocket.connect());
    await connected(page);
    await expect(page).toHaveURL(investigationURL);
    await expect(prompt).toHaveAttribute('open', '');
    await expect(assessment).toContainText('Collection unavailable');
    await page.reload();
    await connected(page);
    await expect(page).toHaveURL(investigationURL);
    await expect(assessment).toContainText('worker execution timed out');
    await page.getByRole('link', {name: 'Open fly-over', exact: true}).click();
    await expectInvestigationReturn(page, selectedResultURL, `result:${baseline.id}`);
    await expect(page.locator('#overview-panel')).toHaveAttribute('data-panel-path', new RegExp(baseline.id));
    await page.locator('#overview-panel').getByRole('link', {name: 'Open as page', exact: true}).click();
    await expect(page).toHaveURL(investigationURL);

    // Restored collection changes the finding on the open page without a reload.
    await mode(request, { data_mode: 'ok' });
    await measured(request, consumerId);
    await expect(assessment).toContainText('Measurement current');
    await expect(assessment).toContainText('2 queued items');
    await expect(assessment).not.toContainText('worker execution timed out');
    await checkpoint(page, testInfo, 'collection-restored-live-320');

    // Only controller transport is partitioned. The same worker can still read
    // the fixture and buffer new WARN measurements while contact becomes overdue.
    await mode(request, { offline_installations: [runner.id], backlog: 6 });
    const blockedAt = Date.now();
    await expect(assessment).toContainText('Runner contact overdue', { timeout: 45_000 });
    const aged = await backlogResult(request);
    expect(aged.id).toBe(baseline.id);
    expect(aged.runner_id).toBe(runner.id);
    expect(aged.current.knowledge).toBe('stale');
    expect(aged.current.health).toBe('OK');
    await expect(assessment).not.toContainText('worker execution timed out');
    await page.setViewportSize({ width: 1280, height: 900 });
    await checkpoint(page, testInfo, 'transport-contact-overdue-retains-evidence');
    await page.reload();
    await connected(page);
    await expect(assessment).toContainText('Runner contact overdue');
    await page.getByRole('link', {name: 'Inspect runner connection', exact: true}).click();
    await expect(page.locator('#overview-panel')).toContainText(runner.label);
    await page.locator('#overview-panel [data-overview-close]').click();
    await expect(page).toHaveURL(investigationURL);
    await expect(assessment).toContainText('Runner contact overdue');

    const resumedAt = Date.now();
    await mode(request, { offline_installations: [] });
    await measured(request, consumerId, 'WARN');
    await expect(assessment).toContainText('Measurement current');
    await expect.poll(async () => {
      const response = await request.get(`${fixtureURL}/transport-records`);
      expect(response.ok()).toBeTruthy();
      const records = (await response.json().then(unpackAPI)).records;
      return records.flatMap((record) => record.request.reports).some((report) =>
        report.assignment_id === consumerId
        && Date.parse(report.started_at) > blockedAt
        && Date.parse(report.started_at) < resumedAt
        && report.results.some((result) => result.key === 'backlog' && result.health === 'WARN'));
    }, { message: 'Reports executed during the partition must arrive with their original execution times' }).toBe(true);
    const restored = await backlogResult(request);
    expect(restored.id).toBe(baseline.id);
    expect(restored.runner_id).toBe(runner.id);
    expect(restored.current.session_id).toBe(baseline.current.session_id);
    await checkpoint(page, testInfo, 'transport-reconnected-with-real-measurement');

    await mode(request, { backlog: 2 });
    await measured(request, consumerId);
    await expect(assessment).toContainText('Measurement current');
    expect(errors).toEqual([]);
  } finally {
    await mode(request, { ready: true, backlog: 2, data_mode: 'ok', offline_installations: [], webhook: 'ok' });
  }
});
