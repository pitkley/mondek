import { unpackAPI } from '../support/helpers.mjs';
// Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
// SPDX-License-Identifier: Apache-2.0
import {test, expect} from '@playwright/test';
import {checkpoint, connected, mode} from '../support/helpers.mjs';

test('LiveView overview preserves independent evidence and missing declarations across navigation and reconnect', async ({page, request}, testInfo) => {
  const scopes = async () => (await (await request.get('/api/v1/coverage')).json().then(unpackAPI)).items;
  let staging;
  await expect.poll(async () => {
    staging = (await scopes()).find(scope => scope.environment === 'staging');
    return staging?.status;
  }, {timeout: 90_000}).toBe('observed');
  const missing = (await scopes()).find(scope => scope.source_key === 'root-disk-node-b');
  expect(missing?.counts.selected).toBe(0);

  await mode(request, {grouped_samples: {
    'coverage-service-a-staging/elasticsearch': {available: true, used_percent: 96},
    'coverage-service-b-staging/elasticsearch': {available: true, used_percent: 40},
  }});
  await expect.poll(async () => {
    const response = await request.get(`/api/v1/coverage/${staging.id}/observers`);
    return (await response.json().then(unpackAPI)).items.some(observer => observer.current?.health === 'CRIT');
  }).toBe(true);

  await page.setViewportSize({width: 1600, height: 1000});
  await page.goto('/');
  await connected(page);
  await expect(page.locator('#preview-attention')).toContainText('Critical');
  const favicon = page.locator('#mondek-favicon');
  await expect(favicon).toHaveAttribute('data-open-alerts', /^[1-9]\d*$/);
  await expect(favicon).toHaveAttribute('href', /^data:image\/png/);
  await expect.poll(async () => {
    const total = (await page.locator('#overview-open-alert-count').textContent()).trim();
    return total === `${await favicon.getAttribute('data-open-alerts')} open`;
  }).toBe(true);
  await expect(page.locator('#preview-healthy-results')).toContainText('Healthy');
  await expect(page.locator('#preview-unobserved')).toContainText('No selected runner');
  await expect(page.locator('link[href*="app.css"]')).toHaveCount(0);
  const summaryColumns = page.locator('#preview-summary > div > h2');
  const summaryLeft = (await summaryColumns.nth(0).boundingBox()).x;
  const summaryRight = (await summaryColumns.nth(1).boundingBox()).x;
  for (const table of ['#preview-attention', '#preview-unobserved table', '#preview-healthy-results']) {
    const resultLeft = (await page.locator(`${table} tbody [data-overview-open]`).first().boundingBox()).x;
    const measurementLeft = await page.locator(`${table} tbody tr`).first().locator('td').nth(1)
      .evaluate(el => el.getBoundingClientRect().x + parseFloat(getComputedStyle(el).paddingLeft));
    expect(Math.abs(resultLeft - summaryLeft)).toBeLessThanOrEqual(1);
    expect(Math.abs(measurementLeft - summaryRight)).toBeLessThanOrEqual(1);
  }
  await checkpoint(page, testInfo, 'overview-desktop');

  const filterQuery = page.getByRole('combobox');
  await filterQuery.click();
  await expect(filterQuery).toBeFocused();
  await filterQuery.fill('tar');
  await filterQuery.press('Enter');
  await expect(filterQuery).toHaveAccessibleName('Target');
  const firstValue = page.getByRole('option').first();
  await expect(firstValue).toHaveAttribute('aria-selected', 'true');
  await filterQuery.press('ArrowDown');
  await expect(page.getByRole('option').nth(1)).toHaveAttribute('aria-selected', 'true');
  // Read the menu in the same task as input, before the server can reply.
  const pending = await filterQuery.evaluate(input => {
    input.value = 'no matching target';
    input.dispatchEvent(new InputEvent('input', {bubbles: true}));
    const listbox = document.getElementById(input.getAttribute('aria-controls'));
    return {
      busy: listbox.getAttribute('aria-busy'),
      visibleOptions: listbox.querySelectorAll('[role="option"]:not([hidden])').length,
      activeOption: input.getAttribute('aria-activedescendant'),
    };
  });
  expect(pending).toEqual({busy: 'true', visibleOptions: 0, activeOption: null});
  await expect(page.getByRole('status').filter({hasText: 'No matches'})).toBeVisible();
  await expect(page.getByRole('listbox')).toHaveAttribute('aria-busy', 'false');
  await filterQuery.fill('Node B');
  await expect(page.getByRole('option')).toHaveCount(1);
  await expect(page.getByRole('option')).toContainText('Node B');
  await expect(page.getByRole('option')).toHaveAttribute('aria-selected', 'true');
  await filterQuery.press('Enter');
  await expect(page).toHaveURL(/target_key=/);
  await expect(page.getByRole('option', {name: 'Environment', exact: true})).toBeVisible();
  await expect(page.getByRole('option', {name: 'Target', exact: true})).toHaveCount(0);
  await filterQuery.press('Backspace');
  await expect(filterQuery).toHaveAccessibleName('Target');
  await expect(filterQuery).toHaveValue('Node B');
  await expect(page.getByRole('option', {name: /Node A/})).toBeVisible();
  await expect.poll(() => filterQuery.evaluate(input => input.value.slice(input.selectionStart, input.selectionEnd))).toBe('Node B');
  const targetChip = page.getByRole('button', {name: /Edit Target filter: Node B/});
  await expect(targetChip).toHaveCount(0);
  await filterQuery.press('Escape');
  await expect(targetChip).toBeVisible();
  await expect(filterQuery).toHaveAttribute('aria-expanded', 'false');
  await expect(page.locator('#preview-unobserved tbody tr')).toHaveCount(1);
  await expect(page.locator('#preview-no-attention')).toHaveText(
    'No results needing attention match your filters.'
  );
  await expect(page.locator('#preview-attention')).toHaveCount(0);
  await expect(page.locator('#preview-healthy-results')).toHaveCount(0);
  await page.reload();
  await connected(page);
  await expect(page.getByRole('button', {name: /Edit Target filter: Node B/})).toBeVisible();
  await page.locator(`#open-expected-${missing.id}`).click();
  await expect(page).toHaveURL(/expected\/.*target_key=/);
  await page.locator('[data-overview-close]').click();
  await expect(page).toHaveURL(/\/\?target_key=/);
  await filterQuery.click();
  await filterQuery.press('Backspace');
  await expect(filterQuery).toHaveAccessibleName('Target');
  await filterQuery.press('Backspace');
  await expect(page).toHaveURL(/\/$/);
  await expect(filterQuery).toHaveAccessibleName('Search results and targets');
  await expect(filterQuery).toBeFocused();
  await expect(page.getByRole('option', {name: 'Target', exact: true})).toBeVisible();
  await expect(page.getByRole('link', {name: 'Remove Target filter'})).toHaveCount(0);

  await filterQuery.click();
  await page.getByRole('option', {name: 'Environment', exact: true}).click();
  await expect(filterQuery).toHaveAccessibleName('Environment');
  await filterQuery.press('Backspace');
  await expect(filterQuery).toHaveAccessibleName('Search results and targets');
  await expect(page.getByRole('option', {name: 'Environment', exact: true})).toBeVisible();
  await page.getByRole('option', {name: 'Environment', exact: true}).click();
  await page.getByRole('option', {name: /^Staging/i}).click();
  await expect(page).toHaveURL(/environment=staging/);
  const gaps = page.locator('#preview-unobserved');
  await expect(gaps).toContainText('No monitoring gaps match your filters.');
  await expect(gaps.getByRole('table')).toHaveCount(0);
  await expect(gaps.getByRole('navigation')).toHaveCount(0);
  await expect(page.locator('#preview-attention')).toContainText('Critical');
  await expect(page.locator('#preview-healthy-results')).toContainText('Healthy');
  await page.locator('#preview-search').fill('Search service');
  await page.locator('#preview-search').press('Enter');
  await expect(page).toHaveURL(/environment=staging.*search=/);
  await page.getByRole('link', {name: 'Clear search text'}).click();
  await expect(page).toHaveURL(/\/\?environment=staging$/);
  await page.getByRole('button', {name: /Edit Environment filter/}).click();
  await expect(filterQuery).toHaveAccessibleName('Environment');
  await filterQuery.press('Escape');
  await expect(filterQuery).toHaveAttribute('aria-expanded', 'false');
  await expect(filterQuery).toHaveAccessibleName('Search results and targets');
  await filterQuery.press('Backspace');
  await expect(filterQuery).toHaveAccessibleName('Environment');
  await filterQuery.fill('');
  await filterQuery.press('Backspace');
  await expect(page).toHaveURL(/\/$/);

  await page.setViewportSize({width: 320, height: 844});
  await filterQuery.click();
  await checkpoint(page, testInfo, 'overview-filter-320');
  await filterQuery.press('Escape');
  await page.setViewportSize({width: 1600, height: 1000});

  // Every row type selects and toggles, and the board stays in place.
  const attentionBox = await page.locator('#preview-attention').boundingBox();
  const healthyOpener = page.locator('#preview-healthy-results [data-overview-open]').first();
  await healthyOpener.click();
  await expect(page.locator('#preview-healthy-results .preview-selected')).toHaveCount(1);
  await expect(page.locator('#overview-panel')).toBeVisible();
  expect(await page.locator('#preview-attention').boundingBox()).toEqual(attentionBox);
  await healthyOpener.click();
  await expect(page.locator('#overview-panel')).toHaveCount(0);
  const missingOpener = page.locator(`#open-expected-${missing.id}`);
  await missingOpener.click();
  await expect(page.locator('#preview-unobserved .preview-selected')).toHaveCount(1);
  await page.locator('#overview-heading').click();
  await expect(page.locator('#overview-panel')).toHaveCount(0);
  await missingOpener.click();
  await expect(page.locator('#overview-panel')).toBeVisible();
  await missingOpener.click();
  await expect(page.locator('#overview-panel')).toHaveCount(0);

  await expect(page).toHaveURL(/\/$/);
  const search = page.locator('#preview-search');
  await search.fill(staging.source_key);
  await search.press('Enter');
  await expect(page).toHaveURL(new RegExp(`search=${encodeURIComponent(staging.source_key)}`));
  await expect(search).toBeFocused();
  await expect(search).toHaveAttribute('aria-expanded', 'false');
  await expect(page.locator('#preview-attention [data-overview-open]')).toHaveCount(1);
  const opener = page.locator('#preview-attention [data-overview-open]');
  const openerId = await opener.getAttribute('id');
  await opener.click();
  await expect(page).toHaveURL(/\/results\//);
  await expect(page.locator('#overview-panel-title')).toBeFocused();
  let selectedURL = page.url();
  await expect(page.locator('#overview-panel .preview-evidence-state')).toHaveCount(1);
  await expect(page.locator('#overview-panel .preview-evidence-state').filter({hasText: 'Critical'})).toHaveCount(1);
  await expect(page.locator('#overview-panel .preview-evidence-state').filter({hasText: 'Healthy'})).toHaveCount(0);
  await expect(page.locator('#preview-related-results')).not.toHaveAttribute('open');
  await page.locator('#preview-related-results summary').click();
  const updated = await page.locator('.preview-heading time').getAttribute('datetime');
  await expect.poll(() => page.locator('.preview-heading time').getAttribute('datetime')).not.toBe(updated);
  await expect(page.locator('#preview-related-results')).toHaveAttribute('open', '');
  await expect(page.locator('#preview-related-results')).toContainText('Healthy');
  await page.locator('#preview-related-results a').first().click();
  await expect(page.locator('#overview-panel .preview-evidence-state')).toContainText('Healthy');
  await expect.poll(() => page.locator('#overview-panel').evaluate(el => el.scrollTop)).toBe(0);
  await expect(page.locator('#preview-healthy-results .preview-selected')).toHaveCount(1);
  await page.locator('#preview-related-results summary').click();
  await page.locator('#preview-related-results a').first().click();
  expect(new URL(page.url()).pathname).toBe(new URL(selectedURL).pathname);
  expect(new URL(page.url()).searchParams.get('search')).toBe(staging.source_key);
  await expect.poll(() => new URL(page.url()).searchParams.get('inspect')).toBe(`result:${openerId.replace('open-result-', '')}`);
  await expect(page.locator('.preview-panel-back-card')).toHaveCount(0);
  selectedURL = page.url();
  await checkpoint(page, testInfo, 'overview-independent-observers');
  await opener.locator('..').click();
  await expect(page.locator('#overview-panel')).toHaveCount(0);
  await opener.click();
  await expect(page.locator('#overview-panel')).toBeVisible();
  await search.click({position: {x: 8, y: 8}});
  await expect(page.locator('#overview-panel')).toHaveCount(0);
  await expect(search).toBeFocused();
  await opener.click();
  await expect(page.locator('#overview-panel')).toBeVisible();

  selectedURL = page.url();
  await page.context().setOffline(true);
  // Chromium may keep an established WebSocket alive under HTTP offline emulation.
  // Force a reconnect while offline so the LiveView transport actually fails.
  await page.evaluate(() => { window.liveSocket.disconnect(); window.liveSocket.connect(); });
  await expect(page.locator('#overview-preview > main > .preview-connection')).toBeVisible();
  await page.context().setOffline(false);
  await connected(page);
  await expect(page).toHaveURL(selectedURL);
  await expect(page.locator('#overview-panel')).toContainText('Critical');
  await expect(favicon).toHaveAttribute('href', /^data:image\/png/);
  await page.keyboard.press('Escape');
  await expect(page.locator('#overview-panel')).toHaveCount(0);
  await expect(page.locator(`#${openerId}`)).toBeFocused();
  await page.goBack();
  await expect(page).toHaveURL(selectedURL);
  await expect(page.locator('#overview-panel')).toBeVisible();

  await page.locator('#overview-panel').getByRole('link', {name: 'View check configuration'}).first().click();
  await connected(page);
  await page.getByRole('link', {name: '← Back to result', exact: true}).click();
  // A direct result route and an explicit trail for that same result are
  // equivalent. The editor normalizes its return to an explicit typed trail.
  await expect.poll(() => new URL(page.url()).pathname).toBe(new URL(selectedURL).pathname);
  expect(new URL(page.url()).searchParams.get('search')).toBe(staging.source_key);
  await expect.poll(() => new URL(page.url()).searchParams.get('inspect')).toBe(`result:${openerId.replace('open-result-', '')}`);
  await connected(page);
  await expect(page.locator('#overview-panel')).toContainText('Critical');
  await expect(page.locator('.preview-panel-back-card')).toHaveCount(0);

  await mode(request, {grouped_samples: {'coverage-service-a-staging/elasticsearch': {available: false}}});
  await expect(page.locator('#overview-panel')).toContainText('Collection unavailable');
  await expect(page.locator('#overview-panel')).toContainText('Critical');
  await expect(page.locator('#overview-panel .preview-evidence-state')).not.toContainText('Healthy');
  await checkpoint(page, testInfo, 'overview-retained-failure');

  await page.goto('/');
  await page.locator(`#open-expected-${missing.id}`).click();
  await expect(page.locator('#overview-panel')).toContainText('No runner is selected');
  await expect(page.locator('#overview-panel a[href^="/checks/"]')).toHaveCount(0);
  const expectedURL = page.url();
  await page.locator('#overview-panel').getByRole('link', {name: 'Open as page', exact: true}).click();
  await connected(page);
  await expect(page.locator('#coverage-page-body')).toContainText('No runner is selected');
  await expect(page.locator('#coverage-page-heading')).toBeVisible();
  await page.goBack();
  await expect(page).toHaveURL(expectedURL);
  await page.reload();
  await connected(page);
  for (const width of [390, 320]) {
    await page.setViewportSize({width, height: 844});
    await expect(page.locator('#overview-panel')).toHaveAttribute('aria-modal', 'true');
    await page.locator('[data-overview-close]').focus();
    await page.keyboard.press('Shift+Tab');
    await expect(page.locator('#overview-panel')).toContainText('No runner is selected');
    expect(await page.locator('#overview-panel').evaluate(el => el.contains(document.activeElement))).toBe(true);
    await page.locator('[data-overview-close]').focus();
    await checkpoint(page, testInfo, `overview-declaration-${width}`);
    await page.locator('[data-overview-close]').click();
    await expect(page.locator('#preview-unobserved')).toBeVisible();
    await checkpoint(page, testInfo, `overview-list-${width}`);
    await page.locator('#preview-attention [data-overview-open]').first().click();
    await expect(page.locator('#overview-panel')).toContainText('Critical');
    await expect(page.locator('#overview-panel .preview-evidence-state')).not.toContainText('Healthy');
    await checkpoint(page, testInfo, `overview-observers-${width}`);
    await page.goto(`/expected/${missing.id}`);
    await connected(page);
  }
});

test('Pearl shell preserves clear active navigation and compact narrow layout', async ({page}, testInfo) => {
  await page.goto('/');
  await connected(page);
  await expect(page.locator('html')).toHaveAttribute('data-preview-theme', 'pearl');
  await expect(page.getByRole('navigation', {name: 'Main navigation'}).getByRole('link', {name: 'Overview', exact: true})).toHaveAttribute('aria-current', 'page');
  await expect(page.locator('link[href*="app.css"]')).toHaveCount(0);
  for (const width of [1600, 390, 320]) {
    await page.setViewportSize({width, height: 900});
    await checkpoint(page, testInfo, `pearl-shell-${width}`);
  }
});

test('thirty real alerts remain compact and page without dropping evidence', async ({page, request}, testInfo) => {
  const {randomUUID} = await import('node:crypto');
  const identity = {version: 1, installation_id: randomUUID(), session_id: randomUUID(), boot: 1};
  const checks = Array.from({length: 31}, (_, index) => {
    const name = `web-${String(index + 1).padStart(2, '0')}`;
    return {key: name, label: 'Root filesystem', definition_revision: 'b'.repeat(64),
      environment: 'production', environment_label: 'Production', params_owner: 'source',
      parameter_schema: {fields: {}}, params: {}, interval_seconds: 60, timeout_seconds: 3,
      freshness_seconds: 3600, outputs: [{key: 'capacity', label: 'Capacity',
        target: {key: name, label: name, kind: 'host'}}]};
  });
  const post = async (path, data) => {
    const response = await request.post(`/api/v1/runner/${path}`, {data});
    expect(response.ok(), await response.text()).toBeTruthy();
    return response.json().then(unpackAPI);
  };
  await post('inventory', {...identity, runner_label: 'Density preview', source_id: 'density-preview',
    source_revision: 'a'.repeat(64), inventory_revision: 1, complete: true, checks});
  const {assignments} = await post('control', {...identity, prepared: {}, active: {}, wait_seconds: 0});
  const prepared = Object.fromEntries(assignments.map(row => [row.id, row.generation]));
  await post('control', {...identity, prepared, active: {}, wait_seconds: 0});
  const at = new Date().toISOString().replace('Z', '000Z');
  const admission = await post('observations', {...identity, reports: assignments.map(row => ({
    id: randomUUID(), assignment_id: row.id, installation_id: identity.installation_id,
    session_id: identity.session_id, generation: row.generation, sequence: 1,
    started_at: at, evaluated_at: at, complete: true, diagnostic: '',
    results: [{key: 'capacity', health: 'CRIT', value: 96, source_at: at,
      summary: 'Root filesystem is 96% used'}],
  }))});
  expect(admission.dispositions.map(row => row.disposition)).toEqual(Array(31).fill('current'));
  await page.setViewportSize({width: 1600, height: 1100});
  await page.goto('/?search=Density');
  await connected(page);
  const rows = page.locator('#preview-attention tbody tr');
  await expect(rows).toHaveCount(30);
  await expect(rows.first()).toContainText('Critical');
  await expect(rows.first()).toContainText('Root filesystem is 96% used');
  const firstPageIDs = await rows.locator('[data-overview-open]').evaluateAll(nodes => nodes.map(node => node.id));
  for (const box of await rows.evaluateAll(nodes => nodes.map(node => ({height: node.getBoundingClientRect().height})))) {
    expect(box.height, 'Desktop rows should remain a single compact scan line').toBeLessThanOrEqual(28);
  }
  // The Overview also contains incidents above Results. Measure the result
  // list's scan density from the first result row.
  const firstRowTop = (await rows.first().boundingBox()).y;
  const twentieth = await rows.nth(19).boundingBox();
  expect(twentieth.y + twentieth.height - firstRowTop, 'Twenty rows should retain compact list density').toBeLessThanOrEqual(20 * 28 + 2);
  const last = await rows.last().boundingBox();
  expect(last.y + last.height - firstRowTop, 'Thirty rows should retain compact list density').toBeLessThanOrEqual(30 * 28 + 2);
  await checkpoint(page, testInfo, 'overview-thirty-alerts');
  await page.getByRole('navigation', {name: 'Results needing attention', exact: true}).getByRole('link', {name: 'Next', exact: true}).click();
  await expect(rows).toHaveCount(1);
  expect(firstPageIDs).not.toContain(await rows.locator('[data-overview-open]').getAttribute('id'));
  await page.setViewportSize({width: 320, height: 844});
  await checkpoint(page, testInfo, 'overview-density-320');
  await page.locator('#preview-attention [data-overview-open]').click();
  await expect(page.locator('#overview-panel')).toContainText('Root filesystem is 96% used');
  await expect(page.locator('#overview-panel')).toHaveAttribute('aria-modal', 'true');
});
