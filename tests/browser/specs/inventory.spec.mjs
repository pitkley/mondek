// Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
// SPDX-License-Identifier: Apache-2.0
import { test, expect } from '@playwright/test';
import { checkpoint, connected, mode, streams } from '../support/helpers.mjs';

const hostFilters = { search: 'host:inventory-shared', environment: 'inventory-test' };
const hostURL = `/checks?${new URLSearchParams({ ...hostFilters, view: 'list' })}`;

function hostGroup(page) {
  return page.locator('.target-group').filter({
    has: page.getByRole('heading', { name: 'Shared inventory host', exact: true }),
  });
}

async function allHostResults(request, filters = {}) {
  const first = await streams(request, { ...hostFilters, ...filters, page_size: 100 });
  const items = [...first.items];
  for (let page = 2; items.length < first.total; page += 1) {
    const next = await streams(request, { ...hostFilters, ...filters, page_size: 100, page });
    items.push(...next.items);
  }
  return items;
}

async function healthy(request) {
  await expect.poll(async () => (await streams(request, { freshness: 'fresh', health: 'OK' })).total,
    { timeout: 120_000, message: 'Both real observers must measure all 122 declared results' }).toBe(122);
}

async function visibleIDs(page) {
  return page.locator('[id^="result-"]').evaluateAll((rows) => rows.map((row) => row.id));
}

async function mobileEvidence(page, result, observer, freshness) {
  const row = page.locator(`#result-${result.id}`);
  await expect(row.locator('.target-result-observer')).toHaveText(observer);
  if (freshness === 'Stale') {
    await expect(row.locator('time')).toHaveAttribute('datetime', result.current.source_at);
  } else {
    // Live successful collection may legitimately advance between API and DOM reads.
    await expect(row.locator('time')).toHaveAttribute('datetime', /^\d{4}-\d{2}-\d{2}T/);
  }
  await expect(row.locator('[data-label="Measured"]')).toContainText(freshness);
  const bounds = await row.evaluate((element) => {
    const wrapper = element.closest('.checks-table-wrap');
    return {
      overflow: wrapper.scrollWidth - wrapper.clientWidth,
      cells: [...element.querySelectorAll('td')].map((cell) => {
        const bounds = cell.getBoundingClientRect();
        return { left: bounds.left, right: bounds.right, overflow: cell.scrollWidth - cell.clientWidth };
      }),
      viewport: document.documentElement.clientWidth,
    };
  });
  expect(bounds.overflow, 'Result evidence must not require horizontal table scrolling').toBeLessThanOrEqual(1);
  for (const cell of bounds.cells) {
    expect(cell.left).toBeGreaterThanOrEqual(0);
    expect(cell.right).toBeLessThanOrEqual(bounds.viewport);
    expect(cell.overflow, 'Observer, age and summary must fit their labeled cell').toBeLessThanOrEqual(1);
  }
}

