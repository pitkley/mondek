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
  const navigation = page.locator('#incident-navigation');
  const monitoringLabel = counts.monitoring ? ` · ${counts.monitoring} monitoring loss incidents need attention` : '';
  await expect(navigation).toHaveAttribute('aria-label', `Incidents · ${counts.health} unacknowledged open incidents${monitoringLabel}`);
  await expect(navigation.locator('#incident-attention-count')).toHaveText(String(counts.health));
  if (counts.monitoring) await expect(navigation.locator('.monitoring-loss-count')).toHaveText(`+${counts.monitoring}`);
  else await expect(navigation.locator('.monitoring-loss-count')).toHaveCount(0);
  return counts;
}

export async function sectionTabs(page, section, navigationLabel, viewHeading) {
  const heading = page.getByRole('heading', { level: 1 });
  const tabs = page.getByRole('navigation', { name: navigationLabel, exact: true });
  const view = page.getByRole('heading', { level: 2, name: viewHeading, exact: true });
  await expect(heading).toHaveText(section);
  await expect(tabs).toBeVisible();
  await expect(tabs.locator('a[aria-current="page"]')).toHaveCount(1);
  await expect(view).toBeVisible();
  const positions = await Promise.all([heading, tabs, view].map((locator) => locator.boundingBox()));
  expect(positions[0].y + positions[0].height).toBeLessThanOrEqual(positions[1].y + 1);
  expect(positions[1].y + positions[1].height).toBeLessThanOrEqual(positions[2].y + 1);
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
