import { unpackAPI } from '../support/helpers.mjs';
// Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
// SPDX-License-Identifier: Apache-2.0
import {test, expect} from '@playwright/test';
import {reviewedMaintenance, cancelReviewedMaintenance, checkpoint, connected, fixtureURL,
  incidentNavigation, keyboardFill, keyboardSubmit, measured, mode, reconnect, snapshot, streams,
  demoAssignments} from '../support/helpers.mjs';

let filesystemId, httpId, consumerId;
test.beforeEach(async ({request}) => {
  const checks=await demoAssignments(request);
  ({filesystem:{id:filesystemId},http:{id:httpId},consumer:{id:consumerId}}=checks);
  const filesystem=checks.filesystem;
  const response=await request.put(`/api/v1/assignments/${filesystemId}/configuration`,{data:{revision:filesystem.revision,
    params:{...filesystem.params,warn_percent:99,crit_percent:100}}});
  expect(response.ok(),await response.text()).toBe(true);
  await measured(request,filesystemId);
});
const form=page=>page.locator('#preview-incident-ack-form');
const active=page=>page.getByRole('table',{name:'Active acknowledgement',exact:true});
const row=(page,id)=>page.locator(`#preview-incident-health-${id}`);
async function replace(page) {
  await page.getByRole('button',{name:'Replace acknowledgement',exact:true}).click();
  await expect(form(page)).toBeVisible();
}
async function save(page) {
  await keyboardSubmit(page,form(page).getByRole('button',{name:/^(Save|Replace) acknowledgement$/}));
  await expect(active(page)).toBeVisible();
}
async function acknowledgementFits(page) {
  const layout=await page.locator('[aria-labelledby=preview-ack-heading]').evaluate(section=>{
    const boundary=section.getBoundingClientRect();
    const outside=[...section.querySelectorAll('*')].flatMap(element=>{
      const box=element.getBoundingClientRect();
      return box.width&&(box.left<boundary.left-1||box.right>boundary.right+1)
        ?[{tag:element.tagName,id:element.id,left:box.left,right:box.right}]:[];
    });
    const button=section.querySelector('button[type=submit]');
    return {outside,width:section.clientWidth,scrollWidth:section.scrollWidth,
      submitHeight:button?.getBoundingClientRect().height||0};
  });
  expect(layout.outside,'Acknowledgement controls must fit their own card').toEqual([]);
  expect(layout.scrollWidth).toBeLessThanOrEqual(layout.width+1);
  expect(layout.submitHeight).toBeLessThanOrEqual(88);
}