test('task views stay predictable through scoped searches, target selection, reload and reconnect', async ({ page, request }, testInfo) => {
  const errors = [];
  page.on('pageerror', (error) => errors.push(error.message));
  await mode(request, { backlog: 2, offline_installations: [], webhook: 'ok' });
  await healthy(request);
  await page.goto('/checks');
  await connected(page);
  const list = page.locator('#inventory-view-list');
  const targets = page.locator('#inventory-view-targets');
  await expect(targets).toHaveAttribute('aria-pressed', 'true');
  await expect(page.locator('.target-group')).toHaveCount(1);
  await expect(page.locator('.checks-target-index button[id^="inventory-target-"]')).toHaveCount(2);
  const host = page.locator('.checks-target-index button[id^="inventory-target-"]').filter({ hasText: 'Shared inventory host' });
  await host.click();
  await expect(hostGroup(page)).toBeVisible();
  await expect(hostGroup(page).locator('.target-group-size')).toContainText('120 matching results');
  await expect(page.locator('[id^="result-"]')).toHaveCount(50);
  const targetIndexBounds = await page.locator('#inventory-target-index').boundingBox();
  const targetOptionsBounds = await page.locator('#inventory-target-options').boundingBox();
  // A tall result page must not stretch the independent index and push its pager down.
  expect(targetIndexBounds.y + targetIndexBounds.height)
    .toBeLessThanOrEqual(targetOptionsBounds.y + targetOptionsBounds.height + 2);
  const selectedTarget = new URL(page.url()).searchParams.get('target');
  expect(selectedTarget).toBeTruthy();
  const firstTargetPage = await visibleIDs(page);
  await page.locator('#inventory-pagination-bottom').getByRole('link', { name: 'Next', exact: true }).press('Enter');
  await expect(page.locator('#check-inventory')).toBeFocused();
  await expect(hostGroup(page).locator('.target-group-range')).toContainText('51–100 of 120');
  expect(new URL(page.url()).searchParams.get('target')).toBe(selectedTarget);
  expect((await visibleIDs(page)).filter((id) => firstTargetPage.includes(id))).toEqual([]);
  await list.click();
  await expect(page.locator('.target-group')).toHaveCount(2);
  await targets.click();
  await expect(host).toHaveAttribute('aria-pressed', 'true');
  expect(new URL(page.url()).searchParams.get('target')).toBe(selectedTarget);
  await page.setViewportSize({ width: 390, height: 844 });
  await checkpoint(page, testInfo, 'target-view-selected-host-390');

  await mode(request, { backlog: 12 });
  try {
    await expect.poll(async () => (await streams(request, { ...hostFilters, health: 'CRIT', freshness: 'fresh' })).total).toBe(2);
    await page.locator('#inventory-tab-critical').click();
    await expect(list).toHaveAttribute('aria-pressed', 'true');
    await expect(page.locator('[id^="result-"]')).toHaveCount(2);
    await expect(hostGroup(page).locator('.target-group-size')).toContainText('2 of 120 results match');
    await expect(page.locator('#inventory-pagination-top')).toHaveCount(0);
    await page.setViewportSize({ width: 320, height: 740 });
    await checkpoint(page, testInfo, 'critical-default-compact-list-320');
    await targets.click();
    await page.locator('#inventory-tab-attention').click();
    await expect(page.locator('#inventory-tab-attention')).toHaveAttribute('aria-pressed', 'true');
    await expect(list).toHaveAttribute('aria-pressed', 'true');
    await page.locator('#inventory-tab-gaps').click();
    await expect(page.locator('#inventory-tab-gaps')).toHaveAttribute('aria-pressed', 'true');
    await expect(list).toHaveAttribute('aria-pressed', 'true');
    await expect(page.locator('#check-inventory')).toContainText('No matching results');
    await page.locator('#inventory-tab-all').click();
    await expect(page.locator('#inventory-tab-all')).toHaveAttribute('aria-pressed', 'true');
    await expect(targets).toHaveAttribute('aria-pressed', 'true');
    await list.click();
    await expect(list).toHaveAttribute('aria-pressed', 'true');
    await page.locator('#inventory-tab-critical').click();
    await expect(page.locator('#inventory-tab-critical')).toHaveAttribute('aria-pressed', 'true');
    await expect(targets).toHaveAttribute('aria-pressed', 'true');

    await page.getByLabel('Search', { exact: true }).fill('Host signal 059');
    await expect(page.getByLabel('Search', { exact: true })).toHaveValue('Host signal 059');
    await expect(page).toHaveURL(/search=Host\+signal\+059/);
    await expect(targets).toHaveAttribute('aria-pressed', 'true');
    await expect(page.locator('[id^="result-"]')).toHaveCount(2);
    await page.getByRole('button', { name: 'Clear', exact: true }).click();
    await expect(page.getByLabel('Search', { exact: true })).toHaveValue('');
    await expect(page.locator('#inventory-tab-critical')).toHaveAttribute('aria-pressed', 'true');
    await expect(targets).toHaveAttribute('aria-pressed', 'true');
    const rememberedURL = page.url();
    const originalIDs = await visibleIDs(page);
    await page.reload();
    await connected(page);
    await expect(page).toHaveURL(rememberedURL);
    await expect(targets).toHaveAttribute('aria-pressed', 'true');
    expect(await visibleIDs(page)).toEqual(originalIDs);
    await page.evaluate(() => window.liveSocket.disconnect());
    await expect(page.locator('[data-phx-main]')).not.toHaveClass(/phx-connected/);
    await page.evaluate(() => window.liveSocket.connect());
    await connected(page);
    await expect(page).toHaveURL(rememberedURL);
    await expect(targets).toHaveAttribute('aria-pressed', 'true');
    await page.locator('#inventory-tab-all').click();
    await expect(list).toHaveAttribute('aria-pressed', 'true');
    await page.locator('#inventory-tab-critical').click();
    await expect(targets).toHaveAttribute('aria-pressed', 'true');
    expect(await visibleIDs(page)).toEqual(originalIDs);
    await checkpoint(page, testInfo, 'per-tab-view-preferences-after-reconnect-320');
    expect(errors).toEqual([]);
  } finally {
    await mode(request, { backlog: 2, offline_installations: [] });
  }
});

