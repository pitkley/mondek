// Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
// SPDX-License-Identifier: Apache-2.0
import { test, expect } from '@playwright/test';
import { checkpoint, connected, mode, streams, setFilter, searchFilters, reconnect, expectInvestigationReturn } from '../support/helpers.mjs';

const hostFilters = { search: 'host:inventory-shared', environment: 'inventory-test' };
const hostURL = `/checks?${new URLSearchParams(hostFilters)}`;
const rows = (page) => page.locator('#preview-check-results > tbody > tr');
const pager = (page) => page.getByRole('navigation', { name: 'Check results', exact: true });
const filterBar = (page) => page.locator('[phx-hook="PreviewFilterPicker"]').first();

async function allHostResults(request, filters = {}) {
  const first = await streams(request, { ...hostFilters, ...filters, page_size: 100 });
  const items = [...first.items];
  for (let page = 2; items.length < first.total; page += 1) {
    items.push(...(await streams(request, { ...hostFilters, ...filters, page_size: 100, page })).items);
  }
  return items;
}

async function healthy(request) {
  await expect.poll(async () => (await streams(request, { freshness: 'fresh', health: 'OK' })).total,
    { timeout: 120_000, message: 'Both actual observers must measure all 122 declared results' }).toBe(122);
}

const visibleIDs = (page) => rows(page).evaluateAll((items) => items.map((row) => row.id));

async function mobileEvidence(page, result, collection) {
  const row = page.locator(`#result-row-${result.id}`);
  await expect(row.locator('.preview-result-context')).toContainText(result.runner_label);
  await expect(row).toContainText(collection);
  if (collection === 'Overdue') await expect(row.locator('time')).toHaveAttribute('datetime', result.current.source_at);
  else await expect(row.locator('time')).toHaveAttribute('datetime', /^\d{4}-\d{2}-\d{2}T/);
  const cells = await row.locator('td').evaluateAll((items) => items.map((cell) => {
    const bounds = cell.getBoundingClientRect();
    return { left: bounds.left, right: bounds.right, overflow: cell.scrollWidth - cell.clientWidth,
      viewport: document.documentElement.clientWidth };
  }));
  for (const cell of cells) {
    expect(cell.left).toBeGreaterThanOrEqual(0);
    expect(cell.right).toBeLessThanOrEqual(cell.viewport + 1);
    expect(cell.overflow, 'Observer, source time and finding fit their cell').toBeLessThanOrEqual(1);
  }
}

test('chips compose health, target and text search and retain their scope across reload and reconnect', async ({ page, request }, testInfo) => {
  const errors = [];
  page.on('pageerror', (error) => errors.push(error.message));
  await mode(request, { backlog: 2, offline_installations: [], webhook: 'ok' });
  await healthy(request);
  await page.goto(hostURL);
  await connected(page);
  await expect(rows(page)).toHaveCount(30);
  await expect(pager(page)).toContainText('120');
  const first = await visibleIDs(page);
  await pager(page).getByRole('link', { name: 'Next', exact: true }).press('Enter');
  await expect(pager(page).locator('[aria-current=page]')).toHaveText('2');
  expect((await visibleIDs(page)).filter((id) => first.includes(id))).toEqual([]);
  await page.setViewportSize({ width: 390, height: 844 });
  await checkpoint(page, testInfo, 'exact-scope-second-page-390');
  await mode(request, { backlog: 12 });
  try {
    await expect.poll(async () => (await streams(request, { ...hostFilters, health: 'CRIT', freshness: 'fresh' })).total).toBe(2);
    await setFilter(page, 'health', 'CRIT');
    await expect(rows(page)).toHaveCount(2);
    expect(new URL(page.url()).searchParams.get('page')).toBeNull();
    await expect(filterBar(page)).toContainText('Critical');
    await searchFilters(page, 'No such result');
    await expect(rows(page)).toHaveCount(0);
    await expect(page.getByText('No check results match these filters.', { exact: false })).toBeVisible();
    await filterBar(page).getByRole('link', { name: 'Clear search text', exact: true }).click();
    await expect(rows(page)).toHaveCount(2);
    await expect(filterBar(page)).toContainText('Critical');
    await searchFilters(page, 'Host signal 059');
    await expect(rows(page)).toHaveCount(2);
    const remembered = page.url();
    const ids = await visibleIDs(page);
    await page.reload();
    await connected(page);
    await reconnect(page);
    await expect(page).toHaveURL(remembered);
    expect(await visibleIDs(page)).toEqual(ids);
    await expect(filterBar(page)).toHaveAttribute('data-search', 'Host signal 059');
    await page.setViewportSize({ width: 320, height: 740 });
    await checkpoint(page, testInfo, 'composed-chips-retained-after-reconnect-320');
    await setFilter(page, 'health', null);
    await expect(rows(page)).toHaveCount(2);
    expect(errors).toEqual([]);
  } finally {
    await mode(request, { backlog: 2, offline_installations: [] });
  }
});