test('acknowledgements retain reviewed drafts, long deadlines and original held deliveries',async({page,request},testInfo)=>{
  const errors=[];
  page.on('pageerror',error=>errors.push(error.message));
  await mode(request,{ready:true,webhook:'ok'});
  await measured(request,httpId);
  const maintenance=await reviewedMaintenance(request,httpId,7200,'Browser acknowledgement review');
  await mode(request,{ready:false});
  await measured(request,httpId,'CRIT');
  const incident=(await snapshot(request)).incidents.find(item=>item.assignment_id===httpId&&item.status==='open');
  const currentIncident=async()=>(await snapshot(request)).incidents.find(item=>item.id===incident.id);
  const result=(await streams(request)).items.find(item=>item.assignment_id===httpId);
  const listing=await page.context().newPage();
  const overview=await page.context().newPage();
  await overview.goto('/');
  await connected(overview);
  await expect(overview.locator(`#result-row-${result.id}`)).toContainText('Critical');
  await incidentNavigation(overview,request,{health:1,monitoring:0});
  await checkpoint(overview,testInfo,'overview-unacknowledged-result-desktop');
  await overview.locator(`#open-result-${result.id}`).click();
  await expect(overview.locator('#overview-panel')).toBeVisible();
  await overview.locator('#overview-panel [data-overview-close]').click();
  await expect(overview).toHaveURL(url=>url.pathname==='/');
  await listing.goto('/incidents');
  await connected(listing);
  await expect(listing.locator('link[rel=stylesheet]')).toHaveAttribute('href',/\/assets\/preview-[a-f0-9]+\.css\?vsn=d$/);
  await expect(listing.locator('script[src]')).toHaveAttribute('src',/\/assets\/preview-[a-f0-9]+\.js\?vsn=d$/);
  await page.goto(`/incidents/health/${incident.id}/full`);
  await connected(page);
  await expect(form(page).locator('input[name=mode][value=until_incident_ends]')).toBeChecked();
  await keyboardFill(page,form(page).locator('textarea[name=note]'),'Investigating until the incident ends');
  await acknowledgementFits(page);
  await save(page);
  await expect(active(page)).toContainText('Investigating until the incident ends');
  await expect(active(page)).toContainText('Incident ends');
  expect((await currentIncident()).acknowledged_until).toBeNull();
  await checkpoint(page,testInfo,'indefinite-acknowledgement-desktop');
  await expect(row(listing,incident.id)).toContainText('Acknowledged');
  await expect(row(listing,incident.id)).toContainText('Critical');
  await expect(row(listing,incident.id)).toContainText('Open');
  // Acknowledgement changes notification work; measured Critical health stays visible.
  await expect(overview.locator(`#result-row-${result.id}`)).toContainText('Critical');
  await expect(overview.locator(`#preview-open-incidents tr:has(#overview-incident-health-${incident.id})`)).toContainText('Acknowledged');
  await incidentNavigation(overview,request,{health:0,monitoring:0});
  await overview.reload();
  await reconnect(overview);
  await expect(overview.locator(`#result-row-${result.id}`)).toContainText('Critical');
  const retained=(await streams(request)).items.find(item=>item.id===result.id);
  expect(retained.current.health).toBe('CRIT');
  await overview.setViewportSize({width:390,height:844});
  await checkpoint(overview,testInfo,'acknowledged-result-health-retained-390');
  await listing.reload();
  await connected(listing);
  await expect(row(listing,incident.id)).toContainText('Acknowledged');
  await checkpoint(listing,testInfo,'acknowledged-incident-list');

  await replace(page);
  await form(page).locator('input[name=mode][value=duration]').check();
  await form(page).getByLabel('Amount',{exact:true}).fill(String(90*24+3));
  await form(page).getByRole('combobox',{name:'Unit',exact:true}).selectOption('hours');
  await form(page).locator('textarea[name=note]').fill('Long investigation with a reviewed deadline');
  await page.keyboard.press('Tab');
  await reconnect(page);
  await expect(form(page).getByLabel('Amount',{exact:true})).toHaveValue(String(90*24+3));
  await expect(form(page).getByRole('combobox',{name:'Unit',exact:true})).toHaveValue('hours');
  await expect(form(page).locator('textarea[name=note]')).toHaveValue('Long investigation with a reviewed deadline');
  const concurrentBase=await currentIncident();
  const concurrent=await request.post(`/api/v1/incidents/health/${incident.id}/acknowledge`,{data:{mode:'duration',seconds:604800,
    note:'Concurrent one-week acknowledgement',revision:concurrentBase.acknowledgement_revision,
    attention_revision:concurrentBase.attention_revision}});
  expect(concurrent.ok(),await concurrent.text()).toBe(true);
  await expect(form(page).getByRole('button',{name:'Replace acknowledgement',exact:true})).toBeDisabled();
  await expect(active(page)).toContainText('Concurrent one-week acknowledgement');
  await expect(form(page).getByLabel('Amount',{exact:true})).toHaveValue(String(90*24+3));
  await page.setViewportSize({width:390,height:844});
  await acknowledgementFits(page);
  await checkpoint(page,testInfo,'stale-acknowledgement-review-mobile');
  await form(page).getByRole('button',{name:'Review current incident',exact:true}).click();
  await expect(form(page).locator('textarea[name=note]')).toHaveValue('Long investigation with a reviewed deadline');
  const beforeLongSave=Date.now();
  await save(page);
  await expect.poll(async()=>(await currentIncident()).acknowledgement_note).toBe('Long investigation with a reviewed deadline');
  const longDeadline=Date.parse((await currentIncident()).acknowledged_until);
  const duration=(90*86400+3*3600)*1000;
  expect(longDeadline).toBeGreaterThanOrEqual(beforeLongSave+duration);
  expect(longDeadline).toBeLessThanOrEqual(Date.now()+duration);
  await acknowledgementFits(page);
  await checkpoint(page,testInfo,'long-acknowledgement-mobile');
  await replace(page);
  await form(page).locator('input[name=mode][value=until]').check();
  const expiry=new Date(Date.now()+86400000).toISOString().slice(0,16);
  await form(page).getByLabel('Date and time (UTC)',{exact:true}).fill(expiry);
  await form(page).locator('textarea[name=note]').fill('Explicit UTC expiry checked in the browser');
  await page.setViewportSize({width:320,height:740});
  await acknowledgementFits(page);
  await checkpoint(page,testInfo,'explicit-UTC-expiry-320');
  await save(page);
  await expect.poll(async()=>Date.parse((await currentIncident()).acknowledged_until)).toBe(Date.parse(`${expiry}Z`));
  await expect(active(page)).toContainText('Local operator');
  await page.getByRole('button',{name:'End acknowledgement',exact:true}).click();
  await expect(active(page)).toHaveCount(0);
  await expect(row(listing,incident.id)).not.toContainText('Acknowledged');
  await expect(overview.locator(`#preview-open-incidents tr:has(#overview-incident-health-${incident.id})`)).toContainText('Unacknowledged');
  await incidentNavigation(overview,request,{health:1,monitoring:0});
  await overview.setViewportSize({width:320,height:740});
  await checkpoint(overview,testInfo,'ended-acknowledgement-work-restored-320');
  await overview.close();
  await checkpoint(listing,testInfo,'incident-attention-restored');
  await listing.close();
  const delivery=page.locator('section[aria-labelledby=preview-delivery-heading]');
  await expect(delivery).toContainText('Maintenance');
  await page.locator(`#preview-operator-history-${incident.id} > summary`).click();
  await expect(page.locator(`#preview-operator-history-${incident.id}`)).toContainText('Explicit UTC expiry checked in the browser');
  const held=(await snapshot(request)).occurrences.find(item=>item.incident_id===incident.id&&item.kind==='firing');
  expect(held.attempt_count).toBe(0);
  await cancelReviewedMaintenance(request,maintenance,'Finished browser review');
  await expect(delivery).toContainText('Receiver accepted',{timeout:30000});
  const delivered=(await snapshot(request)).occurrences.find(item=>item.id===held.id);
  expect(delivered.payload).toEqual(held.payload);
  expect(delivered.attempt_count).toBe(1);
  const receipts=await(await request.get(`${fixtureURL}/records`)).json().then(unpackAPI);
  expect(receipts.records.some(item=>item.payload.occurrence_id===held.id)).toBe(true);
  await page.setViewportSize({width:1280,height:900});
  await form(page).locator('input[name=mode][value=until_incident_ends]').check();
  await form(page).locator('textarea[name=note]').fill('Waiting for confirmed recovery');
  await save(page);
  await mode(request,{ready:true});
  await measured(request,httpId);
  await expect(page.locator('#incident-page')).toContainText('Measured recovery');
  await expect(form(page)).toHaveCount(0);
  await expect(page.locator('[aria-labelledby=preview-ack-heading]')).toContainText('This incident has ended');
  await expect(page.locator(`#preview-operator-history-${incident.id}`)).toContainText('Waiting for confirmed recovery');
  await checkpoint(page,testInfo,'recovery-ends-acknowledgement-history-retained');
  expect(errors).toEqual([]);
  await testInfo.attach('final-state',{body:JSON.stringify(await snapshot(request),null,2),contentType:'application/json'});
});

