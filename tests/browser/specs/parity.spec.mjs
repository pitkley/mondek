// Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
// SPDX-License-Identifier: Apache-2.0
import { test, expect } from '@playwright/test';
import { checkpoint, connected, mode, snapshot, streams, streamMeasured, setFilter, searchFilters, reconnect } from '../support/helpers.mjs';

const resultRows = (page) => page.locator('#preview-check-results > tbody > tr');
const resultPages = (page) => page.getByRole('navigation', {name: 'Check results', exact: true});
const exportURL = '/checks?search=exports%2Fexport-&environment=capacity-test';
const bar = (page) => page.locator('[phx-hook="PreviewFilterPicker"]').first();

async function ready(request) {
  await expect.poll(async () => (await streams(request, {freshness: 'fresh'})).total,
    {timeout: 240_000, message: 'All 511 results must be measured by the installed consumers'}).toBe(511);
}

const resultIDs = (page) => resultRows(page).evaluateAll((rows) => rows.map((row) => row.id));

test('511 actual results remain searchable and 500 export results stay complete across bounded pages', async ({page, request}, testInfo) => {
  const errors = [];
  page.on('pageerror', (error) => errors.push(error.message));
  await ready(request);
  await page.goto('/checks');
  await expect(resultRows(page)).toHaveCount(30);
  await expect(resultPages(page)).toContainText('511');
  await checkpoint(page, testInfo, 'large-result-inventory');
  await page.setViewportSize({width: 320, height: 740});
  await checkpoint(page, testInfo, 'compact-independent-evidence-320');
  const bounds = await resultRows(page).locator('td').evaluateAll((cells) => cells.map((cell) => {
    const rect = cell.getBoundingClientRect();
    return {left: rect.left, right: rect.right, width: cell.clientWidth, contents: cell.scrollWidth};
  }));
  expect(bounds.every((cell) => cell.left >= 0 && cell.right <= 321 && cell.contents <= cell.width + 1)).toBeTruthy();
  await page.setViewportSize({width: 1440, height: 1000});
  await page.goto(`${exportURL}&health=OK&freshness=fresh`);
  await connected(page);
  await expect(resultPages(page)).toContainText('500');
  const all = [];
  for (let number = 1; number <= 17; number += 1) {
    await expect(resultRows(page)).toHaveCount(number === 17 ? 20 : 30);
    await expect(resultPages(page).locator('[aria-current=page]')).toHaveText(String(number));
    all.push(...await resultIDs(page));
    if (number < 17) await resultPages(page).getByRole('link', {name: 'Next', exact: true}).click();
  }
  expect(all).toHaveLength(500);
  expect(new Set(all).size).toBe(500);
  await searchFilters(page, 'exports/export-0499.txt');
  await setFilter(page, 'health', null);
  await setFilter(page, 'freshness', null);
  await expect(resultRows(page)).toHaveCount(1);
  await expect(resultPages(page)).toHaveCount(0);
  await page.reload();
  await connected(page);
  await expect(bar(page)).toHaveAttribute('data-search', 'exports/export-0499.txt');
  await page.setViewportSize({width: 320, height: 740});
  await checkpoint(page, testInfo, 'filtered-large-inventory-320');
  await resultRows(page).first().getByRole('link').first().click();
  await expect(page.locator('#overview-panel')).toContainText('exports/export-0499.txt');
  await checkpoint(page, testInfo, 'selected-large-result-320');
  await page.locator('#overview-panel').getByRole('link', {name: 'View check configuration', exact: true}).click();
  await expect(page.locator('#source-owned-parameters')).toBeVisible();
  await expect(page.getByRole('button', {name: 'Review settings for this check', exact: true})).toHaveCount(0);
  await expect(page.locator('#configuration-results > table > tbody > tr')).toHaveCount(10);
  await checkpoint(page, testInfo, 'source-owned-shared-configuration-320');
  await page.setViewportSize({width: 1440, height: 1000});
  await page.goto('/runners');
  const runners = (await snapshot(request)).runners;
  for (const label of ['Dedicated monitoring', 'Node A', 'Node B']) {
    const runner = runners.find((row) => row.label === label);
    expect(runner, `The installed ${label} runner must retain its own identity`).toBeTruthy();
    const row = page.locator(`#runner-row-${runner.id}`);
    await expect(row.getByRole('link', {name: `${label} · ${runner.id}`, exact: true})).toBeVisible();
    await expect(row.locator('.fleet-identity')).toHaveAttribute('title', runner.id);
  }
  await checkpoint(page, testInfo, 'all-runner-connections');
  const nodeA = (await streams(request, {search: 'node:node-a/export'})).items[0];
  await page.goto('/checks');
  await setFilter(page, 'runner_id', nodeA.runner_id);
  await expect(resultRows(page)).toHaveCount(3);
  await checkpoint(page, testInfo, 'node-local-result-filter');
  expect(errors).toEqual([]);
});