test('all 120 shared-target results remain reachable across bounded pages and exact observer filters', async ({ page, request }, testInfo) => {
  await mode(request, { backlog: 2, offline_installations: [], webhook: 'ok' });
  await healthy(request);
  const original = await allHostResults(request);
  expect(original).toHaveLength(120);
  expect(new Set(original.map((row) => row.runner_id)).size).toBe(2);
  await page.goto(`${hostURL}&health=OK&freshness=fresh`);
  await connected(page);
  const seen = [];
  for (let number = 1; number <= 4; number += 1) {
    await expect(rows(page)).toHaveCount(30);
    await expect(pager(page).locator('[aria-current=page]')).toHaveText(String(number));
    seen.push(...await visibleIDs(page));
    if (number < 4) await pager(page).getByRole('link', { name: 'Next', exact: true }).click();
  }
  expect(new Set(seen).size).toBe(120);
  expect(seen.sort()).toEqual(original.map((row) => `result-row-${row.id}`).sort());
  const finalURL = page.url();
  await reconnect(page);
  await expect(page).toHaveURL(finalURL);
  await expect(pager(page).locator('[aria-current=page]')).toHaveText('4');
  await setFilter(page, 'runner_id', original[0].runner_id);
  await expect(pager(page)).toContainText('60');
  await expect(rows(page)).toHaveCount(30);
  await pager(page).getByRole('link', { name: 'Next', exact: true }).click();
  await expect(pager(page).locator('[aria-current=page]')).toHaveText('2');
  for (const id of await visibleIDs(page)) expect(original.find((row) => `result-row-${row.id}` === id).runner_id).toBe(original[0].runner_id);
  await page.setViewportSize({ width: 320, height: 740 });
  await checkpoint(page, testInfo, 'one-observer-exact-scope-second-page-320');
  await setFilter(page, 'runner_id', null);
  await setFilter(page, 'target', original[0].target.key, {kind: original[0].target.kind});
  await expect(pager(page)).toContainText('120');
  await expect(rows(page)).toHaveCount(30);
  await searchFilters(page, 'Fixture service');
  await expect(rows(page)).toHaveCount(0);
});

test('numbered pages, result panels and configuration retain the original filtered investigation', async ({ page, request }, testInfo) => {
  await healthy(request);
  await page.goto(`${hostURL}&page=2`);
  await connected(page);
  await expect(rows(page)).toHaveCount(30);
  const ids = await visibleIDs(page);
  const secondURL = page.url();
  await pager(page).getByRole('link', { name: 'Previous', exact: true }).click();
  await expect(pager(page).locator('[aria-current=page]')).toHaveText('1');
  await expect(page).toHaveURL(url => (url.searchParams.get('page') || '1') === '1');
  await page.goBack();
  await expect(page).toHaveURL(secondURL);
  expect(await visibleIDs(page)).toEqual(ids);
  await reconnect(page);
  await page.reload();
  await connected(page);
  expect(await visibleIDs(page)).toEqual(ids);
  await rows(page).first().getByRole('link').first().click();
  await expect(page.locator('#overview-panel')).toBeVisible();
  await expect(page).not.toHaveURL(secondURL);
  const detailURL = page.url();
  await page.locator('#overview-panel').getByRole('link', { name: 'View check configuration', exact: true }).click();
  await expect(page).toHaveURL(/\/configuration\/[0-9a-f-]+/);
  await page.getByRole('link', { name: /Back to result/, exact: false }).click();
  await expectInvestigationReturn(page, detailURL, `result:${ids[0].replace('result-row-', '')}`);
  await page.locator('#overview-panel [data-overview-close]').click();
  await expect(page.locator('#overview-panel')).toHaveCount(0);
  const returned = new URL(page.url());
  expect(returned.searchParams.get('page')).toBe('2');
  expect(returned.searchParams.get('search')).toBe(hostFilters.search);
  expect(await visibleIDs(page)).toEqual(ids);
  await page.setViewportSize({ width: 320, height: 740 });
  await checkpoint(page, testInfo, 'page-and-evidence-return-retained-320');
});

