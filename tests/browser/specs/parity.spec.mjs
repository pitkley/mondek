// Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
// SPDX-License-Identifier: Apache-2.0
import { test, expect } from '@playwright/test';
import { checkpoint, connected, keyboardFill, mode, streams, streamMeasured } from '../support/helpers.mjs';

test('hundreds of runner-provided results remain searchable and configuration stays with their source', async ({ page, request }, testInfo) => {
  const errors = [];
  page.on('pageerror', (error) => errors.push(error.message));
  await expect.poll(async () => (await streams(request, { freshness: 'fresh' })).total,
    { timeout: 240_000 }).toBe(511);
  await page.goto('/checks?view=list');
  await expect(page.locator('[id^="result-"]')).toHaveCount(50);
  await expect(page.locator('#inventory-pagination-top')).toContainText('511 matching');
  await expect(page.locator('.target-group')).toHaveCount(50);
  await checkpoint(page, testInfo, 'large-result-inventory');
  await page.setViewportSize({ width: 320, height: 740 });
  await page.getByLabel('Results per page', { exact: true }).selectOption('10');
  await expect(page.locator('[id^="result-"]')).toHaveCount(10);
  await expect(page.locator('.target-group')).toHaveCount(10);
  await checkpoint(page, testInfo, 'singleton-target-ten-results-320');
  const rowBounds = await page.locator('.checks-table-wrap').evaluateAll((tables) => tables.map((table) => {
    const rect = table.getBoundingClientRect();
    return { width: table.clientWidth, contents: table.scrollWidth, left: rect.left, right: rect.right, overflow: getComputedStyle(table).overflowX };
  }));
  expect(rowBounds).toHaveLength(10);
  expect(rowBounds.every((box) => box.left >= 0 && box.right <= 321 && box.overflow === 'auto')).toBeTruthy();
  expect(rowBounds.every((box) => box.contents <= box.width + 1),
    'Narrow evidence must fit without horizontal table scrolling').toBeTruthy();
  const cells = await page.locator('[id^="result-"] td').evaluateAll((items) => items.map((cell) => {
    const box = cell.getBoundingClientRect();
    return { left: box.left, right: box.right, width: cell.clientWidth, contents: cell.scrollWidth };
  }));
  expect(cells.every((cell) => cell.left >= 0 && cell.right <= 321 && cell.contents <= cell.width + 1)).toBeTruthy();
  await expect(page.locator('[id^="result-"] .target-result-observer')).toHaveCount(10);
  await expect(page.locator('[id^="result-"] time')).toHaveCount(10);
  await page.setViewportSize({ width: 1440, height: 1000 });
  await page.getByLabel('Results per page', { exact: true }).selectOption('50');
  await expect(page.locator('[id^="result-"]')).toHaveCount(50);
  // Live urgency may legitimately reorder rows while the accessibility and
  // mobile checkpoints run. Prove disjoint pages over the complete export
  // inventory with equal measured health and freshness, immediately adjacent
  // to navigation; a partial fresh scope is not sufficient evidence.
  await page.goto('/checks?view=list&search=exports%2Fexport-&environment=capacity-test&health=OK&freshness=fresh');
  await connected(page);
  await expect(page.locator('.checks-match-count')).toContainText('500 matching results');
  await expect(page.locator('[id^="result-"]')).toHaveCount(50);
  await expect(page.locator('.target-group h3')).toHaveText(
    Array.from({ length: 50 }, (_, index) => `exports/export-${String(index).padStart(4, '0')}.txt`),
  );
  const firstPage = await page.locator('[id^="result-"]').evaluateAll((rows) => rows.map((row) => row.id));
  await page.locator('#inventory-pagination-top').getByRole('link', { name: 'Next', exact: true }).click();
  await expect(page).toHaveURL(/page=2/);
  await expect(page.locator('#inventory-pagination-top')).toContainText('Page 2');
  await expect(page.locator('.checks-match-count')).toContainText('500 matching results');
  await expect(page.locator('.target-group h3')).toHaveText(
    Array.from({ length: 50 }, (_, index) => `exports/export-${String(index + 50).padStart(4, '0')}.txt`),
  );
  const secondPage = await page.locator('[id^="result-"]').evaluateAll((rows) => rows.map((row) => row.id));
  expect(secondPage.filter((id) => firstPage.includes(id))).toEqual([]);
  await expect(page.locator('#check-inventory')).toBeFocused();
  // Filters precede the newly focused list; reverse Tab reaches them directly.
  await keyboardFill(page, page.getByLabel('Search', { exact: true }), 'exports/export-0499.txt', { backward: true });
  await page.keyboard.press('Tab');
  // The remaining inspection journey includes retained and unavailable results.
  await page.getByLabel('Last measured health', { exact: true }).selectOption('');
  await page.getByLabel('Measurement freshness', { exact: true }).selectOption('');
  await expect(page.locator('[id^="result-"]')).toHaveCount(1);
  await expect(page.locator('.checks-match-count')).toContainText('1 matching');
  await expect(page.locator('#inventory-pagination-top')).toHaveCount(0);
  await page.reload();
  await expect(page.getByLabel('Search', { exact: true })).toHaveValue('exports/export-0499.txt');
  await page.setViewportSize({ width: 320, height: 740 });
  await checkpoint(page, testInfo, 'filtered-large-inventory-320');
  await page.locator('[id^="result-"]').getByRole('link').first().click();
  await expect(page).toHaveURL(/\/checks\/[0-9a-f-]+(?:\?|$)/);
  await expect(page.locator('.result-context > div').filter({ has: page.getByText('Target', { exact: true }) }).locator('dd'))
    .toHaveText('exports/export-0499.txt');
  await checkpoint(page, testInfo, 'selected-large-inventory-result-320');
  await page.getByRole('link', { name: 'Review configuration', exact: true }).click();
  await expect(page.locator('#source-owned-parameters')).toBeVisible();
  await expect(page.getByRole('button', { name: 'Review settings for this check', exact: true })).toHaveCount(0);
  await expect(page.locator('.result-links li')).toHaveCount(10);
  await checkpoint(page, testInfo, 'source-owned-shared-configuration-320');
  await page.setViewportSize({ width: 1440, height: 1000 });
  await page.goto('/runners');
  for (const label of ['Dedicated monitoring', 'Node A', 'Node B']) {
    await expect(page.locator('#runner-list').getByRole('link', { name: new RegExp(`^${label} · [0-9a-f-]+$`) })).toBeVisible();
  }
  await checkpoint(page, testInfo, 'all-runner-connections');
  await page.goto('/checks?view=list');
  await connected(page);
  const nodeA = (await streams(request, { search: 'node:node-a/export' })).items[0];
  await page.getByLabel('Observing runner', { exact: true }).selectOption(nodeA.runner_id);
  await expect(page.locator('[id^="result-"]')).toHaveCount(3);
  await expect(page.locator('.checks-match-count')).toContainText('3 matching');
  await checkpoint(page, testInfo, 'node-local-result-filter');
  expect(errors).toEqual([]);
});

