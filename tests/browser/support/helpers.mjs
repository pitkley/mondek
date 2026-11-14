// Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
// SPDX-License-Identifier: Apache-2.0
import { expect } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';

export const fixtureURL = process.env.MONDEK_BROWSER_FIXTURE_URL || 'http://localhost:58080';

export async function mode(request, changes) {
  const response = await request.post(`${fixtureURL}/mode`, { data: changes });
  expect(response.ok(), await response.text()).toBeTruthy();
}

export async function snapshot(request) {
  const response = await request.get('/api/v1/snapshot');
  expect(response.ok()).toBeTruthy();
  return response.json();
}

export async function demoAssignments(request) {
  let checks;
  await expect.poll(async () => {
    const rows = (await snapshot(request)).assignments;
    checks = Object.fromEntries(['filesystem', 'http', 'consumer'].map((key) => [key, rows.find((row) => row.source_key === key)]));
    return Object.values(checks).every(Boolean);
  }, { timeout: 45_000 }).toBe(true);
  return checks;
}

export async function connected(page) {
  await expect(page.locator('[data-phx-main]')).toHaveClass(/phx-connected/);
}

export async function incidentNavigation(page, request, expected) {
  let counts;
  await expect.poll(async () => {
    const response = await request.get('/api/v1/overview');
    expect(response.ok()).toBeTruthy();
    const overview = await response.json();
    counts = { health: overview.unacknowledged_incident_count || 0,
      monitoring: overview.monitoring_loss?.unacknowledged_count || 0 };
    return expected ? counts : true;
  }).toEqual(expected || true);
  const navigation = page.getByRole('navigation', {name: 'Main navigation'}).getByRole('link', {name: 'Incidents', exact: true});
  await expect(navigation).toHaveAttribute('href', '/incidents');
  // The old split +loss counter was intentionally removed. Counts are asserted
  // against the independent domain projection; one navigation item opens both types.
  return counts;
}

export async function sectionTabs(page, section, _navigationLabel, _viewHeading) {
  // Secondary tabs were intentionally replaced with one section and chip filters.
  const active = page.getByRole('navigation', {name: 'Main navigation'}).getByRole('link', {name: section, exact: true});
  await expect(active).toHaveAttribute('aria-current', 'page');
  const heading = page.getByRole('main').getByRole('heading', {level: 1});
  await expect(heading).toHaveCount(1);
  await expect(heading).toBeVisible();
}

export async function tabTo(page, target, { backward = false } = {}) {
  await expect(target).toBeVisible();
  for (let i = 0; i < 80; i += 1) {
    if (await target.evaluate((element) => element === document.activeElement)) return;
    await page.keyboard.press(backward ? 'Shift+Tab' : 'Tab');
  }
  await expect(target, 'Control must be reachable through the real Tab order').toBeFocused();
}

export async function keyboardFill(page, target, value, navigation) {
  await tabTo(page, target, navigation);
  await page.keyboard.press('ControlOrMeta+A');
  await page.keyboard.insertText(value);
}

export async function keyboardSubmit(page, button) {
  await tabTo(page, button);
  await page.keyboard.press('Enter');
}

export async function checkpoint(page, testInfo, label) {
  console.log(`Checkpoint: ${label}`);
  await connected(page);
  const scan = await new AxeBuilder({ page }).analyze();
  await testInfo.attach(`accessibility-${label}`, {
    body: JSON.stringify(scan, null, 2), contentType: 'application/json',
  });
  await testInfo.attach(`screen-${label}`, {
    body: await page.screenshot(), contentType: 'image/png',
  });
  const layout = await page.evaluate(() => {
    const viewport = document.documentElement.clientWidth;
    return {
      viewport,
      documentWidth: document.documentElement.scrollWidth,
      scrollX: window.scrollX,
      outsideViewport: [...document.querySelectorAll('body *')].flatMap((element) => {
        const box = element.getBoundingClientRect();
        if (!box.width || (box.left >= 0 && box.right <= viewport)) return [];
        const style = getComputedStyle(element);
        return [{
          tag: element.tagName, id: element.id, class: String(element.className),
          left: box.left, right: box.right, width: box.width,
          position: style.position, overflowX: style.overflowX,
          parent: element.parentElement?.tagName,
          parentClass: String(element.parentElement?.className),
        }];
      }).slice(0, 100),
    };
  });
  await testInfo.attach(`layout-${label}`, {
    body: JSON.stringify(layout, null, 2), contentType: 'application/json',
  });
  expect(scan.violations, `Accessibility violations at ${label}`).toEqual([]);
  expect(layout.documentWidth, `Page overflow at ${label}`).toBeLessThanOrEqual(layout.viewport + 1);
}

export async function streams(request, filters = {}) {
  const response = await request.get(`/api/v1/checks?${new URLSearchParams(filters)}`);
  expect(response.ok(), `Check inventory returned HTTP ${response.status()}`).toBeTruthy();
  return response.json();
}

export async function streamMeasured(request, target, health = 'OK', timeout = 45_000) {
  await expect.poll(async () => {
    const item = (await streams(request, { search: target })).items.find((row) => row.target.key === target);
    return item?.current?.knowledge === 'fresh' && item?.current?.health === health;
  }, { message: `${target} must receive a fresh ${health} measurement`, timeout }).toBe(true);
}