test('shared targets remain complete across bounded pages, filters and browser reconnect', async ({ page, request }, testInfo) => {
  const errors = [];
  page.on('pageerror', (error) => errors.push(error.message));
  await mode(request, { backlog: 2, offline_installations: [], webhook: 'ok' });
  await healthy(request);
  const original = await allHostResults(request);
  expect(original).toHaveLength(120);
  expect(new Set(original.map((row) => row.runner_id)).size).toBe(2);
  const observerA = original.find((row) => row.runner_label === 'Inventory observer A').runner_id;

  await page.goto('/checks?view=list');
  await connected(page);
  await expect(page.locator('.target-group')).toHaveCount(2);
  const service = page.locator('.target-group').filter({
    has: page.getByRole('heading', { name: 'Fixture service', exact: true }),
  });
  await expect(service.locator('.target-kind')).toContainText(/service/i);
  await expect(service.locator('.target-group-size')).toContainText('2 matching results');
  await expect(service.locator('[id^="result-"]')).toHaveCount(2);

  await page.goto(hostURL);
  await connected(page);
  await expect(page.locator('[id^="result-"]')).toHaveCount(50);
  await expect(hostGroup(page).locator('.target-group-size')).toContainText('120 matching results');
  await expect(hostGroup(page).locator('.target-group-range')).toContainText('1–50 of 120');
  await expect(hostGroup(page).locator('.target-group-range')).toContainText('Continues on the next page');
  await expect(page.locator('#inventory-view-list')).toHaveAttribute('aria-pressed', 'true');
  const first = await visibleIDs(page);
  await checkpoint(page, testInfo, 'grouped-inventory-complete-target-summary');

  await page.locator('#inventory-pagination-bottom').getByRole('link', { name: 'Next', exact: true }).press('Enter');
  await expect(page).toHaveURL(/page=2/);
  await expect(page.locator('#check-inventory')).toBeFocused();
  await expect.poll(async () => page.locator('#check-inventory').evaluate((element) => element.getBoundingClientRect().top))
    .toBeGreaterThanOrEqual(-1);
  expect((await page.locator('#check-inventory').boundingBox()).y).toBeLessThan(100);
  await expect(hostGroup(page).locator('.target-group-range')).toContainText('51–100 of 120');
  await expect(hostGroup(page).locator('.target-group-range')).toContainText('Continued from the previous page');
  const second = await visibleIDs(page);
  expect(second.filter((id) => first.includes(id))).toEqual([]);
  const secondURL = page.url();
  await page.evaluate(() => window.liveSocket.disconnect());
  await expect(page.locator('[data-phx-main]')).not.toHaveClass(/phx-connected/);
  await page.evaluate(() => window.liveSocket.connect());
  await connected(page);
  await expect(page).toHaveURL(secondURL);
  await expect(page.getByLabel('Search', { exact: true })).toHaveValue(hostFilters.search);
  await expect(page.getByLabel('Monitored environment', { exact: true })).toHaveValue(hostFilters.environment);
  await expect(hostGroup(page).locator('.target-group-range')).toContainText('51–100 of 120');
  expect(await visibleIDs(page)).toEqual(second);

  await page.locator('#inventory-pagination-top').getByRole('link', { name: 'Next', exact: true }).click();
  await expect(hostGroup(page).locator('.target-group-range')).toContainText('101–120 of 120');
  await expect(page.locator('[id^="result-"]')).toHaveCount(20);
  const third = await visibleIDs(page);
  expect([...first, ...second, ...third].sort()).toEqual(original.map((row) => `result-${row.id}`).sort());
  await page.setViewportSize({ width: 390, height: 844 });
  await checkpoint(page, testInfo, 'grouped-inventory-final-page-390');

  await page.getByLabel('Observing runner', { exact: true }).selectOption(observerA);
  await expect(hostGroup(page).locator('.target-group-size')).toContainText('60 of 120 results match');
  await expect(hostGroup(page).locator('.target-group-range')).toContainText('1–50 of 60');
  await page.locator('#inventory-pagination-top').getByRole('link', { name: 'Next', exact: true }).click();
  await expect(page.locator('[id^="result-"]')).toHaveCount(10);
  await expect(hostGroup(page).locator('.target-group-range')).toContainText('51–60 of 60');
  await page.setViewportSize({ width: 320, height: 740 });
  await checkpoint(page, testInfo, 'grouped-inventory-one-observer-320');

  // Expand from page two of one observer's results without losing that
  // investigation. The exact target contains both observers, not the service.
  const investigationURL = page.url();
  const investigationIDs = await visibleIDs(page);
  await hostGroup(page).getByRole('link', { name: /Show all observations/ }).click();
  await expect(page.locator('#checks-target-context')).toBeVisible();
  await expect(page.locator('#checks-investigation-return')).toHaveAttribute('href',
    new URL(investigationURL).pathname + new URL(investigationURL).search);
  const targetScope = new URL(page.url()).searchParams.get('target_scope');
  expect(targetScope).toBeTruthy();
  await expect(hostGroup(page).locator('.target-group-size')).toContainText('120 matching results');
  await expect(page.locator('.target-group')).toHaveCount(1);
  await expect(page.getByLabel('Observing runner', { exact: true })).toHaveValue('');
  await expect(page.getByLabel('Search', { exact: true })).toHaveValue('');
  await page.locator('#inventory-tab-critical').click();
  await expect(page.locator('[id^="result-"]')).toHaveCount(0);
  await expect(page.locator('#checks-target-context')).toContainText('Shared inventory host');
  expect(new URL(page.url()).searchParams.get('target_scope')).toBe(targetScope);
  await page.locator('#inventory-tab-all').click();
  await expect(page.locator('#inventory-tab-all')).toHaveAttribute('aria-pressed', 'true');
  await page.locator('#inventory-view-list').click();
  await expect(page.locator('#inventory-view-list')).toHaveAttribute('aria-pressed', 'true');
  await expect(page.locator('.target-group')).toHaveCount(1);
  await page.locator('#inventory-pagination-top').getByRole('link', { name: 'Next', exact: true }).click();
  await expect(hostGroup(page).locator('.target-group-range')).toContainText('51–100 of 120');
  await expect(page).toHaveURL(/(?:\?|&)page=2(?:&|$)/);
  const contextURL = page.url();
  const contextIDs = await visibleIDs(page);
  await page.locator('[id^="result-"]').first().getByRole('link').first().click();
  await expect(page.locator('#result-target-context')).toBeVisible();
  await expect(page).toHaveURL(/\/checks\/[0-9a-f-]+(?:\?|$)/);
  const detailURL = page.url();
  await page.locator('#result-target-context').click();
  await expect(page.locator('#checks-target-context')).toBeVisible();
  expect(new URL(page.url()).searchParams.get('target_scope')).toBe(targetScope);
  await expect(page.locator('#checks-investigation-return')).toHaveAttribute('href',
    new URL(investigationURL).pathname + new URL(investigationURL).search);
  await page.goBack();
  await expect(page).toHaveURL(detailURL);
  await connected(page);
  await page.getByRole('link', { name: 'Review configuration', exact: true }).click();
  await expect(page).toHaveURL(/\/configuration\/[0-9a-f-]+(?:\?|$)/);
  await page.getByRole('link', { name: 'Back to result', exact: true }).click();
  await expect(page).toHaveURL(detailURL);
  await page.getByRole('link', { name: 'Back to results', exact: true }).click();
  await expect(page).toHaveURL(contextURL);
  expect(await visibleIDs(page)).toEqual(contextIDs);
  await page.reload();
  await connected(page);
  await page.evaluate(() => window.liveSocket.disconnect());
  await expect(page.locator('[data-phx-main]')).not.toHaveClass(/phx-connected/);
  await page.evaluate(() => window.liveSocket.connect());
  await connected(page);
  await expect(page).toHaveURL(contextURL);
  expect(await visibleIDs(page)).toEqual(contextIDs);
  await checkpoint(page, testInfo, 'exact-target-context-reconnect-and-detail-return-320');
  await page.locator('#checks-investigation-return').click();
  await expect(page).toHaveURL(investigationURL);
  expect(await visibleIDs(page)).toEqual(investigationIDs);
  await expect(page.getByLabel('Observing runner', { exact: true })).toHaveValue(observerA);
  expect(errors).toEqual([]);
});