test('five hundred targets use a bounded index with stable selection, scroll and reconnect', async ({ page, request }, testInfo) => {
  const errors = [];
  page.on('pageerror', (error) => errors.push(error.message));
  await expect.poll(async () => (await streams(request, { freshness: 'fresh' })).total,
    { timeout: 240_000 }).toBe(511);
  const liveScope = '/checks?search=exports%2Fexport-&environment=capacity-test';
  await page.goto(`${liveScope}&health=OK&freshness=fresh&view=targets`);
  await connected(page);
  await expect(page.locator('#inventory-view-targets')).toHaveAttribute('aria-pressed', 'true');
  await expect(page.locator('.checks-match-count')).toContainText('500 matching results');
  await expect(page.locator('.target-group')).toHaveCount(1);
  await expect(page.locator('[id^="result-"]')).toHaveCount(1);
  const targets = page.locator('.checks-target-index button[id^="inventory-target-"]');
  const more = page.locator('#inventory-load-more-groups');
  await expect(targets).toHaveCount(100);
  const first = await targets.evaluateAll((buttons) => buttons.map((button) => button.id));
  await targets.nth(30).click();
  const index = page.locator('#inventory-target-options');
  expect(await index.evaluate((element) => element.scrollTop)).toBeGreaterThan(0);
  await expect(page.locator('.checks-match-count')).toContainText('500 matching results');
  const immediatelyBeforeNext = await targets.evaluateAll((buttons) => buttons.map((button) => button.id));
  expect(immediatelyBeforeNext).toEqual(first);
  await more.evaluate((element) => element.focus({ preventScroll: true }));
  await page.keyboard.press('Enter');
  await expect(page.locator('.checks-match-count')).toContainText('500 matching results');
  await expect(targets).toHaveCount(200);
  const second = await targets.evaluateAll((buttons) => buttons.map((button) => button.id));
  expect(second.slice(0, 100)).toEqual(first);
  expect(new Set(second).size).toBe(200);

  // Selection and reconnect run against the live, unfiltered health states.
  // A target may change urgency while its selected result stays open; the
  // alphabetic index and original measured identity must remain stable.
  await page.goto(`${liveScope}&view=targets&group_limit=200`);
  await connected(page);
  await expect(targets).toHaveCount(200);
  const selectedButtonID = await targets.nth(130).getAttribute('id');
  const selectedTarget = selectedButtonID.replace('inventory-target-', '');
  await page.locator(`#${selectedButtonID}`).click();
  await expect(page).toHaveURL((url) => url.searchParams.get('target') === selectedTarget);
  await expect(page.locator(`#${selectedButtonID}`)).toHaveAttribute('aria-pressed', 'true');
  const selectedURL = page.url();
  const selectedResult = await page.locator('[id^="result-"]').getAttribute('id');
  const scrollTop = await index.evaluate((element) => element.scrollTop);
  expect(scrollTop).toBeGreaterThan(0);
  const updated = await page.locator('.live-indicator').textContent();
  await expect(page.locator('.live-indicator')).not.toHaveText(updated);
  expect(await index.evaluate((element) => element.scrollTop)).toBeCloseTo(scrollTop, 0);
  await expect(page.locator('[id^="result-"]')).toHaveAttribute('id', selectedResult);
  await expect(page).toHaveURL(selectedURL);
  await checkpoint(page, testInfo, 'five-hundred-target-index-expanded');

  await page.locator('#inventory-view-list').click();
  await expect(page.locator('[id^="result-"]')).toHaveCount(50);
  await page.locator('#inventory-view-targets').click();
  await expect(targets).toHaveCount(200);
  await expect(page.locator('[id^="result-"]')).toHaveAttribute('id', selectedResult);
  const rememberedURL = page.url();
  expect(new URL(rememberedURL).searchParams.get('target')).toBe(new URL(selectedURL).searchParams.get('target'));
  await page.reload();
  await connected(page);
  await expect(page).toHaveURL(rememberedURL);
  await expect(targets).toHaveCount(200);
  await expect(page.locator('[id^="result-"]')).toHaveAttribute('id', selectedResult);
  await page.evaluate(() => window.liveSocket.disconnect());
  await expect(page.locator('[data-phx-main]')).not.toHaveClass(/phx-connected/);
  await page.evaluate(() => window.liveSocket.connect());
  await connected(page);
  await expect(page).toHaveURL(rememberedURL);
  await expect(page.locator('[id^="result-"]')).toHaveAttribute('id', selectedResult);
  await page.setViewportSize({ width: 320, height: 740 });
  await checkpoint(page, testInfo, 'selected-target-after-reconnect-320');
  await page.getByLabel('Search', { exact: true }).fill('exports/export-0499.txt');
  await expect(targets).toHaveCount(1);
  await expect(page.locator('#inventory-view-targets')).toHaveAttribute('aria-pressed', 'true');
  await expect(page.locator('.target-group h3')).toHaveText('exports/export-0499.txt');
  await expect(more).toHaveCount(0);
  expect(errors).toEqual([]);
});