test('target suggestions search beyond their first twenty values and retain exact selection through reconnect', async ({page, request}, testInfo) => {
  await ready(request);
  const exports = await streams(request, {search: 'exports/export-0499.txt', environment: 'capacity-test'});
  expect(exports.total).toBe(1);
  const selected = exports.items[0];
  await page.goto(exportURL);
  await connected(page);
  const input = bar(page).getByRole('combobox');
  await input.click();
  await bar(page).locator('[role=option][phx-value-field=target]').click();
  expect(await bar(page).locator('[role=option][phx-value-key]').count()).toBeLessThanOrEqual(20);
  await input.fill('exports/export-0499.txt');
  const option = bar(page).locator('[role=option][phx-value-key]').filter({hasText: 'exports/export-0499.txt'});
  await expect(option).toHaveCount(1);
  await option.click();
  await input.press('Escape');
  await expect(resultRows(page)).toHaveCount(1);
  const selectedURL = page.url();
  expect(new URL(selectedURL).searchParams.get('target_key')).toBe(selected.target.key);
  expect(new URL(selectedURL).searchParams.get('target_kind')).toBe(selected.target.kind);
  await reconnect(page);
  await page.reload();
  await connected(page);
  await expect(page).toHaveURL(selectedURL);
  await expect(resultRows(page).first()).toHaveAttribute('id', `result-row-${selected.id}`);
  await resultRows(page).first().getByRole('link').first().click();
  await expect(page.locator('#overview-panel')).toContainText('exports/export-0499.txt');
  await page.locator('#overview-panel [data-overview-close]').click();
  await expect(page.locator('#overview-panel')).toHaveCount(0);
  await expect(resultRows(page)).toHaveCount(1);
  await page.setViewportSize({width: 320, height: 740});
  await checkpoint(page, testInfo, 'exact-target-chip-reconnected-320');
  await setFilter(page, 'target', null);
  await expect(resultRows(page)).toHaveCount(30);
  await expect(resultPages(page)).toContainText('500');
});

test('one actual datasource execution retains independent result incidents and original source times', async ({page, request}, testInfo) => {
  await mode(request, {ready: false, secondary_ready: true});
  try {
    await streamMeasured(request, 'service:primary', 'CRIT');
    await streamMeasured(request, 'service:secondary', 'OK');
    const items = (await streams(request, {search: 'service:'})).items;
    const primary = items.find((item) => item.target.key === 'service:primary');
    const secondary = items.find((item) => item.target.key === 'service:secondary');
    expect(primary.assignment_id).toBe(secondary.assignment_id);
    expect(primary.current.observation_id).toBe(secondary.current.observation_id);
    expect(primary.current.source_at).toBeTruthy();
    expect(secondary.current.source_at).toBeTruthy();
    await page.goto(`/results/${primary.id}/full`);
    await expect(page.locator('#preview-result-incidents')).toBeVisible();
    await checkpoint(page, testInfo, 'primary-datasource-failure');
    await page.locator('#preview-result-incidents').getByRole('link', {name: 'View incident', exact: true}).click();
    await expect(page.locator('#overview-panel')).toContainText('Critical');
    const incidentURL = page.url();
    await page.goto(`/results/${secondary.id}/full`);
    await connected(page);
    await expect(page.locator('#preview-result-incidents')).toHaveCount(0);
    await expect(page.locator('#full-result-heading')).toContainText('Secondary service');
    await checkpoint(page, testInfo, 'healthy-sibling-independent-result');
    await mode(request, {ready: true});
    await streamMeasured(request, 'service:primary');
    await page.goto(incidentURL);
    await expect(page.locator('#overview-panel #preview-history')).toContainText('Measured recovery');
    await page.setViewportSize({width: 390, height: 844});
    await checkpoint(page, testInfo, 'independent-datasource-recovery-390');
  } finally {
    await mode(request, {ready: true, secondary_ready: true});
  }
});

