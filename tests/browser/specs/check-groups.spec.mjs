// Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
// SPDX-License-Identifier: Apache-2.0
import { test, expect } from '@playwright/test';
import { readFile, writeFile } from 'node:fs/promises';
import { reviewedMaintenance, checkpoint, connected, mode, snapshot, streams, reconnect } from '../support/helpers.mjs';

const phase = process.env.MONDEK_BROWSER_PHASE || 'initial';
const statePath = '/artifacts/check-groups-state.json';
const rows = (page) => page.locator('#preview-check-results > tbody > tr');
const bar = (page) => page.locator('[phx-hook="PreviewFilterPicker"]').first();

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

async function openGroups(page, query) {
  const existing = bar(page).locator('.preview-filter-chip > button[phx-click="filter_open"][phx-value-field="group"]');
  if (await existing.count()) await existing.click();
  else {
    await bar(page).getByRole('combobox').click();
    await bar(page).locator('[role="option"][phx-value-field="group"]').click();
  }
  await expect(bar(page)).toHaveAttribute('data-step', 'group');
  await bar(page).getByRole('combobox').fill(query);
}

async function chooseGroup(page, label) {
  await openGroups(page, label);
  const option = bar(page).locator('[role="option"][phx-value-key]').filter({hasText: new RegExp(`${label} ·`)});
  await expect(option).toHaveCount(1);
  const key = await option.getAttribute('phx-value-key');
  await option.click();
  await expect(bar(page)).not.toHaveAttribute('data-step', 'group');
  await bar(page).getByRole('combobox').press('Escape');
  await expect(page).toHaveURL((url) => url.searchParams.get('group') === key);
  return key;
}

test('group chips search the complete real catalogue while keeping the selected result scope stable', async ({ page, request }, testInfo) => {
  test.skip(phase !== 'initial', 'The publication phase is tested separately');
  const errors = [];
  page.on('pageerror', (error) => errors.push(error.message));
  await mode(request, { backlog: 2, offline_installations: [], webhook: 'ok' });
  await measured(request);
  const original = await allResults(request);
  expect(original).toHaveLength(140);
  expect(new Set(original.map((row) => row.target.key)).size).toBe(125);
  expect(new Set(original.map((row) => row.runner_id)).size).toBe(2);
  await page.goto('/checks');
  await connected(page);
  const selected = await chooseGroup(page, 'Node');
  await expect(rows(page)).toHaveCount(30);
  const visible = await rows(page).evaluateAll((items) => items.map((row) => row.id).sort());
  await checkpoint(page, testInfo, 'node-group-compact-result-table-desktop');

  // Suggestions search the whole catalogue, not only the first bounded20.
  await openGroups(page, '');
  expect(await bar(page).locator('[role="option"][phx-value-key]').count()).toBeLessThanOrEqual(20);
  await bar(page).getByRole('combobox').fill('Site 104');
  const unloaded = bar(page).locator('[role="option"][phx-value-key]').filter({hasText: 'Site 104'});
  await expect(unloaded).toHaveCount(1);
  expect(await rows(page).evaluateAll((items) => items.map((row) => row.id).sort())).toEqual(visible);
  expect(new URL(page.url()).searchParams.get('group')).toBe(selected);
  expect(new URL(page.url()).searchParams.get('search')).toBeNull();
  await unloaded.press('Enter');
  await bar(page).getByRole('combobox').press('Escape');
  await expect(rows(page)).toHaveCount(1);
  await expect(rows(page).first()).toContainText('Resource 104');
  const selectedURL = page.url();
  await reconnect(page);
  await page.reload();
  await connected(page);
  await expect(page).toHaveURL(selectedURL);
  await expect(rows(page)).toHaveCount(1);
  expect(await chooseGroup(page, 'Node')).toBe(selected);
  await page.setViewportSize({ width: 320, height: 740 });
  for (const label of ['Container 000', 'Groups observer A', 'Groups observer B']) {
    await expect(page.locator('#preview-check-results')).toContainText(label);
  }
  await checkpoint(page, testInfo, 'group-chip-and-independent-results-320');

  // Real source regrouping must preserve prior monitoring and operator controls.
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
  await page.goto(`/incidents/health/${incident.id}/full`);
  await connected(page);
  await page.locator('#preview-incident-ack-form textarea[name=note]').fill('Retain acknowledgement through group rename');
  await page.locator('#preview-incident-ack-form').getByRole('button', { name: 'Save acknowledgement', exact: true }).click();
  await expect(page.getByRole('table', {name: 'Active acknowledgement', exact: true})).toContainText('Retain acknowledgement through group rename');
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

test('real source regrouping preserves stable group identity result history incidents and controls', async ({ page, request }, testInfo) => {
  test.skip(phase !== 'renamed', 'Requires the actual runner metadata publication');
  const before = JSON.parse(await readFile(statePath, 'utf8'));
  await measured(request);
  await page.goto('/checks');
  await connected(page);
  expect(await chooseGroup(page, 'Node services')).toBe(before.selected);
  await expect(page.getByRole('navigation', {name: 'Check results', exact: true})).toContainText('31');
  await expect(rows(page)).toHaveCount(30);
  const moved = before.streams.find((row) => row.target.kind === 'deadline' && row.target.key === 'deadline:000');
  expect(moved, 'The known deadline result must move into the renamed Node group').toBeTruthy();
  const firstNodePage = await rows(page).evaluateAll((items) => items.map((row) => row.id));
  const resultPages = page.getByRole('navigation', {name: 'Check results', exact: true});
  await resultPages.getByRole('link', {name: 'Next', exact: true}).click();
  await expect(resultPages.locator('[aria-current=page]')).toHaveText('2');
  await expect(rows(page)).toHaveCount(1);
  await expect(page.locator(`#result-row-${moved.id}`)).toBeVisible();
  const completeNodeGroup = [...firstNodePage, ...await rows(page).evaluateAll((items) => items.map((row) => row.id))];
  expect(new Set(completeNodeGroup).size).toBe(31);
  const after = await allResults(request);
  const movedResult = after.find((row) => row.id === moved.id);
  expect(movedResult.result_key).toBe('deadline-000');
  expect(movedResult.check_group).toMatchObject({key: 'node', label: 'Node services'});
  expect(after.map((row) => ({ id: row.id, assignment_id: row.assignment_id, target: row.target, runner_id: row.runner_id })).sort((a, b) => a.id.localeCompare(b.id)))
    .toEqual(before.streams.sort((a, b) => a.id.localeCompare(b.id)));
  const state = await snapshot(request);
  expect(state.incidents.filter((row) => row.status === 'open').map((row) => row.id).sort()).toEqual(before.incidents);
  expect(state.incidents.find((row) => row.id === before.acknowledged).acknowledgement_mode).toBe('until_incident_ends');
  for (const control of before.controls) expect(state.controls.find((row) => row.id === control.id)).toEqual(control);
  await checkpoint(page, testInfo, 'renamed-group-stable-measurements-and-controls');
  await chooseGroup(page, 'Miscellaneous');
  await expect(rows(page)).toHaveCount(4);
  await expect(page.locator(`#result-row-${moved.id}`)).toHaveCount(0);
  await page.setViewportSize({ width: 320, height: 740 });
  await reconnect(page);
  await checkpoint(page, testInfo, 'moved-result-leaves-old-group-after-reconnect-320');
});
