// Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
// SPDX-License-Identifier: Apache-2.0
import {test, expect} from '@playwright/test';
import {checkpoint, connected, mode} from '../support/helpers.mjs';

test('LiveView overview preserves independent evidence and missing declarations across navigation and reconnect', async ({page, request}, testInfo) => {
  const scopes = async () => (await (await request.get('/api/v1/coverage')).json()).items;
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
    return (await response.json()).items.some(observer => observer.current?.health === 'CRIT');
  }).toBe(true);

  await page.setViewportSize({width: 1600, height: 1000});
  await page.goto('/next');
  await connected(page);
  await expect(page.locator('#preview-attention')).toContainText('Critical');
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
  await checkpoint(page, testInfo, 'next-overview-desktop');

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

  await expect(page).toHaveURL(/\/next$/);
  const search = page.locator('#preview-search');
  await search.fill(staging.source_key);
  await expect(page).toHaveURL(new RegExp(`search=${encodeURIComponent(staging.source_key)}`));
  await expect(search).toBeFocused();
  await expect(page.locator('#preview-attention [data-overview-open]')).toHaveCount(1);
  const opener = page.locator('#preview-attention [data-overview-open]');
  const openerId = await opener.getAttribute('id');
  await opener.click();
  await expect(page).toHaveURL(/\/next\/results\//);
  await expect(page.locator('#overview-panel-title')).toBeFocused();
  const selectedURL = page.url();
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
  await expect(page).toHaveURL(selectedURL);
  await checkpoint(page, testInfo, 'next-overview-independent-observers');
  await opener.locator('..').click();
  await expect(page.locator('#overview-panel')).toHaveCount(0);
  await opener.click();
  await expect(page.locator('#overview-panel')).toBeVisible();
  await search.click();
  await expect(page.locator('#overview-panel')).toHaveCount(0);
  await expect(search).toBeFocused();
  await opener.click();
  await expect(page.locator('#overview-panel')).toBeVisible();

  await page.context().setOffline(true);
  // Chromium may keep an established WebSocket alive under HTTP offline emulation.
  // Force a reconnect while offline so the LiveView transport actually fails.
  await page.evaluate(() => { window.liveSocket.disconnect(); window.liveSocket.connect(); });
  await expect(page.locator('#overview-panel .preview-connection')).toBeVisible();
  await page.context().setOffline(false);
  await connected(page);
  await expect(page).toHaveURL(selectedURL);
  await expect(page.locator('#overview-panel')).toContainText('Critical');
  await page.keyboard.press('Escape');
  await expect(page.locator('#overview-panel')).toHaveCount(0);
  await expect(page.locator(`#${openerId}`)).toBeFocused();
  await page.goBack();
  await expect(page).toHaveURL(selectedURL);
  await expect(page.locator('#overview-panel')).toBeVisible();

  await page.locator('#overview-panel').getByRole('link', {name: 'Full result and configuration'}).first().click();
  await connected(page);
  await page.getByRole('link', {name: 'Back to overview preview', exact: true}).click();
  await expect(page).toHaveURL(selectedURL);
  await connected(page);

  await mode(request, {grouped_samples: {'coverage-service-a-staging/elasticsearch': {available: false}}});
  await expect(page.locator('#overview-panel')).toContainText('Collection unavailable');
  await expect(page.locator('#overview-panel')).toContainText('Critical');
  await expect(page.locator('#overview-panel .preview-evidence-state')).not.toContainText('Healthy');
  await checkpoint(page, testInfo, 'next-overview-retained-failure');

  await page.goto('/next');
  await page.locator(`#open-expected-${missing.id}`).click();
  await expect(page.locator('#overview-panel')).toContainText('No runner is selected');
  await expect(page.locator('#overview-panel a[href^="/checks/"]')).toHaveCount(0);
  const expectedURL = page.url();
  await page.getByRole('link', {name: 'Full declaration and placement details'}).click();
  await connected(page);
  await page.getByRole('link', {name: 'Back to overview preview', exact: true}).click();
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
    await checkpoint(page, testInfo, `next-overview-declaration-${width}`);
    await page.locator('[data-overview-close]').click();
    await expect(page.locator('#preview-unobserved')).toBeVisible();
    await checkpoint(page, testInfo, `next-overview-list-${width}`);
    await page.locator('#preview-attention [data-overview-open]').first().click();
    await expect(page.locator('#overview-panel')).toContainText('Critical');
    await expect(page.locator('#overview-panel .preview-evidence-state')).not.toContainText('Healthy');
    await checkpoint(page, testInfo, `next-overview-observers-${width}`);
    await page.goto(`/next/expected/${missing.id}`);
    await connected(page);
  }
});

