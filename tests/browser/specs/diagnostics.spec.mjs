// Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
// SPDX-License-Identifier: Apache-2.0
import { test, expect } from '@playwright/test';
import { checkpoint, connected, fixtureURL, measured, mode, snapshot, streams } from '../support/helpers.mjs';
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
    tab: 'custom', view: 'list', freshness: 'unavailable', runner_id: runner.id,
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
    await expect(page.locator('[id^="result-"]')).toHaveCount(1);
    await page.locator(`#result-${baseline.id} a[href^="/checks/"]`).first().click();
    await expect(page).toHaveURL(new RegExp(`/checks/${baseline.id}\\?`));
    await connected(page);
    const selectedResultURL = page.url();
    const selectedResult = new URL(selectedResultURL);
    expect(selectedResult.pathname).toBe(`/checks/${baseline.id}`);
    expect(new URLSearchParams(selectedResult.searchParams.get('return_to').split('?')[1]).get('runner_id')).toBe(runner.id);
    await page.getByRole('link', { name: 'Investigate measurement', exact: true }).first().click();
    await expect(page).toHaveURL(new RegExp(`/checks/${baseline.id}/diagnostics\\?`));
    await connected(page);
    const investigationURL = page.url();
    expect(new URL(investigationURL).pathname).toBe(`/checks/${baseline.id}/diagnostics`);
    await expect(page.locator('#measurement-investigation')).toBeVisible();
    await expect(page.locator('#investigation-finding h2')).toHaveText('Collection unavailable');
    await expect(page.locator('#investigation-next-action a')).toHaveAttribute('href', '#latest-execution');
    await expect(page.locator('.investigation-section').first()).toHaveText(/Latest execution evidence/);
    await expect(page.locator('#latest-execution')).toContainText(unavailable.current.diagnostic);
    await expect(page.locator('#runner-signals')).toContainText(runner.label);
    await expect(page.locator('#notification-boundary')).toContainText(/notification/i);
    await checkpoint(page, testInfo, 'collection-timeout-with-owning-runner');

    // Copyable context excludes raw datasource URLs, parameters and execution
    // diagnostics, even though those details are available in the investigation.
    const prompt = page.locator('#collection-agent-prompts-collection');
    await prompt.locator(':scope > summary').click();
    const promptText = page.locator('#collection-agent-prompts-collection-text');
    const shared = await promptText.inputValue();
    expect(shared).toContain(runner.id);
    expect(shared).toContain(`"check_id":"${consumerId}"`);
    expect(shared).toContain('read-only');
    expect(shared).not.toContain('http://target:8080/data');
    expect(shared).not.toContain(unavailable.current.diagnostic);
    expect(shared).not.toContain('"params"');
    await page.locator('#collection-agent-prompts-collection-select').click();
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
    await expect(page.locator('#investigation-finding h2')).toHaveText('Collection unavailable');
    await page.reload();
    await connected(page);
    await expect(page).toHaveURL(investigationURL);
    await expect(page.locator('#latest-execution')).toContainText('worker execution timed out');
    await page.locator('#investigation-back').click();
    await expect(page).toHaveURL(selectedResultURL);
    await page.getByRole('link', { name: 'Investigate measurement', exact: true }).first().click();
    await connected(page);

    // Restored collection changes the finding on the open page without a reload.
    await mode(request, { data_mode: 'ok' });
    await measured(request, consumerId);
    await expect(page.locator('#investigation-finding h2')).toHaveText('Measurement current');
    await expect(page.locator('#latest-execution')).toContainText('2 queued items');
    await expect(page.locator('#latest-execution')).toContainText('Warning at: 5 items');
    await expect(page.locator('#latest-execution')).not.toContainText('worker execution timed out');
    await checkpoint(page, testInfo, 'collection-restored-live-320');

    // Only controller transport is partitioned. The same worker can still read
    // the fixture and buffer new WARN measurements while contact becomes overdue.
    await mode(request, { offline_installations: [runner.id], backlog: 6 });
    const blockedAt = Date.now();
    await expect(page.locator('#investigation-finding h2')).toHaveText('Runner contact overdue', { timeout: 45_000 });
    const aged = await backlogResult(request);
    expect(aged.id).toBe(baseline.id);
    expect(aged.runner_id).toBe(runner.id);
    expect(aged.current.knowledge).toBe('stale');
    expect(aged.current.health).toBe('OK');
    await expect(page.locator('#latest-execution')).not.toContainText('worker execution timed out');
    await page.setViewportSize({ width: 1280, height: 900 });
    await checkpoint(page, testInfo, 'transport-contact-overdue-retains-evidence');
    await page.reload();
    await connected(page);
    await expect(page.locator('#investigation-finding h2')).toHaveText('Runner contact overdue');
    await expect(page.locator('.investigation-section').first()).toHaveText(/Runner contact and execution/);
    await page.getByRole('link', {name: 'Inspect runner connection', exact: true}).click();
    await expect(page).toHaveURL(new RegExp(`/runners/${runner.id}\\?`));
    await page.locator('a.back').click();
    await expect(page).toHaveURL(investigationURL);
    await expect(page.locator('#investigation-finding h2')).toHaveText('Runner contact overdue');

    const resumedAt = Date.now();
    await mode(request, { offline_installations: [] });
    await measured(request, consumerId, 'WARN');
    await expect(page.locator('#investigation-finding h2')).toHaveText('Measurement current');
    await expect.poll(async () => {
      const response = await request.get(`${fixtureURL}/transport-records`);
      expect(response.ok()).toBeTruthy();
      const records = (await response.json()).records;
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
    await expect(page.locator('#investigation-finding h2')).toHaveText('Measurement current');
    expect(errors).toEqual([]);
  } finally {
    await mode(request, { ready: true, backlog: 2, data_mode: 'ok', offline_installations: [], webhook: 'ok' });
  }
});