test('short result pages preserve group scope, inspection return paths and actual reconnect', async ({ page, request }, testInfo) => {
  const errors = [];
  page.on('pageerror', (error) => errors.push(error.message));
  await mode(request, { backlog: 2, offline_installations: [], webhook: 'ok' });
  await healthy(request);
  const original = await allHostResults(request);
  const observerA = original.find((row) => row.runner_label === 'Inventory observer A').runner_id;
  await page.goto(`${hostURL}&page_size=25&page=2`);
  await connected(page);
  const size = page.getByLabel('Results per page', { exact: true });
  await expect(size).toHaveValue('25');
  await expect(page.locator('[id^="result-"]')).toHaveCount(25);
  await expect(hostGroup(page).locator('.target-group-range')).toContainText('26–50 of 120');
  await expect(hostGroup(page).locator('.target-group-size')).toContainText('120 matching results');

  await size.focus();
  await size.selectOption('10');
  await expect(page.locator('[id^="result-"]')).toHaveCount(10);
  await expect(size).toBeFocused();
  await expect(page.locator('#inventory-pagination-top')).toContainText('Page 1 of 12');
  await expect(hostGroup(page).locator('.target-group-range')).toContainText('1–10 of 120');
  await expect(page.getByLabel('Search', { exact: true })).toHaveValue(hostFilters.search);
  await expect(page.getByLabel('Monitored environment', { exact: true })).toHaveValue(hostFilters.environment);
  await page.setViewportSize({ width: 390, height: 844 });
  await checkpoint(page, testInfo, 'ten-results-with-complete-group-summary-390');

  await page.locator('#inventory-pagination-top').getByRole('link', { name: 'Next', exact: true }).press('Enter');
  await expect(page.locator('#check-inventory')).toBeFocused();
  await expect(hostGroup(page).locator('.target-group-range')).toContainText('11–20 of 120');
  const secondURL = page.url();
  const ids = await visibleIDs(page);
  await page.goBack();
  await expect(size).toHaveValue('10');
  await expect(hostGroup(page).locator('.target-group-range')).toContainText('1–10 of 120');
  await page.goForward();
  await expect(page).toHaveURL(secondURL);
  await expect(hostGroup(page).locator('.target-group-range')).toContainText('11–20 of 120');
  expect(await visibleIDs(page)).toEqual(ids);
  await page.evaluate(() => window.liveSocket.disconnect());
  await expect(page.locator('[data-phx-main]')).not.toHaveClass(/phx-connected/);
  await page.evaluate(() => window.liveSocket.connect());
  await connected(page);
  await expect(page).toHaveURL(secondURL);
  await expect(size).toHaveValue('10');
  expect(await visibleIDs(page)).toEqual(ids);
  await page.reload();
  await connected(page);
  await expect(page).toHaveURL(secondURL);
  await expect(size).toHaveValue('10');
  await expect(hostGroup(page).locator('.target-group-range')).toContainText('11–20 of 120');
  await page.setViewportSize({ width: 320, height: 740 });
  await checkpoint(page, testInfo, 'short-page-restored-after-reconnect-and-reload-320');

  const returnURL = new URL(secondURL);
  returnURL.hash = '';
  await page.locator('[id^="result-"]').first().getByRole('link').first().click();
  await expect(page).toHaveURL(/\/checks\/[0-9a-f-]+(?:\?|$)/);
  await page.getByRole('link', { name: 'Review configuration', exact: true }).click();
  await page.getByRole('link', { name: 'Back to result', exact: true }).click();
  await expect(page).toHaveURL(/\/configuration\/[0-9a-f-]+(?:\?|$)/);
  await page.getByRole('link', { name: 'Back to results', exact: true }).click();
  await expect(page).toHaveURL(returnURL.href);
  await expect(size).toHaveValue('10');
  expect(await visibleIDs(page)).toEqual(ids);

  await page.getByLabel('Observing runner', { exact: true }).selectOption(observerA);
  await expect(size).toHaveValue('10');
  await expect(page.locator('#inventory-pagination-top')).toContainText('Page 1 of 6');
  await expect(hostGroup(page).locator('.target-group-size')).toContainText('60 of 120 results match');
  await size.selectOption('100');
  await expect(page.locator('[id^="result-"]')).toHaveCount(60);
  await expect(page.locator('#inventory-pagination-top')).toHaveCount(0);
  await expect(page.locator('#inventory-pagination-bottom')).toHaveCount(0);
  await expect(page.getByLabel('Observing runner', { exact: true })).toHaveValue(observerA);

  // Both independent forms can contain unsent edits when transport returns.
  await page.evaluate(() => window.liveSocket.disconnect());
  await expect(page.locator('[data-phx-main]')).not.toHaveClass(/phx-connected/);
  await size.selectOption('25');
  await page.getByLabel('Search', { exact: true }).fill('Host signal 059');
  await page.keyboard.press('Tab');
  await page.evaluate(() => window.liveSocket.connect());
  await connected(page);
  await expect(size).toHaveValue('25');
  await expect(page.getByLabel('Search', { exact: true })).toHaveValue('Host signal 059');
  await expect(page.getByLabel('Observing runner', { exact: true })).toHaveValue(observerA);
  await expect(page.locator('[id^="result-"]')).toHaveCount(1);
  await expect(page.locator('#inventory-pagination-top')).toHaveCount(0);
  await checkpoint(page, testInfo, 'page-size-and-search-edits-recovered-together-320');
  expect(errors).toEqual([]);
});