export async function measured(request, id, health = 'OK') {
  await expect.poll(async () => {
    const current = (await snapshot(request)).assignments.find((check) => check.id === id)?.current;
    return current?.knowledge === 'fresh' && current?.health === health && !!current?.confirmed_observation_id;
  }, { message: `Check ${id} must receive its own fresh ${health} measurement`, timeout: 45_000 }).toBe(true);
}

export async function attachState(request, testInfo, label) {
  await testInfo.attach(label, { body: JSON.stringify(await snapshot(request), null, 2), contentType: 'application/json' });
}

export async function reviewedMaintenance(request, assignment, seconds, reason) {
  const seedResponse = await request.get(`/api/v1/maintenance/seed/${assignment}`);
  expect(seedResponse.ok(), await seedResponse.text()).toBe(true);
  const seed = await seedResponse.json();
  const proposal = { ...seed.proposal, name: 'Browser maintenance', reason,
    timezone: 'UTC', start_mode: 'now',
    ends_local: new Date(Date.now() + seconds * 1000).toISOString().slice(0, 19) };
  const previewResponse = await request.post('/api/v1/maintenance/preview', { data: { proposal } });
  expect(previewResponse.ok(), await previewResponse.text()).toBe(true);
  const preview = await previewResponse.json();
  const response = await request.post('/api/v1/maintenance/apply', {
    data: { proposal: preview.proposal, review_token: preview.review_token },
  });
  expect(response.ok(), await response.text()).toBe(true);
  return response.json();
}

export async function cancelReviewedMaintenance(request, window, reason) {
  const response = await request.post(`/api/v1/maintenance/${window.id}/cancel`, {
    data: { revision: window.revision, reason },
  });
  expect(response.ok(), await response.text()).toBe(true);
}

// Exercise the same two-step picker used by operators, including editing/removal.
// Field names are protocol keys; values remain exact identities rather than labels.
export async function setFilter(page, field, value, {id, kind} = {}) {
  const bar = id ? page.locator(`#${id}`) : page.locator('[phx-hook="PreviewFilterPicker"]').first();
  const input = bar.getByRole('combobox');
  const fieldAttr = JSON.stringify(String(field));
  const existing = bar.locator(`.preview-filter-chip > button[phx-click="filter_open"][phx-value-field=${fieldAttr}]`);
  if (value === null || value === undefined) {
    if (await existing.count()) {
      const chip = existing.locator('..');
      await chip.getByRole('link', {name: /^Remove .* filter$/}).or(chip.getByRole('button', {name: /^Remove .* filter$/})).click();
      await expect(existing).toHaveCount(0);
    }
    await input.press('Escape');
    return;
  }
  if (await existing.count()) await existing.click();
  else {
    await input.click();
    await input.fill('');
    await bar.locator(`[role="option"][phx-value-field=${fieldAttr}]`).click();
  }
  await expect(bar).toHaveAttribute('data-step', field);
  const kindSelector = kind === undefined ? '' : `[phx-value-kind=${JSON.stringify(String(kind))}]`;
  const option = bar.locator(`[role="option"][phx-value-key=${JSON.stringify(String(value))}]${kindSelector}`);
  if (!await option.count()) await input.fill(String(value));
  await expect(option).toBeVisible();
  await option.click();
  await expect(bar).not.toHaveAttribute('data-step', field);
  await input.press('Escape');
  if (value !== 'all') await expect(existing).toBeVisible();
}

export async function searchFilters(page, value, {id} = {}) {
  const bar = id ? page.locator(`#${id}`) : page.locator('[phx-hook="PreviewFilterPicker"]').first();
  const input = bar.getByRole('combobox');
  if (value === '') {
    const clear = bar.locator('[aria-label="Clear search text"]');
    if (await clear.count()) await clear.click();
    await input.click();
    await input.fill('');
    await input.press('Escape');
    await connected(page);
    await expect(bar).toHaveAttribute('data-search', '');
    return;
  }
  await input.click();
  await input.press('Escape');
  await input.fill(value);
  await input.press('Enter');
  await connected(page);
  await expect(bar).toHaveAttribute('data-search', value);
  await input.press('Escape');
}

// Related evidence can make an implicit root explicit in inspect. Retain every
// owner/filter parameter and require the exact returned typed stack.
export async function expectInvestigationReturn(page, owner, trail) {
  const expected = new URL(owner, page.url());
  expected.searchParams.delete('inspect');
  expected.searchParams.sort();
  const selection = Array.isArray(trail) ? trail.join(',') : trail;
  await expect(page).toHaveURL(actual => {
    const filters = new URLSearchParams(actual.search);
    filters.delete('inspect');
    filters.sort();
    return actual.origin === expected.origin && actual.pathname === expected.pathname
      && filters.toString() === expected.searchParams.toString()
      && actual.searchParams.get('inspect') === selection;
  });
}

export async function reconnect(page, {alreadyDisconnected = false} = {}) {
  if (!alreadyDisconnected) await page.evaluate(() => window.liveSocket.disconnect());
  await expect(page.locator('[data-phx-main]')).not.toHaveClass(/phx-connected/);
  await page.evaluate(() => window.liveSocket.connect());
  await connected(page);
}
