import { unpackAPI } from '../support/helpers.mjs';
// Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
// SPDX-License-Identifier: Apache-2.0
import { test, expect } from '@playwright/test';
import { checkpoint, connected, incidentNavigation, keyboardSubmit, mode, sectionTabs, setFilter, reconnect } from '../support/helpers.mjs';

async function coverage(request, filters = {}) {
  const response = await request.get(`/api/v1/coverage?${new URLSearchParams(filters)}`);
  expect(response.ok(), await response.text()).toBeTruthy();
  return response.json().then(unpackAPI);
}

async function observers(request, id) {
  const response = await request.get(`/api/v1/coverage/${id}/observers`);
  expect(response.ok(), await response.text()).toBeTruthy();
  return (await response.json().then(unpackAPI)).items;
}

async function scopeInState(request, predicate, status) {
  let scope;
  await expect.poll(async () => {
    scope = (await coverage(request)).items.find(predicate);
    return scope?.status;
  }, { timeout: 90_000 }).toBe(status);
  return scope;
}

async function reset(request) {
  await mode(request, { webhook: 'ok', offline_installations: [], grouped_samples: {
    'coverage-service-a-staging/elasticsearch': { available: true, used_percent: 40, sample_age_seconds: 0 },
    'coverage-service-b-staging/elasticsearch': { available: true, used_percent: 40, sample_age_seconds: 0 },
  } });
  await expect.poll(async () => (await coverage(request)).total, { timeout: 90_000 }).toBe(5);
  return scopeInState(request, (scope) => scope.environment === 'staging', 'observed');
}

async function filtersFit(page) {
  const input = page.getByRole('combobox');
  await expect(input).toBeVisible();
  const box = await input.boundingBox();
  expect(box.x).toBeGreaterThanOrEqual(0);
  expect(box.x + box.width).toBeLessThanOrEqual(page.viewportSize().width + 1);
}

test('never-installed and excluded scopes remain visible through chip filtering and stacked inspection', async ({page, request}, testInfo) => {
  await reset(request);
  await page.goto('/coverage');
  await connected(page);
  await sectionTabs(page, 'Coverage');
  await incidentNavigation(page, request);
  await expect(page.getByRole('table', {name: 'Declared results', exact: true}).locator('tbody > tr')).toHaveCount(5);
  await filtersFit(page);
  await checkpoint(page, testInfo, 'declared-scopes-desktop');
  await setFilter(page, 'environment', 'production');
  await setFilter(page, 'status', 'attention');
  await expect(page.getByRole('table', {name: 'Declared results', exact: true}).locator('tbody > tr')).toHaveCount(2);
  const missing = (await coverage(request, {environment: 'production', status: 'missing'})).items.find(scope => scope.source_key === 'root-disk-node-b');
  expect(missing.counts.selected).toBe(0);
  const filteredURL = page.url();
  await page.locator(`#open-coverage-${missing.id}`).click();
  await expect(page.locator('#overview-panel')).toContainText('No runner selected');
  await expect(page.locator('#overview-panel')).toContainText('Not selected');
  const identity = page.locator('#overview-panel [id$="preview-coverage-identity"]');
  await identity.locator('summary').click();
  await expect(identity).toContainText('root-disk-node-b');
  const prompt = page.locator('#overview-panel [id$="coverage-agent-prompts-coverage"]');
  await prompt.locator('summary').click();
  await expect(prompt.locator('textarea')).toHaveValue(/root-disk-node-b/);
  await prompt.getByRole('button', {name:'Select text',exact:true}).click();
  expect(await prompt.locator('textarea').evaluate(node => node.selectionEnd - node.selectionStart)).toBeGreaterThan(100);
  await reconnect(page);
  await expect(identity).toHaveAttribute('open', '');
  await checkpoint(page, testInfo, 'missing-node-details');
  await page.setViewportSize({width: 320, height: 760});
  await checkpoint(page, testInfo, 'missing-node-narrow');
  await page.locator('#overview-panel [data-overview-close]').click();
  await expect(page).toHaveURL(filteredURL);
  await expect(page.getByRole('button', {name:/Edit Environment filter: Production/})).toBeVisible();
  await expect(page.getByRole('button', {name:/Edit Coverage filter: Needs attention/})).toBeVisible();
  await filtersFit(page);
  await checkpoint(page, testInfo, 'missing-scopes-narrow');
  await page.goto('/coverage');
  const diagnostics = page.locator('#preview-coverage-runner-diagnostics');
  await diagnostics.locator('summary').click();
  await expect(diagnostics.getByRole('table', {name:'Runner diagnostics',exact:true}).locator('tbody > tr')).toHaveCount(2);
  await diagnostics.locator('a[id^="open-diagnostic-"]').first().click();
  await expect(page.locator('#overview-panel')).toContainText('Why this check is unresolved');
  await checkpoint(page, testInfo, 'unbound-declaration-detail-narrow');
  await page.locator('#overview-panel [data-overview-close]').click();
  await page.goto('/coverage/publishers');
  await connected(page);
  await expect(page.getByRole('heading', {level:1})).toHaveText('Source publications');
  await expect(page.getByRole('table', {name:'Source publications',exact:true}).locator('tbody > tr')).toHaveCount(3);
  await checkpoint(page, testInfo, 'source-publications-narrow');
  await page.reload();
  await reconnect(page);
  await page.setViewportSize({width:390,height:844});
  await checkpoint(page,testInfo,'coverage-publications-after-reload-reconnect-390');
  await page.getByRole('link',{name:'Back to Coverage',exact:true}).click();
  await expect(page.getByRole('heading',{level:1})).toHaveText('Coverage');
});