test('light themes preserve geometry, evidence and local preference', async ({page}, testInfo) => {
  await page.setViewportSize({width: 1600, height: 1000});
  await page.goto('/next');
  await connected(page);
  const picker = page.locator('#preview-theme-picker');
  const choose = async (theme) => {
    await picker.locator('summary').click();
    await picker.locator(`input[value="${theme}"]`).check();
    if (await picker.getAttribute('open') !== null) await picker.locator('summary').click();
    await expect(page.locator('html')).toHaveAttribute('data-preview-theme', theme);
    await expect(picker.locator('summary')).toBeFocused();
  };
  await picker.locator('summary').click();
  await checkpoint(page, testInfo, 'theme-menu');
  await page.keyboard.press('Escape');
  await expect(picker.locator('summary')).toBeFocused();
  const boardBox = await page.locator('#preview-summary').boundingBox();
  const searchBox = await page.locator('#preview-search').boundingBox();
  for (const theme of ['pearl', 'clear', 'mist', 'linen', 'original']) {
    await choose(theme);
    expect(await page.locator('#preview-summary').boundingBox()).toEqual(boardBox);
    expect(await page.locator('#preview-search').boundingBox()).toEqual(searchBox);
    const nav = page.getByRole('navigation', {name: 'Main navigation', exact: true});
    const current = nav.getByRole('link', {name: 'Overview', exact: true});
    const incidents = nav.getByRole('link', {name: 'Incidents', exact: true});
    await expect(current).toHaveAttribute('aria-current', 'page');
    const currentBackground = await current.evaluate(el => getComputedStyle(el).backgroundColor);
    expect(currentBackground).not.toBe('rgba(0, 0, 0, 0)');
    await page.locator('#overview-heading').hover();
    const idleBackground = await incidents.evaluate(el => getComputedStyle(el).backgroundColor);
    await incidents.hover();
    await expect.poll(() => incidents.evaluate(el => getComputedStyle(el).backgroundColor)).not.toBe(idleBackground);
    expect(await current.evaluate(el => getComputedStyle(el).backgroundColor)).not.toBe(await incidents.evaluate(el => getComputedStyle(el).backgroundColor));
    await checkpoint(page, testInfo, `theme-${theme}-desktop`);
  }
  await choose('pearl');
  await page.reload();
  await connected(page);
  await expect(page.locator('html')).toHaveAttribute('data-preview-theme', 'pearl');
  await expect(picker.locator('input[value="pearl"]')).toBeChecked();
  await page.locator('[data-overview-open]').first().click();
  await expect(page.locator('#overview-panel')).toBeVisible();
  const selectedURL = page.url();
  const panelBox = await page.locator('#overview-panel').boundingBox();
  await choose('pearl');
  await expect(page).toHaveURL(selectedURL);
  expect(await page.locator('#overview-panel').boundingBox()).toEqual(panelBox);
  await checkpoint(page, testInfo, 'theme-pearl-panel');
  await page.locator('[data-overview-close]').click();
  await page.setViewportSize({width: 320, height: 844});
  for (const theme of ['pearl', 'clear', 'mist', 'linen', 'original']) {
    await choose(theme);
    await checkpoint(page, testInfo, `theme-${theme}-320`);
  }
  await choose('pearl');
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
    const response = await request.post(`/api/v1/${path}`, {data});
    expect(response.ok(), await response.text()).toBeTruthy();
    return response.json();
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
  await page.goto('/next?search=Density');
  await connected(page);
  const rows = page.locator('#preview-attention tbody tr');
  await expect(rows).toHaveCount(30);
  await expect(rows.first()).toContainText('Critical');
  await expect(rows.first()).toContainText('Root filesystem is 96% used');
  const firstPageIDs = await rows.locator('[data-overview-open]').evaluateAll(nodes => nodes.map(node => node.id));
  for (const box of await rows.evaluateAll(nodes => nodes.map(node => ({height: node.getBoundingClientRect().height})))) {
    expect(box.height, 'Desktop rows should remain a single compact scan line').toBeLessThanOrEqual(28);
  }
  const twentieth = await rows.nth(19).boundingBox();
  expect(twentieth.y + twentieth.height, 'Twenty alerts should fit within 900px of viewport height').toBeLessThanOrEqual(900);
  const last = await rows.last().boundingBox();
  expect(last.y + last.height, 'Thirty alerts should fit in the tall desktop viewport').toBeLessThanOrEqual(1100);
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