test('a delayed pager response preserves a newer keyboard interaction in the shared search box', async ({ page, request }) => {
  await healthy(request);
  await page.goto(hostURL);
  await connected(page);
  const input = filterBar(page).getByRole('combobox');
  await page.evaluate(() => window.liveSocket.enableLatencySim(400));
  try {
    await pager(page).getByRole('link', { name: 'Next', exact: true }).press('Enter');
    await input.focus();
    expect(new URL(page.url()).searchParams.get('page')).toBeNull();
    await expect(pager(page).locator('[aria-current=page]')).toHaveText('2');
    await expect(input).toBeFocused();
    await input.fill('Host signal 059');
    await input.press('Enter');
    await expect(rows(page)).toHaveCount(2);
    await expect(input).toBeFocused();
  } finally {
    await page.evaluate(() => window.liveSocket.disableLatencySim());
  }
});

test('priority preserves a disconnected observers original Critical evidence while its peer recovers', async ({ page, request }, testInfo) => {
  await mode(request, { backlog: 2, offline_installations: [], webhook: 'ok' });
  await healthy(request);
  const baseline = await allHostResults(request);
  const observerB = baseline.find((row) => row.runner_label === 'Inventory observer B').runner_id;
  await mode(request, { backlog: 12 });
  try {
    await expect.poll(async () => (await streams(request, { ...hostFilters, health: 'CRIT', freshness: 'fresh' })).total).toBe(2);
    await page.goto(hostURL);
    await expect(rows(page).nth(0)).toContainText('Host signal 059');
    await expect(rows(page).nth(1)).toContainText('Host signal 059');
    await setFilter(page, 'health', 'CRIT');
    const failing = (await streams(request, { ...hostFilters, health: 'CRIT' })).items;
    expect(new Set(failing.map((row) => row.assignment_id)).size).toBe(2);
    await expect(rows(page)).toHaveCount(2);
    await page.setViewportSize({ width: 320, height: 740 });
    for (const result of failing) await mobileEvidence(page, result, 'Fresh');
    await checkpoint(page, testInfo, 'independent-critical-observers-320');
    await mode(request, { offline_installations: [observerB], backlog: 2 });
    await expect.poll(async () => (await streams(request, { ...hostFilters, runner_id: observerB, freshness: 'stale' })).total,
      { timeout: 60_000 }).toBe(60);
    await expect.poll(async () => (await streams(request, { ...hostFilters, health: 'OK', freshness: 'fresh' })).total).toBe(60);
    const retained = (await allHostResults(request, { runner_id: observerB })).find((row) => row.result_key === 'signal-059');
    expect(retained.current.health).toBe('CRIT');
    expect(retained.current.knowledge).toBe('stale');
    expect(Date.parse(retained.current.source_at)).toBeLessThan(Date.now() - 12_000);
    await page.goto(hostURL);
    await setFilter(page, 'freshness', 'stale');
    await expect(pager(page)).toContainText('60');
    await mobileEvidence(page, retained, 'Overdue');
    await checkpoint(page, testInfo, 'retained-critical-original-source-time-320');
    await setFilter(page, 'freshness', null);
    await searchFilters(page, 'Host signal 059');
    await expect(rows(page)).toHaveCount(2);
    const peers = await allHostResults(request, { search: 'Host signal 059' });
    const freshPeer = peers.find((row) => row.runner_id !== observerB);
    expect(freshPeer.current.health).toBe('OK');
    expect(peers.find((row) => row.id === retained.id).current.source_at).toBe(retained.current.source_at);
    await mobileEvidence(page, retained, 'Overdue');
    await mobileEvidence(page, freshPeer, 'Fresh');
    await checkpoint(page, testInfo, 'same-target-stale-and-fresh-peers-320');
    await setFilter(page, 'freshness', 'stale');
    await mode(request, { offline_installations: [] });
    await healthy(request);
    await expect(rows(page)).toHaveCount(0);
    expect((await allHostResults(request)).map((row) => row.id).sort()).toEqual(baseline.map((row) => row.id).sort());
    expect((await allHostResults(request)).every((row) => row.current.health === 'OK' && row.current.knowledge === 'fresh')).toBe(true);
    await checkpoint(page, testInfo, 'fresh-recovery-same-identities-320');
  } finally {
    await mode(request, { backlog: 2, offline_installations: [] });
  }
});