test('Critical evidence remains covered while independent collection loss stays visible', async ({page,request},testInfo) => {
  let staging=await reset(request);
  await mode(request,{grouped_samples:{'coverage-service-a-staging/elasticsearch':{used_percent:96}}});
  let failing;
  await expect.poll(async()=>{
    failing=(await observers(request,staging.id)).find(observer=>observer.current?.health==='CRIT');
    return failing?.measurement_state;
  },{timeout:60000}).toBe('fresh');
  staging=await scopeInState(request,scope=>scope.id===staging.id,'observed');
  expect(staging.counts.fresh).toBe(2);
  await page.goto(`/coverage/${staging.id}/full`);
  await connected(page);
  await expect(page.locator('#preview-coverage-facts')).toContainText('Reporting');
  await expect(page.getByRole('table',{name:'Runner decisions',exact:true})).toContainText('Reporting');
  await incidentNavigation(page,request);
  await checkpoint(page,testInfo,'critical-is-observed');
  await mode(request,{grouped_samples:{'coverage-service-b-staging/elasticsearch':{available:false}}});
  staging=await scopeInState(request,scope=>scope.id===staging.id,'partial');
  expect(staging.counts.fresh).toBe(1);
  expect(staging.counts.unavailable).toBe(1);
  await expect(page.locator('#preview-coverage-facts')).toContainText('Partial coverage');
  const decisions=page.getByRole('table',{name:'Runner decisions',exact:true});
  await expect(decisions).toContainText('Collection unavailable');
  const failingLabel=failing.runner_label || failing.runner_id;
  await decisions.getByRole('row').filter({hasText:failingLabel}).getByRole('link',{name:'View check result',exact:true}).click();
  await expect(page.locator('#overview-panel .preview-result-measurement')).toContainText('Critical');
  await page.locator('#overview-panel [data-overview-close]').click();
  const unavailable=decisions.getByRole('row').filter({hasText:'Collection unavailable'});
  await unavailable.getByRole('link',{name:'View check result',exact:true}).click();
  await expect(page.locator('#overview-panel section[id$="collection-diagnostics"]')).toContainText('Collection unavailable');
  await page.locator('#overview-panel .preview-result-source').getByRole('link').first().click();
  await expect(page.locator('#overview-panel #runner-detail')).toBeVisible();
  await page.locator('#overview-panel [data-overview-close]').click();
  await expect(page.locator('#overview-panel section[id$="collection-diagnostics"]')).toContainText('Collection unavailable');
  await page.locator('#overview-panel [data-overview-close]').click();
  await expect(page.locator('#coverage-page-body')).toBeVisible();
  await page.setViewportSize({width:320,height:760});
  await checkpoint(page,testInfo,'partial-observers-narrow');
  await reset(request);
  await expect(page.locator('#preview-coverage-facts')).toContainText('Reporting');
  await expect(decisions).not.toContainText('Collection unavailable');
});