async function maintenanceFormsFit(page) {
  for (const selector of ['#maintenance-selection-form', '#maintenance-form']) {
    if (!(await page.locator(selector).isVisible())) continue;
    const bounds = await page.locator(selector).evaluate((form) => {
      const outer = form.getBoundingClientRect();
      return {width: form.clientWidth, scroll: form.scrollWidth,
        outside: [...form.querySelectorAll('input, select, textarea, button, label')].flatMap((element) => {
          const rect = element.getBoundingClientRect();
          return rect.width && (rect.left < outer.left - 1 || rect.right > outer.right + 1) ? [element.id || element.tagName] : [];
        })};
    });
    expect(bounds.outside, `${selector} controls fit their panel`).toEqual([]);
    expect(bounds.scroll).toBeLessThanOrEqual(bounds.width + 1);
  }
}

const choiceRows = (page) => page.locator('#maintenance-selection-form > table > tbody:not(.preview-maintenance-pinned) > tr.preview-maintenance-choice-row');
const choiceCheckboxes = (page) => choiceRows(page).locator('input[type=checkbox][name="selected_keys[]"]');

async function nextReviewPage(pages) {
  const marker = pages.locator('[aria-current=page]');
  const numbered = await marker.count() > 0;
  const current = numbered ? Number(await marker.textContent()) : Number((await pages.textContent()).match(/Page (\d+) of/)[1]);
  await pages.getByRole('button', {name: 'Next', exact: true}).click();
  if (numbered) await expect(marker).toHaveText(String(current + 1));
  else await expect(pages).toContainText(`Page ${current + 1} of`);
}

