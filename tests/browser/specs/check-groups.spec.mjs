// Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
// SPDX-License-Identifier: Apache-2.0
import { test, expect } from '@playwright/test';
import { readFile, writeFile } from 'node:fs/promises';
import { reviewedMaintenance, checkpoint, connected, mode, snapshot, streams } from '../support/helpers.mjs';

const phase = process.env.MONDEK_BROWSER_PHASE || 'initial';
const statePath = '/artifacts/check-groups-state.json';
const options = (page) => page.locator('#inventory-target-options > button');
const group = (page, label) => options(page).filter({ hasText: label });

async function allResults(request) {
  const first = await streams(request, { page_size: 100 });
  const items = [...first.items];
  for (let page = 2; items.length < first.total; page += 1) {
    items.push(...(await streams(request, { page, page_size: 100 })).items);
  }
  return items;
}

async function measured(request) {
  await expect.poll(async () => (await streams(request, { freshness: 'fresh' })).total,
    { timeout: 180_000, message: 'Both installed runners must measure all 140 results' }).toBe(140);
}

async function reconnect(page) {
  await page.evaluate(() => window.liveSocket.disconnect());
  await expect(page.locator('[data-phx-main]')).not.toHaveClass(/phx-connected/);
  await page.evaluate(() => window.liveSocket.connect());
  await connected(page);
}

test('groups browse many precise targets with complete local search and progressive loading', async ({ page, request }, testInfo) => {
  test.skip(phase !== 'initial', 'The publication phase is tested separately');
  const errors = [];
  page.on('pageerror', (error) => errors.push(error.message));
  await mode(request, { backlog: 2, offline_installations: [], webhook: 'ok' });
  await measured(request);
  const original = await allResults(request);
  expect(original).toHaveLength(140);
  expect(new Set(original.map((row) => row.target.key)).size).toBe(125);
  expect(new Set(original.map((row) => row.runner_id)).size).toBe(2);

  await page.goto('/checks?view=targets');
  await connected(page);
  await expect(options(page)).toHaveCount(100);
  await group(page, 'Node').click();
  await expect(page.locator('[id^="result-"]')).toHaveCount(30);
  await expect(page).toHaveURL(/target=group-[a-f0-9]+/);
  const selected = new URL(page.url()).searchParams.get('target');
  const visible = await page.locator('[id^="result-"]').evaluateAll((rows) => rows.map((row) => row.id).sort());
  await checkpoint(page, testInfo, 'many-resources-in-node-desktop');

  // Search applies to the entire sidebar, including entries not yet loaded.
  // It must not rewrite the global query or the current result investigation.
  await page.locator('#inventory-group-search').fill('Site 104');
  await expect(options(page)).toHaveCount(1);
  await expect(options(page).first()).toContainText('Site 104');
  await expect(page.locator('[id^="result-"]')).toHaveCount(30);
  expect(new URL(page.url()).searchParams.get('target')).toBe(selected);
  expect(new URL(page.url()).searchParams.get('search')).toBeNull();
  await reconnect(page);
  await expect(page.locator('#inventory-group-search')).toHaveValue('Site 104');
  await expect(options(page)).toHaveCount(1);
  expect(await page.locator('[id^="result-"]').evaluateAll((rows) => rows.map((row) => row.id).sort())).toEqual(visible);
  await options(page).first().click();
  await expect(page.locator('[id^="result-"]')).toHaveCount(1);
  await expect(page.locator('[id^="result-"]').first()).toContainText('Resource 104');
  await page.locator('#inventory-group-search').fill('');
  await expect(options(page)).toHaveCount(100);
  const scroll = page.locator('#inventory-target-options');
  await scroll.evaluate((element) => { element.scrollTop = element.scrollHeight; });
  await expect(options(page)).toHaveCount(107);
  await expect(page.locator('#inventory-load-more-groups')).toHaveCount(0);
  expect(new URL(page.url()).searchParams.get('group_limit')).toBe('200');
  await reconnect(page);
  await expect(options(page)).toHaveCount(107);
  await expect(page.locator('[id^="result-"]')).toHaveCount(1);

  // Keyboard activation provides an explicit alternative to scrolling. Keep
  // focus from scrolling the button into view and triggering the auto-loader.
  const keyboardPage = await page.context().newPage();
  await keyboardPage.goto('/checks?view=targets');
  await connected(keyboardPage);
  await expect(options(keyboardPage)).toHaveCount(100);
  await keyboardPage.locator('#inventory-load-more-groups').evaluate((element) => element.focus({ preventScroll: true }));
  await keyboardPage.keyboard.press('Enter');
  await expect(options(keyboardPage)).toHaveCount(107);
  await keyboardPage.close();
  await group(page, 'Node').click();
  await page.setViewportSize({ width: 320, height: 740 });
  await checkpoint(page, testInfo, 'group-navigation-and-resource-evidence-320');
  for (const label of ['Container 000', 'Groups observer A', 'Groups observer B']) {
    await expect(page.locator('#check-inventory')).toContainText(label);
  }

  // Persistent controls and incidents are established before changing only
  // source-owned grouping metadata in the next installed-runner publication.
  const maintained = original.find((row) => row.result_key === 'deadline-000');
  await reviewedMaintenance(request, maintained.assignment_id, 7200, 'Preserve through navigation regrouping');
  await mode(request, { backlog: 12 });
  await expect.poll(async () => (await streams(request, { health: 'CRIT', freshness: 'fresh' })).total).toBe(2);
  let incidents;
  await expect.poll(async () => {
    incidents = (await snapshot(request)).incidents.filter((row) => row.status === 'open');
    return incidents.length;
  }).toBe(2);
  const incident = incidents[0];
  await page.goto(`/incidents/${incident.id}`);
  await connected(page);
  await page.locator('#ack-note').fill('Retain acknowledgement through group rename');
  await page.locator('#acknowledgement-form').getByRole('button', { name: 'Acknowledge', exact: true }).click();
  await expect(page.locator('#active-acknowledgement')).toContainText('Retain acknowledgement through group rename');
  const before = await snapshot(request);
  await writeFile(statePath, JSON.stringify({
    streams: original.map((row) => ({ id: row.id, assignment_id: row.assignment_id, target: row.target, runner_id: row.runner_id })),
    incidents: before.incidents.filter((row) => row.status === 'open').map((row) => row.id).sort(),
    acknowledged: incident.id,
    controls: before.controls,
    selected,
  }, null, 2));
  expect(errors).toEqual([]);
});