test('one datasource execution has independent target incidents and source timestamps', async ({ page, request }, testInfo) => {
  await mode(request, { ready: false, secondary_ready: true });
  await streamMeasured(request, 'service:primary', 'CRIT');
  await streamMeasured(request, 'service:secondary', 'OK');
  const items = (await streams(request, { search: 'service:' })).items;
  const primary = items.find((item) => item.target.key === 'service:primary');
  const secondary = items.find((item) => item.target.key === 'service:secondary');
  expect(primary.assignment_id).toBe(secondary.assignment_id);
  expect(primary.current.observation_id).toBe(secondary.current.observation_id);
  await page.goto(`/checks/${primary.id}`);
  await expect(page.locator('[id^="active-incident-"]')).toHaveCount(1);
  await checkpoint(page, testInfo, 'primary-datasource-failure');
  await page.locator('[id^="active-incident-"]').getByRole('link', { name: /Inspect incident/ }).click();
  await expect(page.locator('#incident-check-now')).toContainText('Critical');
  const incidentURL = page.url();
  await page.goto(`/checks/${secondary.id}`);
  await connected(page);
  await expect(page.locator('[id^="active-incident-"]')).toHaveCount(0);
  await expect(page.locator('.result-context > div').filter({ has: page.getByText('Target', { exact: true }) }).locator('dd'))
    .toHaveText('Secondary service');
  await checkpoint(page, testInfo, 'healthy-sibling-has-no-incident');
  await mode(request, { ready: true });
  await streamMeasured(request, 'service:primary');
  await page.goto(incidentURL);
  await expect(page.locator('#incident-summary')).toContainText('Measured recovery');
  await page.setViewportSize({ width: 390, height: 844 });
  await checkpoint(page, testInfo, 'independent-datasource-recovery-390');
});