test('unacknowledged warning precedes acknowledged Critical through reload and reconnect',async({page,request},testInfo)=>{
  // Establish a new episode even if the preceding journey failed while acknowledged.
  await mode(request,{ready:true,backlog:2,processing_enabled:true});
  await measured(request,httpId);
  await measured(request,consumerId);
  await mode(request,{ready:false,backlog:6,processing_enabled:true});
  await measured(request,httpId,'CRIT');
  await measured(request,consumerId,'WARN');
  const incidents=(await snapshot(request)).incidents.filter(item=>item.status==='open');
  const critical=incidents.find(item=>item.assignment_id===httpId);
  const warning=incidents.find(item=>item.assignment_id===consumerId);
  const rows=()=>page.getByRole('table',{name:'Incidents',exact:true}).locator('tbody > tr').evaluateAll(items=>items.map(item=>item.id));
  await page.goto('/incidents');
  await connected(page);
  await expect.poll(rows).toEqual([`preview-incident-health-${critical.id}`,`preview-incident-health-${warning.id}`]);
  await incidentNavigation(page,request,{health:2,monitoring:0});
  await row(page,critical.id).getByRole('link').first().click();
  await form(page).locator('textarea[name=note]').fill('Already investigating this critical incident');
  await save(page);
  await page.locator('#overview-panel [data-overview-close]').click();
  await expect.poll(rows).toEqual([`preview-incident-health-${warning.id}`,`preview-incident-health-${critical.id}`]);
  await incidentNavigation(page,request,{health:1,monitoring:0});
  await checkpoint(page,testInfo,'warning-before-acknowledged-critical');
  await page.reload();
  await reconnect(page);
  await expect.poll(rows).toEqual([`preview-incident-health-${warning.id}`,`preview-incident-health-${critical.id}`]);
  for(const width of [390,320]) {
    await page.setViewportSize({width,height:844});
    await expect(page.getByRole('table',{name:'Incidents',exact:true}).locator('thead th')).toHaveCount(5);
    await checkpoint(page,testInfo,`acknowledged-list-${width}`);
  }
  await page.setViewportSize({width:1280,height:900});
  await row(page,critical.id).getByRole('link').first().click();
  await page.getByRole('button',{name:'End acknowledgement',exact:true}).click();
  await expect(active(page)).toHaveCount(0);
  await page.locator('#overview-panel [data-overview-close]').click();
  await expect.poll(rows).toEqual([`preview-incident-health-${critical.id}`,`preview-incident-health-${warning.id}`]);
  await incidentNavigation(page,request,{health:2,monitoring:0});
  await mode(request,{ready:true,backlog:2});
  await measured(request,httpId);
  await measured(request,consumerId);
  await incidentNavigation(page,request,{health:0,monitoring:0});
});