test('real source regrouping preserves resource history, incidents and controls', async ({ page, request }, testInfo) => {
  test.skip(phase !== 'renamed', 'Requires the real runner metadata publication');
  const before = JSON.parse(await readFile(statePath, 'utf8'));
  await measured(request);
  await page.goto('/checks?view=targets');
  await connected(page);
  await expect(group(page, 'Node services')).toBeVisible();
  await group(page, 'Node services').click();
  await expect.poll(() => new URL(page.url()).searchParams.get('target')).toBe(before.selected);
  await expect(page.locator('[id^="result-"]')).toHaveCount(31);
  await expect(page.locator('#check-inventory')).toContainText('Deadline 000');
  const after = await allResults(request);
  expect(after.map((row) => ({ id: row.id, assignment_id: row.assignment_id, target: row.target, runner_id: row.runner_id })).sort((a, b) => a.id.localeCompare(b.id)))
    .toEqual(before.streams.sort((a, b) => a.id.localeCompare(b.id)));
  const state = await snapshot(request);
  expect(state.incidents.filter((row) => row.status === 'open').map((row) => row.id).sort()).toEqual(before.incidents);
  expect(state.incidents.find((row) => row.id === before.acknowledged).acknowledgement_mode).toBe('until_incident_ends');
  for (const control of before.controls) expect(state.controls.find((row) => row.id === control.id)).toEqual(control);
  await checkpoint(page, testInfo, 'renamed-group-keeps-measurements-and-incidents');
  await group(page, 'Miscellaneous').click();
  await expect(page.locator('[id^="result-"]')).toHaveCount(4);
  await expect(page.locator('#check-inventory')).not.toContainText('Deadline 000');
  await page.setViewportSize({ width: 320, height: 740 });
  await reconnect(page);
  await checkpoint(page, testInfo, 'moved-resource-leaves-old-group-after-reconnect-320');
});
