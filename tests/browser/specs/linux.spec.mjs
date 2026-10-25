// Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
// SPDX-License-Identifier: Apache-2.0
import { test, expect } from '@playwright/test';
import { checkpoint, connected, streams } from '../support/helpers.mjs';

test('Linux pack groups, measurements and shared code policy on two runners', async ({ page, request }, testInfo) => {
  const items = (await streams(request, { page_size: 100 })).items;
  expect(items).toHaveLength(9);
  const memory = items.find(row => row.target.key === 'host:linux-fixture' && row.check_label.includes('memory'));
  expect(memory).toBeTruthy();
  await page.goto('/checks?view=targets');
  await connected(page);
  await expect(page.locator('body')).toContainText('Linux native');
  await expect(page.locator('body')).toContainText('Linux fixture');
  await checkpoint(page, testInfo, 'linux-host-groups');
  await page.goto(`/checks/${memory.id}`);
  await connected(page);
  await expect(page.getByRole('heading', {level: 1})).toHaveText('Linux memory');
  await expect(page.locator('body')).toContainText('Memory 50.0% used');
  await expect(page.locator('body')).toContainText('MemAvailable');
  await checkpoint(page, testInfo, 'linux-memory-evidence');
  await page.goto(`/configuration/${memory.assignment_id}`);
  await connected(page);
  await expect(page.locator('[name="params[warning]"]')).toHaveValue('80');
  // One source-owned contract makes policy apply to both hosts, including future hosts.
  const manifest = { version: 1, project: 'linux-acceptance', rules: [{ key: 'memory', name: 'Fleet memory limits', source_id: 'linux-pack-example', parameter_contract: 'mondek.linux.memory.v1', params: { warning: 30, critical: 40 } }] };
  let response = await request.post('/api/v1/configuration/policy/plan', { data: { manifest } });
  expect(response.ok(), await response.text()).toBeTruthy();
  const plan = await response.json();
  response = await request.post('/api/v1/configuration/policy/apply', { data: { manifest, review_token: plan.review_token } });
  expect(response.ok(), await response.text()).toBeTruthy();
  await expect.poll(async () => {
    const rows = (await streams(request, { page_size: 100 })).items;
    return rows.find(row => row.id === memory.id).current.health;
  }, {timeout: 120000}).toBe('CRIT');
  for (const row of items.filter(row => row.check_label.includes('memory'))) {
    const assignment = await (await request.get(`/api/v1/assignments/${row.assignment_id}`)).json();
    expect(assignment.params).toEqual({warning: 30, critical: 40});
  }
  await page.reload();
  await connected(page);
  await expect(page.locator('#configuration-origin')).toContainText('Fleet memory limits');
  await page.setViewportSize({width: 390, height: 844});
  await checkpoint(page, testInfo, 'linux-shared-policy-mobile');
  await page.evaluate(() => window.liveSocket.disconnect());
  await page.evaluate(() => window.liveSocket.connect());
  await connected(page);
  await expect(page.locator('[name="params[critical]"]')).toHaveValue('40');
  const empty = {...manifest, rules: []};
  // Deliberate fixture removal: production callers must review intervening edits first.
  const revision = await (await request.get('/api/v1/configuration/revision')).json();
  response = await request.post('/api/v1/configuration/policy/plan', {data: {manifest: empty, base_head: revision.head}});
  expect(response.ok(), await response.text()).toBeTruthy();
  const removal = await response.json();
  response = await request.post('/api/v1/configuration/policy/apply', {data: {manifest: empty, review_token: removal.review_token}});
  expect(response.ok(), await response.text()).toBeTruthy();
  await expect.poll(async () => (await streams(request, {page_size:100})).items.find(row => row.id === memory.id).current.health, {timeout:120000}).toBe('OK');

  // Selection is an ordinary shared contract, configured in the real UI.
  const discovery = items.find(row => row.check_label === 'Linux resource discovery');
  expect(discovery).toBeTruthy();
  await page.setViewportSize({width: 1280, height: 900});
  await page.goto(`/configuration/${discovery.assignment_id}`);
  await connected(page);
  await page.getByRole('link', {name: 'Configure similar checks', exact: true}).click();
  await page.locator('#rule-name').fill('Ignore transient fixture resources');
  await page.locator('#rule-param-filesystem_exclude').fill('/data*');
  await page.locator('#rule-param-interface_exclude').fill('lo,veth*,br-*');
  await page.getByRole('button', {name: 'Preview rule', exact: true}).click();
  await expect(page.locator('#rule-preview-summary')).toContainText('1 checks reviewed');
  await checkpoint(page, testInfo, 'linux-discovery-selection-preview');
  await page.getByRole('button', {name: 'Save rule', exact: true}).click();
  await expect(page).toHaveURL(/\/configuration\/rules\/[0-9a-f-]{36}$/);
  await expect.poll(async () => {
    const assignment = await (await request.get(`/api/v1/assignments/${discovery.assignment_id}`)).json();
    return assignment.params.filesystem_exclude;
  }).toBe('/data*');
  await page.setViewportSize({width: 390, height: 844});
  await checkpoint(page, testInfo, 'linux-discovery-selection-mobile');
  await page.evaluate(() => window.liveSocket.disconnect());
  await page.evaluate(() => window.liveSocket.connect());
  await connected(page);
  await expect(page.locator('#rule-param-filesystem_exclude')).toHaveValue('/data*');
});
