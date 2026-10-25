// Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
// SPDX-License-Identifier: Apache-2.0
import { test, expect } from '@playwright/test';
import fs from 'node:fs';
import path from 'node:path';
import { checkpoint, connected, mode, streams } from '../support/helpers.mjs';
const phase = process.env.MONDEK_DISCOVERY_PHASE || 'operator';
const output = process.env.MONDEK_BROWSER_OUTPUT;
const receiptFile = path.join(path.dirname(output), 'pending-discovery-change.json');
const rows = async request => (await streams(request, {page_size:100})).items;
const get = async (request, id) => (await request.get(`/api/v1/assignments/${id}`)).json();
const locate = (items, observer, label) => items.find(row => row.runner_label === `Observer ${observer}` && row.check_label === label);
async function edit(page, id, scope='local') {
  await page.goto(`/configuration/discovery/${id}`);
  await connected(page);
  await page.locator(`#discovery-scope-${scope}`).check();
}
async function reviewSave(page) {
  await page.locator('#discovery-config-form').getByRole('button',{name:'Review change',exact:true}).click();
  await expect(page.locator('#discovery-config-review')).toBeVisible();
  await page.locator('#save-discovery-change').click();
  await expect(page).toHaveURL(/\/configuration\/discovery\/changes\//);
  await connected(page);
}
async function accepted(page, count=1) {
  await expect(page.getByText('Successful inventory accepted for the reviewed settings',{exact:true})).toHaveCount(count,{timeout:120000});
}

test(`real discovery configuration ${phase}`, async ({page,request},testInfo) => {
  if(phase==='recovery') {
    const saved=JSON.parse(fs.readFileSync(receiptFile,'utf8'));
    await page.goto(saved.url); await connected(page); await accepted(page);
    await expect.poll(async()=>Boolean((await get(request,saved.oldChild)).retired)).toBe(true);
    await page.reload(); await connected(page); await accepted(page);
    await checkpoint(page,testInfo,'receipt-after-real-runner-restart');
    return;
  }
  const all=await rows(request);
  const primary=locate(all,'a1','Interface eth0');
  expect(primary).toBeTruthy();
  const manager=all.find(row=>row.runner_id===primary.runner_id && row.check_label==='Linux resource discovery');
  if(phase==='preview') {
    await page.goto(`/checks/${primary.id}`); await connected(page);
    await page.locator('.page-heading #configure-resource-discovery').click(); await connected(page);
    await expect(page.locator('#discovery-all-values')).not.toHaveAttribute('open');
    await page.locator('#toggle-discovered-resource').click();
    for(const width of [1280,390,320]) {
      await page.setViewportSize({width,height:960});
      await checkpoint(page,testInfo,`focused-discovery-editor-${width}`);
    }
    await page.getByRole('button',{name:'Review change',exact:true}).click();
    await checkpoint(page,testInfo,'focused-discovery-review-320');
    expect((await get(request,manager.assignment_id)).params.interface_exclude).not.toContain('eth0');
    await page.getByRole('button',{name:'Back to editing',exact:true}).click();
    await expect(page.locator('#toggle-discovered-resource')).toContainText('Remove exact exclusion');
    await page.goto('/checks');
    return;
  }
  if(phase==='failure') {
    await edit(page,primary.assignment_id);
    await page.locator('#toggle-discovered-resource').click();
    await reviewSave(page);
    await expect(page.getByText('Inventory refresh failed; previous monitoring is retained. Waiting for a successful retry.',{exact:true})).toBeVisible({timeout:120000});
    expect((await rows(request)).some(row=>row.id===primary.id)).toBe(true);
    await page.setViewportSize({width:320,height:844});
    await checkpoint(page,testInfo,'failed-refresh-retains-critical-membership-320');
    fs.writeFileSync(receiptFile,JSON.stringify({url:new URL(page.url()).pathname,oldChild:primary.assignment_id}));
    return;
  }
  const secondary=locate(all,'a2','Interface eth0');
  const other=locate(all,'b','Interface eth0');
  expect(primary.current.health).toBe('CRIT');
  await page.goto(`/checks/${primary.id}`); await connected(page);
  await page.locator('#configure-resource-discovery').click();
  await expect(page.locator('#discovery-config-subject')).toContainText('Host A');
  await expect(page.locator('#discovery-config-form')).toContainText('2 current observers, plus future compatible observers');
  await page.locator('#toggle-discovered-resource').click();
  for(const width of [1280,390,320]) {
    await page.setViewportSize({width,height:960});
    await checkpoint(page,testInfo,`discovery-editor-${width}`);
  }
  await page.getByRole('button',{name:'Review change',exact:true}).click();
  await checkpoint(page,testInfo,'local-selection-review-320');
  expect((await get(request,manager.assignment_id)).params.interface_exclude).not.toContain('eth0');
  await page.locator('#save-discovery-change').click(); await accepted(page);
  const firstReceipt=page.url();
  await expect.poll(async()=>Boolean((await get(request,primary.assignment_id)).retired)).toBe(true);
  for(const row of [secondary,other]) expect((await rows(request)).some(item=>item.id===row.id)).toBe(true);
  for(const row of all.filter(row=>row.check_label==='Interface wlan0')) expect((await rows(request)).some(item=>item.id===row.id && item.current.health==='OK')).toBe(true);
  await page.setViewportSize({width:1280,height:960});
  await edit(page,primary.assignment_id);
  await page.locator('#toggle-discovered-resource').click(); await reviewSave(page); await accepted(page);
  await expect.poll(async()=>Boolean(locate(await rows(request),'a1','Interface eth0'))).toBe(true);
  const included=locate(await rows(request),'a1','Interface eth0');
  expect(included.id).not.toBe(primary.id);
  await expect.poll(async()=>locate(await rows(request),'a1','Interface eth0').current.knowledge).toBe('fresh');
  await page.goto(firstReceipt); await connected(page); await accepted(page);
  expect((await get(request,primary.assignment_id)).retired).toBe(true);
  await edit(page,included.assignment_id,'host');
  await page.locator('#toggle-discovered-resource').click();
  await reviewSave(page);
  const hostReceipt=page.url();
  await expect(page.getByText('Local override blocks this host policy. Review removing the override separately.',{exact:true})).toBeVisible();
  await page.getByRole('link',{name:'Review local override removal'}).click(); await connected(page);
  await page.locator('#remove-instance-exception').click();
  await page.locator('#exception-reset-form').getByRole('button',{name:'Confirm removal'}).click();
  await page.goto(hostReceipt); await connected(page); await accepted(page,2);
  expect((await rows(request)).some(row=>row.id===other.id)).toBe(true);
  // A deliberate local inclusion while the observer cannot contact the controller.
  await mode(request,{offline_installations:[primary.runner_id]});
  try {
    await edit(page,included.assignment_id,'local');
    await page.locator('#toggle-discovered-resource').click(); await reviewSave(page);
    await expect(page.locator('#discovery-change-receipt')).toContainText('Waiting for runner activation');
    expect(locate(await rows(request),'a1','Interface eth0')).toBeUndefined();
    await page.evaluate(()=>window.liveSocket.disconnect());
    await page.evaluate(()=>window.liveSocket.connect()); await connected(page);
    await expect(page.locator('#discovery-change-receipt')).toContainText('Waiting for runner activation');
    await checkpoint(page,testInfo,'offline-adoption-and-browser-reconnect');
  } finally { await mode(request,{offline_installations:[]}); }
  await accepted(page);
  await expect.poll(async()=>Boolean(locate(await rows(request),'a1','Interface eth0'))).toBe(true);
  const required=locate(await rows(request),'a1','Interface wlan0');
  await edit(page,required.assignment_id);
  await expect(page.locator('#toggle-discovered-resource')).toHaveCount(0);
  await expect(page.locator('body')).toContainText('This resource is required by code');
});