test('a slow pager response does not interrupt a newer keyboard interaction', async ({ page, request }) => {
  await healthy(request);
  await page.goto(`${hostURL}&page_size=10`);
  await connected(page);
  const search = page.getByLabel('Search', { exact: true });
  await page.evaluate(() => window.liveSocket.enableLatencySim(400));
  try {
    await page.locator('#inventory-pagination-top').getByRole('link', { name: 'Next', exact: true }).press('Enter');
    await search.focus();
    expect(new URL(page.url()).searchParams.get('page'), 'Search must receive focus before the delayed pager response').toBeNull();
    await expect(page).toHaveURL(/page=2/);
    await expect(hostGroup(page).locator('.target-group-range')).toContainText('11–20 of 120');
    await expect(search).toBeFocused();
    await search.fill('Host signal 059');
    await expect(page.locator('[id^="result-"]')).toHaveCount(2);
    await expect(search).toBeFocused();
    await expect(page.getByLabel('Results per page', { exact: true })).toHaveValue('10');
  } finally {
    await page.evaluate(() => window.liveSocket.disableLatencySim());
  }
});

test('problems sort first while a disconnected observer retains its own aged evidence and recovers', async ({ page, request }, testInfo) => {
  const errors = [];
  page.on('pageerror', (error) => errors.push(error.message));
  await mode(request, { backlog: 2, offline_installations: [], webhook: 'ok' });
  await healthy(request);
  const baseline = await allHostResults(request);
  const observerB = baseline.find((row) => row.runner_label === 'Inventory observer B').runner_id;
  const identities = baseline.map((row) => row.id).sort();

  await mode(request, { backlog: 12 });
  try {
    await expect.poll(async () => (await streams(request, { ...hostFilters, health: 'CRIT', freshness: 'fresh' })).total).toBe(2);
    await page.goto(hostURL);
    await connected(page);
    await expect(page.locator('[id^="result-"]').nth(0)).toContainText('Host signal 059');
    await expect(page.locator('[id^="result-"]').nth(1)).toContainText('Host signal 059');
    const failing = (await streams(request, { ...hostFilters, health: 'CRIT' })).items;
    expect(new Set(failing.map((row) => row.runner_id)).size).toBe(2);
    expect(new Set(failing.map((row) => row.assignment_id)).size).toBe(2);
    await page.locator('#inventory-tab-critical').click();
    await expect(page.locator('[id^="result-"]')).toHaveCount(2);
    await expect(hostGroup(page).locator('.target-group-size')).toContainText('2 of 120 results match');
    expect((await visibleIDs(page)).sort()).toEqual(failing.map((row) => `result-${row.id}`).sort());
    await page.setViewportSize({ width: 320, height: 740 });
    for (const result of failing) {
      await mobileEvidence(page, result, result.runner_label, 'Fresh measurement');
    }
    await checkpoint(page, testInfo, 'grouped-inventory-independent-problems-320');

    // Partition only one runner's controller transport. Its Python schedules
    // keep executing against the fixture; the other observer remains fresh.
    await mode(request, { offline_installations: [observerB], backlog: 2 });
    await expect.poll(async () => (await streams(request, { ...hostFilters, runner_id: observerB, freshness: 'stale' })).total,
      { timeout: 60_000, message: 'All 60 expected results remain present and age while observer B cannot upload' }).toBe(60);
    await expect.poll(async () => (await streams(request, { ...hostFilters, health: 'OK', freshness: 'fresh' })).total).toBe(60);
    await page.goto(hostURL);
    await connected(page);
    await expect(hostGroup(page).locator('.target-group-size')).toContainText('120 matching results');
    const retained = (await allHostResults(request, { runner_id: observerB })).find((row) => row.result_key === 'signal-059');
    expect(retained.current.health).toBe('CRIT');
    expect(retained.current.knowledge).toBe('stale');
    expect(Date.parse(retained.current.source_at)).toBeLessThan(Date.now() - 12_000);
    await expect(page.locator(`#result-${retained.id} .badge.crit`)).toContainText('Critical');
    await expect(page.locator(`#result-${retained.id} .badge.stale`)).toHaveText('Stale');
    await mobileEvidence(page, retained, 'Inventory observer B', 'Stale');
    await checkpoint(page, testInfo, 'stale-observer-and-original-age-visible-320');
    await page.locator('#inventory-more-filters > summary').click();
    await page.getByLabel('Measurement freshness', { exact: true }).selectOption('stale');
    await expect(hostGroup(page).locator('.target-group-size')).toContainText('60 of 120 results match');
    await expect(page.locator('[id^="result-"]').first()).toContainText('Host signal 059');
    await page.setViewportSize({ width: 1280, height: 900 });
    await checkpoint(page, testInfo, 'grouped-inventory-stale-observer-retains-health');

    const staleInvestigationURL = page.url();
    await hostGroup(page).getByRole('link', { name: /Show all observations/ }).click();
    await expect(page.locator('#checks-target-context')).toBeVisible();
    await page.getByLabel('Results per page', { exact: true }).selectOption('100');
    await expect(page.locator('.target-group')).toHaveCount(1);
    await expect(hostGroup(page).locator('.target-group-size')).toContainText('120 matching results');
    await expect(page.locator(`#result-${retained.id} .badge.crit`)).toContainText('Critical');
    await expect(page.locator(`#result-${retained.id} .badge.stale`)).toHaveText('Stale');
    // Fresh results from A are visible alongside, and never stand in for B's
    // retained Critical evidence. Compare the original evidence timestamp too.
    const expanded = await streams(request, { target_scope: new URL(page.url()).searchParams.get('target_scope'), page_size: 100 });
    expect(expanded.total).toBe(120);
    const expandedNext = await streams(request, { target_scope: new URL(page.url()).searchParams.get('target_scope'), page_size: 100, page: 2 });
    expanded.items.push(...expandedNext.items);
    expect(expanded.items).toHaveLength(120);
    expect(expanded.items.some((row) => row.runner_id !== observerB && row.current.knowledge === 'fresh')).toBe(true);
    const stillRetained = expanded.items.find((row) => row.id === retained.id);
    expect(stillRetained.current.source_at).toBe(retained.current.source_at);
    expect(stillRetained.current.health).toBe('CRIT');
    await checkpoint(page, testInfo, 'exact-target-independent-stale-and-healthy-observations');
    await page.getByLabel('Search', { exact: true }).fill('Host signal 059');
    await expect(page.locator('[id^="result-"]')).toHaveCount(2);
    await page.setViewportSize({ width: 320, height: 740 });
    const freshPeer = expanded.items.find((row) => row.result_key === retained.result_key && row.runner_id !== observerB);
    expect(freshPeer.current.health).toBe('OK');
    await mobileEvidence(page, retained, 'Inventory observer B', 'Stale');
    await mobileEvidence(page, freshPeer, freshPeer.runner_label, 'Fresh measurement');
    await checkpoint(page, testInfo, 'same-result-independent-stale-and-fresh-320');
    await page.locator('#checks-investigation-return').click();
    await expect(page).toHaveURL(staleInvestigationURL);

    await mode(request, { offline_installations: [] });
    await healthy(request);
    await expect(page.locator('#check-inventory')).toContainText('No matching results');
    expect((await allHostResults(request)).map((row) => row.id).sort()).toEqual(identities);
    await page.goto(hostURL);
    await connected(page);
    await expect(hostGroup(page).locator('.target-group-size')).toContainText('120 matching results');
    await expect(page.locator(`#result-${retained.id} .badge.crit`)).toHaveCount(0);
    expect((await allHostResults(request)).every((row) => row.current.health === 'OK' && row.current.knowledge === 'fresh')).toBe(true);
    await checkpoint(page, testInfo, 'grouped-inventory-reconnected-measured-recovery');
    expect(errors).toEqual([]);
  } finally {
    await mode(request, { backlog: 2, offline_installations: [] });
  }
});