async function maintenanceFormsFit(page) {
  for (const selector of ['#maintenance-selection-form', '#maintenance-form']) {
    if (!(await page.locator(selector).isVisible())) continue;
    const bounds = await page.locator(selector).evaluate((form) => {
      const outer = form.getBoundingClientRect();
      return {
        width: form.clientWidth,
        scroll: form.scrollWidth,
        outside: [...form.querySelectorAll('input, select, textarea, button, label')].flatMap((element) => {
          const rect = element.getBoundingClientRect();
          return rect.width && (rect.left < outer.left - 1 || rect.right > outer.right + 1) ? [element.id || element.tagName] : [];
        }),
      };
    });
    expect(bounds.outside, `${selector} controls fit their panel`).toEqual([]);
    expect(bounds.scroll).toBeLessThanOrEqual(bounds.width + 1);
  }
}

test('one maintenance window selects 500 real export targets with paging and a large reconnect-safe draft', async ({ page, request }, testInfo) => {
  const errors = [];
  page.on('pageerror', (error) => errors.push(error.message));
  await expect.poll(async () => (await streams(request, { freshness: 'fresh' })).total,
    { timeout: 240_000 }).toBe(511);
  await page.goto('/maintenance/new');
  await connected(page);
  await page.locator('#maintenance-kind').selectOption('target');
  await page.locator('#maintenance-source').fill('export-capacity');
  await page.locator('#maintenance-environment').fill('capacity-test');
  const pages = page.getByRole('navigation', { name: 'Maintenance selection pages', exact: true });
  await expect(pages).toContainText('500 choices');
  await expect(pages).toContainText('Page 1 of 20');
  await expect(page.locator('.maintenance-picker-rows li')).toHaveCount(25);
  const firstPage = await page.locator('.maintenance-picker-rows input[type="checkbox"]').evaluateAll((inputs) => inputs.map((input) => input.value));
  await page.locator('#maintenance-select-page').click();
  await expect(page.locator('#maintenance-selected-count')).toHaveText('25 selections');
  await pages.getByRole('button', { name: 'Next', exact: true }).click();
  await expect(pages).toContainText('Page 2 of 20');
  const secondPage = await page.locator('.maintenance-picker-rows input[type="checkbox"]').evaluateAll((inputs) => inputs.map((input) => input.value));
  expect(secondPage.filter((key) => firstPage.includes(key))).toEqual([]);
  await page.locator('.maintenance-picker-rows input[type="checkbox"]').first().check();
  await expect(page.locator('#maintenance-selected-count')).toHaveText('26 selections');
  await page.locator('#maintenance-name').fill('Export fleet maintenance');
  await page.locator('#maintenance-reason').fill('One shared window for the explicitly selected export files');
  await page.locator('#maintenance-search').fill('exports/export-0499.txt');
  await expect(page.locator('.maintenance-picker-rows li')).toHaveCount(1);
  await expect(page.locator('#maintenance-selected-count')).toHaveText('26 selections');
  await page.locator('#maintenance-search').fill('');
  await expect(pages).toContainText('500 choices');
  await page.locator('#maintenance-select-matching').click();
  await expect(page.locator('#maintenance-selected-count')).toHaveText('500 selections');
  await page.locator('#maintenance-review-selected').click();
  await expect(pages).toContainText('Page 1 of 20');
  await pages.getByRole('button', { name: 'Next', exact: true }).click();
  await expect(pages).toContainText('Page 2 of 20');
  const selectedPayload = await page.locator('#maintenance-form input[name="_proposal"]').inputValue();
  expect(Buffer.byteLength(selectedPayload)).toBeGreaterThan(16_000);
  expect(JSON.parse(selectedPayload).selections).toHaveLength(500);
  await page.setViewportSize({ width: 390, height: 844 });
  await maintenanceFormsFit(page);
  await checkpoint(page, testInfo, 'five-hundred-target-selection-review-390');

  // The basket is larger than the old scalar-only recovery limit, and both
  // forms acquire unsent changes while the actual LiveView socket is down.
  const offlineChoice = page.locator('.maintenance-picker-rows input[type="checkbox"]').first();
  const removedKey = await offlineChoice.inputValue();
  const removed = JSON.parse(Buffer.from(removedKey, 'base64url').toString());
  await page.evaluate(() => window.liveSocket.disconnect());
  await expect(page.locator('[data-phx-main]')).not.toHaveClass(/phx-connected/);
  await offlineChoice.uncheck();
  await page.locator('#maintenance-name').fill('Recovered export fleet window');
  await page.locator('#maintenance-reason').fill('This reason and the unchecked target were not sent before reconnect');
  await page.evaluate(() => window.liveSocket.connect());
  await connected(page);
  await expect(page.locator('#maintenance-selected-count')).toHaveText('499 selections');
  await expect(pages).toContainText('Page 2 of 20');
  await expect(page.locator('#maintenance-review-selected')).toHaveAttribute('aria-pressed', 'true');
  await expect(page.locator('#maintenance-name')).toHaveValue('Recovered export fleet window');
  await expect(page.locator('#maintenance-reason')).toHaveValue('This reason and the unchecked target were not sent before reconnect');
  const recovered = JSON.parse(await page.locator('#maintenance-form input[name="_proposal"]').inputValue());
  expect(recovered.selections.some((item) => item.target_key === removed.target_key)).toBe(false);
  expect(recovered.selections).toHaveLength(499);
  await page.locator('.maintenance-picker-rows li').first().getByRole('button', { name: /^Remove / }).click();
  await expect(page.locator('#maintenance-selected-count')).toHaveText('498 selections');
  await page.locator('#maintenance-clear-selection').click();
  await expect(page.locator('#maintenance-selected-count')).toHaveText('0 selections');
  await expect(page.locator('#maintenance-settings')).toBeHidden();
  await page.getByRole('button', { name: 'Available choices', exact: true }).click();
  await expect(page.locator('#maintenance-source')).toHaveValue('export-capacity');
  await expect(page.locator('#maintenance-environment')).toHaveValue('capacity-test');
  await page.locator('#maintenance-select-matching').click();
  await expect(page.locator('#maintenance-selected-count')).toHaveText('500 selections');
  await expect(page.locator('#maintenance-name')).toHaveValue('Recovered export fleet window');
  await page.locator('#maintenance-preview-button').click();
  await expect(page.locator('#maintenance-preview-summary')).toContainText('500 results across 50 scheduled checks');
  await expect(page.locator('#maintenance-saved-selection li')).toHaveCount(25);
  await expect(page.locator('#maintenance-preview .maintenance-matches li')).toHaveCount(25);
  const inspector = page.locator('#maintenance-selection-details');
  const inspectorToggle = inspector.locator(':scope > summary');
  await expect(inspector).not.toHaveAttribute('open');
  await expect(inspectorToggle).toHaveText('Inspect selected checks and targets (500)');
  await inspectorToggle.click();
  await expect(page.locator('#maintenance-saved-selection li').first()).toBeVisible();
  await expect(page.locator('#maintenance-saved-selection li strong')).toHaveText(
    Array.from({ length: 25 }, (_, index) => `exports/export-${String(index).padStart(4, '0')}.txt`),
  );
  const savedPages = page.getByRole('navigation', { name: 'Saved selection pages', exact: true });
  await expect(savedPages).toContainText('Page 1 of 20');
  await savedPages.getByRole('button', { name: 'Next', exact: true }).click();
  await expect(savedPages).toContainText('Page 2 of 20');
  await expect(page.locator('#maintenance-saved-selection li strong').first()).toHaveText('exports/export-0025.txt');
  await expect(inspector).toHaveJSProperty('open', true);
  await inspectorToggle.click();
  const matchesInspector = page.locator('#maintenance-preview-matches');
  await expect(matchesInspector).not.toHaveAttribute('open');
  await expect(matchesInspector.locator(':scope > summary')).toHaveText('Inspect currently matching results (500)');
  await matchesInspector.locator(':scope > summary').click();
  await expect(page.locator('#maintenance-preview .maintenance-matches li').first()).toBeVisible();
  const affectedPages = page.getByRole('navigation', { name: 'Affected result pages', exact: true });
  await affectedPages.getByRole('button', { name: 'Next', exact: true }).click();
  await expect(affectedPages).toContainText('Page 2 of 20');
  await expect(matchesInspector).toHaveJSProperty('open', true);
  await matchesInspector.locator(':scope > summary').click();
  await page.setViewportSize({ width: 320, height: 740 });
  expect((await inspector.boundingBox()).height).toBeLessThan(140);
  expect((await matchesInspector.boundingBox()).height).toBeLessThan(140);
  await maintenanceFormsFit(page);
  await checkpoint(page, testInfo, 'five-hundred-target-union-preview-320');
  await page.locator('#maintenance-save').click();
  await expect(page).toHaveURL(/\/maintenance\/[0-9a-f-]{36}$/);
  const id = new URL(page.url()).pathname.split('/').at(-1);
  const response = await request.get(`/api/v1/maintenance/${id}`);
  expect(response.ok(), await response.text()).toBe(true);
  const saved = await response.json();
  expect(saved.scope).toBe('selection');
  expect(saved.selections).toHaveLength(500);
  expect(saved.match_count).toBe(500);
  expect(new Set(saved.selections.map((item) => `${item.source_id}/${item.environment}/${item.target_kind}/${item.target_key}`)).size).toBe(500);
  await expect(page.locator('#maintenance-saved')).toContainText('500 selected checks or targets');
  await expect(page.locator('#maintenance-selection-form')).toHaveCount(0);
  await expect(page.locator('#maintenance-saved-selection li')).toHaveCount(25);
  await expect(inspector).not.toHaveAttribute('open');
  await inspectorToggle.click();
  await savedPages.getByRole('button', { name: 'Next', exact: true }).click();
  await expect(savedPages).toContainText('Page 2 of 20');
  await page.evaluate(() => window.liveSocket.disconnect());
  await expect(page.locator('[data-phx-main]')).not.toHaveClass(/phx-connected/);
  await page.evaluate(() => window.liveSocket.connect());
  await connected(page);
  await expect(page.locator('#maintenance-saved')).toContainText('500 selected checks or targets');
  await expect(page.locator('#maintenance-saved-selection li')).toHaveCount(25);
  await expect(inspector).toHaveJSProperty('open', true);
  await expect(page.locator('#maintenance-saved-selection li').first()).toBeVisible();
  await expect(page.locator('#maintenance-notice')).toHaveCount(0);
  await inspectorToggle.click();
  await page.setViewportSize({ width: 1280, height: 800 });
  await checkpoint(page, testInfo, 'saved-five-hundred-target-window');
  await page.locator('#maintenance-cancel').click();
  await page.locator('#maintenance-cancel-reason').fill('Shared export maintenance completed');
  await page.locator('#maintenance-confirm-cancel').click();
  await expect(page.locator('#maintenance-saved')).toContainText('Ended early');
  await expect(page.locator('#maintenance-history')).toContainText('Shared export maintenance completed');
  await expect(page.locator('#maintenance-saved-selection li')).toHaveCount(25);
  await expect(page.locator('#maintenance-form')).toHaveCount(0);
  expect(errors).toEqual([]);
});