test('one maintenance window retains a reconnect-safe selection of 500 real export targets', async ({page, request}, testInfo) => {
  const errors = [];
  page.on('pageerror', (error) => errors.push(error.message));
  await ready(request);
  await page.goto('/maintenance/new');
  await connected(page);
  const picker = {id: 'maintenance-choice-search'};
  await setFilter(page, 'kind', 'target', picker);
  await setFilter(page, 'source_id', 'export-capacity', picker);
  await setFilter(page, 'environment', 'capacity-test', picker);
  const pages = page.getByRole('navigation', {name: 'Maintenance selection pages', exact: true});
  await expect(page.locator('#maintenance-select-matching')).toHaveText('Select all 500 matches');
  await expect(choiceRows(page)).toHaveCount(25);
  const firstPage = await choiceCheckboxes(page).evaluateAll((inputs) => inputs.map((input) => input.value));
  expect(new Set(firstPage).size).toBe(25);
  await page.locator('#maintenance-select-page').click();
  await expect(page.locator('#maintenance-selected-count')).toHaveText('25 selected');
  await nextReviewPage(pages);
  await expect(choiceCheckboxes(page)).toHaveCount(25);
  const secondPage = await choiceCheckboxes(page).evaluateAll((inputs) => inputs.map((input) => input.value));
  expect(new Set([...firstPage, ...secondPage]).size).toBe(50);
  expect(secondPage.filter((key) => firstPage.includes(key))).toEqual([]);
  await choiceCheckboxes(page).first().check();
  await expect(page.locator('#maintenance-selected-count')).toHaveText('26 selected');
  await expect(page.locator('.preview-maintenance-pinned input[type=checkbox]:checked')).toHaveCount(25);
  await page.locator('#maintenance-name').fill('Export fleet maintenance');
  await page.locator('#maintenance-reason').fill('One shared window for the explicitly selected export files');
  await searchFilters(page, 'exports/export-0499.txt', picker);
  await expect(choiceRows(page)).toHaveCount(1);
  await expect(page.locator('#maintenance-selected-count')).toHaveText('26 selected');
  await page.locator('#maintenance-choice-search').getByRole('button', {name: 'Clear search text', exact: true}).click();
  await page.locator('#maintenance-select-matching').click();
  await expect(page.locator('#maintenance-selected-count')).toHaveText('500 selected');
  await nextReviewPage(pages);
  const encoded = await page.locator('#maintenance-form input[name="_proposal"]').inputValue();
  expect(Buffer.byteLength(encoded)).toBeGreaterThan(16_000);
  expect(JSON.parse(encoded).selections).toHaveLength(500);
  await page.setViewportSize({width: 390, height: 844});
  await maintenanceFormsFit(page);
  await checkpoint(page, testInfo, 'five-hundred-selected-targets-390');

  // Unsent checkbox and editor changes recover together from the actual DOM.
  const offlineChoice = choiceCheckboxes(page).first();
  const removedKey = await offlineChoice.inputValue();
  const removed = JSON.parse(Buffer.from(removedKey, 'base64url').toString());
  await page.evaluate(() => window.liveSocket.disconnect());
  await expect(page.locator('[data-phx-main]')).not.toHaveClass(/phx-connected/);
  await offlineChoice.uncheck();
  await page.locator('#maintenance-name').fill('Recovered export fleet window');
  await page.locator('#maintenance-reason').fill('Reason and unchecked target were not sent before reconnect');
  await page.evaluate(() => window.liveSocket.connect());
  await connected(page);
  await expect(page.locator('#maintenance-selected-count')).toHaveText('499 selected');
  await expect(page.locator('#maintenance-name')).toHaveValue('Recovered export fleet window');
  await expect(page.locator('#maintenance-reason')).toHaveValue('Reason and unchecked target were not sent before reconnect');
  const recovered = JSON.parse(await page.locator('#maintenance-form input[name="_proposal"]').inputValue());
  expect(recovered.selections).toHaveLength(499);
  expect(recovered.selections.some((item) => item.target_key === removed.target_key)).toBe(false);
  await choiceCheckboxes(page).nth(1).uncheck();
  await expect(page.locator('#maintenance-selected-count')).toHaveText('498 selected');
  await page.locator('#maintenance-clear-selection').click();
  await expect(page.locator('#maintenance-selected-count')).toHaveText('0 selected');
  await expect(page.locator('#maintenance-settings')).toBeVisible();
  await expect(page.locator('#maintenance-preview-button')).toBeDisabled();
  await page.locator('#maintenance-select-matching').click();
  await expect(page.locator('#maintenance-selected-count')).toHaveText('500 selected');
  await expect(page.locator('#maintenance-name')).toHaveValue('Recovered export fleet window');
  await page.locator('#maintenance-preview-button').click();
  await expect(page.locator('#maintenance-preview-summary')).toContainText('500 results across 50 scheduled checks');
  const inspector = page.locator('#maintenance-selection-details');
  await expect(inspector).not.toHaveAttribute('open');
  await inspector.locator(':scope > summary').click();
  await expect(page.locator('#maintenance-saved-selection li')).toHaveCount(25);
  await expect(page.locator('#maintenance-saved-selection li strong')).toHaveText(
    Array.from({length: 25}, (_, index) => `exports/export-${String(index).padStart(4, '0')}.txt`));
  const savedPages = page.getByRole('navigation', {name: 'Saved selection pages', exact: true});
  await nextReviewPage(savedPages);
  await expect(page.locator('#maintenance-saved-selection li strong').first()).toHaveText('exports/export-0025.txt');
  await expect(inspector).toHaveJSProperty('open', true);
  const matches = page.locator('#maintenance-preview-matches');
  await expect(matches).toHaveJSProperty('open', true);
  await nextReviewPage(page.getByRole('navigation', {name: 'Affected result pages', exact: true}));
  await expect(matches).toHaveJSProperty('open', true);
  await inspector.locator(':scope > summary').click();
  await matches.locator(':scope > summary').click();
  await page.setViewportSize({width: 320, height: 740});
  expect((await inspector.boundingBox()).height).toBeLessThan(140);
  expect((await matches.boundingBox()).height).toBeLessThan(140);
  await maintenanceFormsFit(page);
  await checkpoint(page, testInfo, 'five-hundred-target-union-preview-320');
  await page.locator('#maintenance-save').click();
  await expect(page).toHaveURL(/\/maintenance\/[0-9a-f-]{36}(?:\/full)?(?:\?.*)?$/);
  const id = new URL(page.url()).pathname.match(/\/maintenance\/([0-9a-f-]{36})/)[1];
  const response = await request.get(`/api/v1/maintenance/${id}`);
  expect(response.ok(), await response.text()).toBe(true);
  const saved = await response.json();
  expect(saved.scope).toBe('selection');
  expect(saved.selections).toHaveLength(500);
  expect(saved.match_count).toBe(500);
  expect(new Set(saved.selections.map((item) => `${item.source_id}/${item.environment}/${item.target_kind}/${item.target_key}`)).size).toBe(500);
  await expect(page.locator('#maintenance-saved')).toContainText('500');
  await expect(page.locator('#maintenance-selection-form')).toHaveCount(0);
  await expect(inspector).not.toHaveAttribute('open');
  await inspector.locator(':scope > summary').click();
  await nextReviewPage(savedPages);
  await expect(page.locator('#maintenance-saved-selection li')).toHaveCount(25);
  await reconnect(page);
  await expect(inspector).toHaveJSProperty('open', true);
  await expect(page.locator('#maintenance-saved-selection li').first()).toBeVisible();
  await inspector.locator(':scope > summary').click();
  await page.setViewportSize({width: 1280, height: 800});
  await checkpoint(page, testInfo, 'saved-five-hundred-target-window');
  await page.locator('#maintenance-cancel').click();
  await page.locator('#maintenance-cancel-reason').fill('Shared export maintenance completed');
  await page.locator('#maintenance-confirm-cancel').click();
  await expect(page.locator('#maintenance-saved')).toContainText('Ended early');
  await expect(page.locator('#maintenance-history')).toContainText('Shared export maintenance completed');
  await expect(page.locator('#maintenance-form')).toHaveCount(0);
  expect(errors).toEqual([]);
});

test('500 actual declared scopes retain complete counts numbered paging and applied chip filters', async ({page, request}, testInfo) => {
  await expect.poll(async () => {
    const response = await request.get('/api/v1/coverage?source_id=export-capacity');
    expect(response.ok()).toBeTruthy();
    return (await response.json()).summary.observed;
  }, {timeout: 240_000}).toBe(500);
  await page.goto('/coverage?source_id=export-capacity');
  await connected(page);
  const declarations = page.getByRole('table', {name: 'Declared results', exact: true}).locator(':scope > tbody > tr');
  const pages = page.getByRole('navigation', {name: 'Declared result pages', exact: true});
  await expect(declarations).toHaveCount(25);
  await expect(pages).toContainText('500');
  const first = await declarations.locator('[data-overview-open]').evaluateAll((links) => links.map((link) => link.id));
  await pages.getByRole('link', {name: 'Next', exact: true}).press('Enter');
  await expect(pages.locator('[aria-current=page]')).toHaveText('2');
  const second = await declarations.locator('[data-overview-open]').evaluateAll((links) => links.map((link) => link.id));
  expect(new Set([...first, ...second]).size).toBe(50);
  await checkpoint(page, testInfo, 'five-hundred-declared-scopes');
  await declarations.first().getByRole('link').first().click();
  await expect(page.locator('#overview-panel #preview-coverage-facts')).toBeVisible();
  await page.locator('#overview-panel [data-overview-close]').click();
  await expect(page.locator('#overview-panel')).toHaveCount(0);
  await expect(pages.locator('[aria-current=page]')).toHaveText('2');
  const pageTwo = page.url();
  await reconnect(page);
  await page.reload();
  await connected(page);
  await expect(page).toHaveURL(pageTwo);
  await expect(page.locator('#overview-panel')).toHaveCount(0);
  await setFilter(page, 'environment', 'capacity-test');
  await searchFilters(page, 'export');
  await expect(pages.locator('[aria-current=page]')).toHaveText('1');
  await expect(declarations).toHaveCount(25);
  await expect(pages).toContainText('500');
  await reconnect(page);
  await expect(bar(page)).toHaveAttribute('data-search', 'export');
  await expect(bar(page).getByRole('button', {name: 'Edit Environment filter: Capacity test', exact: true})).toBeVisible();
  await expect(page).toHaveURL(url => url.searchParams.get('environment') === 'capacity-test');
  await page.setViewportSize({width: 320, height: 760});
  await checkpoint(page, testInfo, 'declared-scope-chips-reconnected-320');
});