test('five hundred declared scopes preserve complete counts, keyboard paging and filter recovery', async ({ page, request }, testInfo) => {
  await expect.poll(async () => {
    const response = await request.get('/api/v1/coverage?source_id=export-capacity');
    expect(response.ok()).toBeTruthy();
    return (await response.json()).summary.observed;
  }, { timeout: 240_000 }).toBe(500);
  await page.goto('/coverage?source_id=export-capacity');
  await connected(page);
  await expect(page.locator('#coverage-scopes [data-scope-id]')).toHaveCount(25);
  await expect(page.locator('#coverage-scopes-heading')).toHaveText('500 matching intended results');
  await expect(page.locator('#coverage-pages-top')).toContainText('Page 1 of 20');
  const firstPage = await page.locator('[data-scope-id]').evaluateAll((rows) => rows.map((row) => row.dataset.scopeId));
  await page.locator('#coverage-pages-bottom').getByRole('link', { name: 'Next', exact: true }).focus();
  await page.keyboard.press('Enter');
  await expect(page.locator('#coverage-pages-top')).toContainText('Page 2 of 20');
  await expect(page.locator('#coverage-scopes')).toBeFocused();
  const secondPage = await page.locator('[data-scope-id]').evaluateAll((rows) => rows.map((row) => row.dataset.scopeId));
  expect(new Set([...firstPage, ...secondPage]).size).toBe(50);
  await checkpoint(page, testInfo, 'five-hundred-declared-scopes');
  const updated = await page.locator('#coverage-updated').getAttribute('datetime');
  await page.locator('#coverage-search').focus();
  await expect(page.locator('#coverage-updated')).not.toHaveAttribute('datetime', updated);
  await expect(page.locator('#coverage-search')).toBeFocused();
  await page.locator('[data-scope-id] h3 a').first().click();
  await expect(page.locator('a.back')).toHaveAttribute('href', '/coverage?page=2&source_id=export-capacity');
  await page.locator('a.back').click();
  await expect(page.locator('#coverage-pages-top')).toContainText('Page 2 of 20');
  await page.evaluate(() => window.liveSocket.disconnect());
  await expect(page.locator('[data-phx-main]')).not.toHaveClass(/phx-connected/);
  await page.locator('#coverage-search').fill('export');
  await page.locator('#coverage-environment').fill('capacity-test');
  await page.evaluate(() => window.liveSocket.connect());
  await connected(page);
  await expect(page.locator('#coverage-search')).toHaveValue('export');
  await expect(page.locator('#coverage-environment')).toHaveValue('capacity-test');
  await expect(page.locator('#coverage-pages-top')).toContainText('Page 2 of 20');
  await page.locator('#coverage-filters button').click();
  await expect(page.locator('#coverage-pages-top')).toContainText('Page 1 of 20');
  await expect(page.locator('#coverage-scopes-heading')).toHaveText('500 matching intended results');
  await page.setViewportSize({ width: 320, height: 760 });
  await checkpoint(page, testInfo, 'declared-scope-filters-recovered-narrow');
});
