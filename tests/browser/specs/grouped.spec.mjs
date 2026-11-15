import { unpackAPI } from '../support/helpers.mjs';
// Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
// SPDX-License-Identifier: Apache-2.0
import { test, expect } from '@playwright/test';
import { checkpoint, connected, fixtureURL, keyboardSubmit, mode, streams } from '../support/helpers.mjs';

const volumeKey = 'node-a/volume';
const elasticKey = 'service-a/elasticsearch';

async function samples(request, volume = {}, elastic = {}) {
  await mode(request, { grouped_samples: { [volumeKey]: volume, [elasticKey]: elastic } });
}

async function measured(request, source, health, knowledge = 'fresh') {
  let result;
  await expect.poll(async () => {
    result = (await streams(request)).items.find((row) => row.source_id === source);
    return result?.current?.health === health && result?.current?.knowledge === knowledge;
  }, { message: `${source} must report its own ${knowledge} ${health} evidence`, timeout: 60_000 }).toBe(true);
  return result;
}

async function incidents(request, filters = {}) {
  const response = await request.get(`/api/v1/incidents/health?${new URLSearchParams(filters)}`);
  expect(response.ok(), await response.text()).toBe(true);
  return response.json().then(unpackAPI);
}

async function detail(request, id, filters = {}) {
  const response = await request.get(`/api/v1/incidents/health/${id}?${new URLSearchParams(filters)}`);
  expect(response.ok(), await response.text()).toBe(true);
  return response.json().then(unpackAPI);
}

async function reset(request) {
  await mode(request, { webhook: 'ok', offline_installations: [] });
  const healthy = { used_percent: 40, writes_blocked: false, available: true, sample_age_seconds: 0 };
  await samples(request, healthy, healthy);
  await measured(request, 'linux-volume-monitoring', 'OK');
  await measured(request, 'elasticsearch-monitoring', 'OK');
  await expect.poll(async () => (await incidents(request)).total).toBe(0);
}

async function opened(request, count) {
  let group;
  await expect.poll(async () => {
    const list = await incidents(request);
    group = list.items[0];
    return list.total === 1 && group.incident_kind === 'condition' && group.open_contribution_count === count;
  }).toBe(true);
  return group;
}

const ackForm=page=>page.locator('#preview-incident-ack-form');
const activeAck=page=>page.getByRole('table',{name:'Active acknowledgement',exact:true});
const contributors=page=>page.getByRole('table',{name:'Contributing results',exact:true});
const contributorRows=page=>contributors(page).locator(':scope > tbody > tr');
async function acknowledge(page,note) {
  await ackForm(page).locator('textarea[name=note]').fill(note);
  await keyboardSubmit(page,ackForm(page).getByRole('button',{name:/^(Save|Replace) acknowledgement$/}));
  await expect(activeAck(page)).toContainText(note);
}
async function reconnect(page) {
  await page.evaluate(()=>window.liveSocket.disconnect());
  await expect(page.locator('[data-phx-main]')).not.toHaveClass(/phx-connected/);
  await page.evaluate(()=>window.liveSocket.connect());
  await connected(page);
}
const incidentPage=id=>`/incidents/health/${id}/full`;

test('shared incident retains independent evidence and reviewed acknowledgement through corroboration',async({page,request},testInfo)=>{
  const errors=[]; page.on('pageerror',error=>errors.push(error.message));
  await reset(request);
  await samples(request,{used_percent:96});
  const volume=await measured(request,'linux-volume-monitoring','CRIT');
  const group=await opened(request,1);
  await page.goto(incidentPage(group.id)); await connected(page);
  await expect(page.locator('#incident-heading')).toContainText('Search storage capacity');
  await expect(contributorRows(page)).toHaveCount(1);
  await expect(page.locator(`#preview-confirmed-healthy-${group.id}`)).toContainText('Last confirmed healthy results');
  await ackForm(page).locator('textarea[name=note]').fill('Reviewing independent storage evidence');
  await samples(request,{}, {used_percent:92});
  const elastic=await measured(request,'elasticsearch-monitoring','WARN');
  expect((await opened(request,2)).id).toBe(group.id);
  await expect(contributorRows(page)).toHaveCount(2);
  await expect(ackForm(page).locator('textarea[name=note]')).toHaveValue('Reviewing independent storage evidence');
  await expect(ackForm(page).getByRole('button',{name:'Save acknowledgement',exact:true})).toBeEnabled();
  await reconnect(page);
  await expect(ackForm(page).locator('textarea[name=note]')).toHaveValue('Reviewing independent storage evidence');
  await acknowledge(page,'Reviewing independent storage evidence');
  await expect(page.getByRole('table',{name:'Shared incident summary',exact:true})).toContainText('Unpaused for 0 of 2');
  await expect(contributors(page)).toContainText('Paused by shared acknowledgement');
  await checkpoint(page,testInfo,'shared-incident-independent-evidence-desktop');
  const before=await detail(request,group.id);
  const contribution=before.contributions.find(row=>row.incident.stream_id===volume.id);
  await page.goto(incidentPage(contribution.incident.id)); await connected(page);
  await expect(page.getByRole('link',{name:'Open shared incident and its notifications',exact:true})).toBeVisible();
  await expect(ackForm(page)).toContainText('this result’s health incident');
  const history=page.locator(`#preview-measurements-${contribution.incident.id}`);
  await history.locator(':scope > summary').click();
  await expect(history).toContainText('Search data volume is 96% used');
  await expect(history).toContainText('Critical');
  const recorded=history.locator(`[data-observation-id="${contribution.incident.opening_observation_id}"]`);
  await expect(recorded).toBeVisible();
  await recorded.getByText('Timing and identity',{exact:true}).click();
  await expect(recorded.getByRole('table',{name:'Historical measurement identity',exact:true}))
    .toContainText(contribution.incident.opening_observation_id);
  await checkpoint(page,testInfo,'individual-contribution-evidence-and-shared-history');
  await page.getByRole('link',{name:'Open shared incident and its notifications',exact:true}).click();
  await expect(page.locator('#overview-panel')).toContainText('Search storage capacity');
  await expect(page.locator('#overview-panel section[aria-labelledby=preview-delivery-heading]')).toContainText('Critical severity');
  await page.goto(`/incidents?runner_id=${elastic.runner_id}`); await connected(page);
  const matching=await incidents(request,{runner_id:elastic.runner_id});
  expect(matching.total).toBe(1);
  expect(matching.items[0].health).toBe('CRIT');
  expect(matching.items[0].matching_result_count).toBe(1);
  const link=page.getByRole('link',{name:'Search storage capacity',exact:true});
  await expect(link).toHaveCount(1);
  await expect(link.locator('xpath=ancestor::tr')).toContainText('Critical');
  await expect(link.locator('xpath=ancestor::tr')).toContainText('Shared incident · 2 members');
  await page.setViewportSize({width:390,height:844});
  await checkpoint(page,testInfo,'shared-incident-filtered-list-mobile');
  await link.click();
  await expect(contributorRows(page)).toHaveCount(2);
  const maintenance=page.locator('#overview-panel').getByRole('link',{name:'Schedule maintenance',exact:true});
  expect(new URL(await maintenance.getAttribute('href'),'http://localhost').pathname).toBe('/maintenance/new');
  await page.setViewportSize({width:320,height:740});
  const order=await page.evaluate(()=>({
    evidence:document.querySelector('#overview-panel table[aria-label="Contributing results"]').getBoundingClientRect().top,
    controls:document.querySelector('#overview-panel [aria-labelledby=preview-ack-heading]').getBoundingClientRect().top,
  }));
  expect(order.evidence).toBeLessThan(order.controls);
  await page.locator('#overview-panel [aria-labelledby=preview-ack-heading]').scrollIntoViewIfNeeded();
  await checkpoint(page,testInfo,'shared-incident-acknowledgement-320');
  expect(errors).toEqual([]); await reset(request);
});

test('maintained new impact ends shared acknowledgement and preserves independent recovery history',async({page,request},testInfo)=>{
  await reset(request); await samples(request,{used_percent:96},{used_percent:96});
  const volume=await measured(request,'linux-volume-monitoring','CRIT');
  const elastic=await measured(request,'elasticsearch-monitoring','CRIT');
  const group=await opened(request,2);
  await page.goto(`/maintenance/new?check_id=${elastic.assignment_id}`); await connected(page);
  await page.locator('#maintenance-name').fill('Elasticsearch storage work');
  await page.locator('#maintenance-reason').fill('Only the service-side observer is maintained');
  await page.locator('#maintenance-preview-button').click();
  await expect(page.locator('#maintenance-preview-summary')).toContainText('1 result');
  await page.locator('#maintenance-save').click();
  await expect(page.locator('#maintenance-saved')).toContainText('Active');
  const maintenanceURL=page.url();
  await page.goto(incidentPage(group.id)); await connected(page);
  await acknowledge(page,'Reviewing capacity while service maintenance continues');
  await samples(request,{}, {writes_blocked:true});
  await expect.poll(async()=>(await detail(request,group.id)).incident.impacts.map(impact=>impact.key)).toEqual(['writes-blocked']);
  await expect(activeAck(page)).toHaveCount(0);
  await expect(page.getByRole('table',{name:'Shared incident summary',exact:true})).toContainText('Search index writes are blocked');
  await expect(page.getByRole('table',{name:'Shared incident summary',exact:true})).toContainText('Unpaused for 1 of 2');
  await expect(contributors(page)).toContainText('Elasticsearch storage work');
  const current=await detail(request,group.id);
  const impact=current.occurrences.find(notice=>notice.payload.requested_fact?.key==='writes-blocked');
  expect(impact.gates).toContain('maintenance'); expect(impact.attempt_count).toBe(0);
  await page.setViewportSize({width:390,height:844});
  await checkpoint(page,testInfo,'new-impact-partial-maintenance-mobile');
  const review=ackForm(page).getByRole('button',{name:'Review current incident',exact:true});
  await expect(ackForm(page).getByRole('button',{name:'Save acknowledgement',exact:true})).toBeDisabled();
  await expect(review).toBeVisible();
  await review.click();
  await expect(ackForm(page).locator('.preview-ack-reviewed-scope')).toContainText('Search index writes are blocked');
  await page.goto(maintenanceURL); await connected(page);
  await page.locator('#maintenance-cancel').click();
  await page.locator('#maintenance-cancel-reason').fill('Service-side storage work completed');
  await page.locator('#maintenance-confirm-cancel').click();
  await expect(page.locator('#maintenance-saved')).toContainText('Ended early');
  await expect.poll(async()=>(await detail(request,group.id,{notification_status:'all'})).occurrences.find(notice=>notice.id===impact.id)?.status).toBe('delivered');
  const receipts=await(await request.get(`${fixtureURL}/records`)).json().then(unpackAPI);
  expect(receipts.records.some(receipt=>receipt.payload.occurrence_id===impact.id)).toBe(true);
  await samples(request,{available:false});
  await measured(request,'linux-volume-monitoring','CRIT','unavailable');
  await page.goto(incidentPage(group.id)); await connected(page);
  await expect(contributors(page)).toContainText('Collection unavailable');
  expect((await detail(request,group.id)).counts.open).toBe(2);
  await samples(request,{available:true,used_percent:40});
  await measured(request,'linux-volume-monitoring','OK');
  await expect.poll(async()=>(await detail(request,group.id)).counts.open).toBe(1);
  await page.getByRole('link',{name:'Show historical contributors',exact:true}).click();
  await expect(contributors(page)).toContainText('Recovered');
  await page.setViewportSize({width:1280,height:800});
  await checkpoint(page,testInfo,'partial-recovery-retained-contribution');
  await reset(request); await page.goto(incidentPage(group.id)); await connected(page);
  await expect(page.locator('#incident-page')).toContainText('Measured recovery');
  await samples(request,{used_percent:96});
  const recurringVolume=await measured(request,'linux-volume-monitoring','CRIT');
  const recurrence=await opened(request,1);
  expect(recurrence.id).not.toBe(group.id);
  expect((await detail(request,recurrence.id)).incident.acknowledgement_mode).toBeNull();
  await expect(page.locator('#incident-page')).toContainText('Measured recovery');
  await checkpoint(page,testInfo,'closed-episode-does-not-borrow-recurrence');
  const closed=await detail(request,group.id,{state:'history'});
  const closedVolume=closed.contributions.find(row=>row.incident.stream_id===volume.id);
  await page.goto(incidentPage(closedVolume.incident.id)); await connected(page);
  const history=page.locator(`#preview-measurements-${closedVolume.incident.id}`);
  await history.locator(':scope > summary').click();
  await expect(history).toContainText('Search data volume is 96% used');
  await expect(history).toContainText('Search data volume is 40% used');
  expect(recurringVolume.current.confirmed_observation_id).toMatch(/^[0-9a-f-]{36}$/);
  const retained=await detail(request,closedVolume.incident.id);
  // The API can also supply explicitly separate recent execution evidence. The
  // closed episode's authoritative references and measurement history stay historical.
  expect(retained.incident.status).toBe('closed');
  expect(retained.incident.opening_observation_id).not.toBe(recurringVolume.current.confirmed_observation_id);
  expect(retained.incident.closing_observation_id).not.toBe(recurringVolume.current.confirmed_observation_id);
  expect(retained.evidence.some(report=>report.id===retained.incident.closing_observation_id)).toBe(true);
  await expect(history.locator(`[data-observation-id="${recurringVolume.current.confirmed_observation_id}"]`)).toHaveCount(0);
  await reset(request);
});

test('contributor history pages retain exact reviewed drafts through reconnect',async({page,request},testInfo)=>{
  await reset(request); await samples(request,{used_percent:96});
  await measured(request,'linux-volume-monitoring','CRIT');
  const group=await opened(request,1);
  await page.goto(incidentPage(group.id)); await connected(page);
  await acknowledge(page,'Shared condition remains under investigation');
  for(let index=0;index<26;index+=1) {
    await samples(request,{}, {used_percent:96}); await measured(request,'elasticsearch-monitoring','CRIT');
    await samples(request,{}, {used_percent:40}); await measured(request,'elasticsearch-monitoring','OK');
  }
  const populated=await detail(request,group.id);
  expect(populated.counts.total).toBe(27); expect(populated.counts.open).toBe(1);
  expect(populated.counts.recovered).toBe(26);
  expect(populated.incident.acknowledgement_mode).toBe('until_incident_ends');
  expect((await incidents(request)).total).toBe(1);
  await page.getByRole('button',{name:'Replace acknowledgement',exact:true}).click();
  await ackForm(page).locator('input[name=mode][value=duration]').check();
  await ackForm(page).getByLabel('Amount',{exact:true}).fill('14');
  await ackForm(page).getByRole('combobox',{name:'Unit',exact:true}).selectOption('days');
  await ackForm(page).locator('textarea[name=note]').fill('Preserve this reviewed draft through contribution pages');
  await page.getByRole('link',{name:'Show historical contributors',exact:true}).click();
  await expect(contributorRows(page)).toHaveCount(25);
  await page.getByRole('navigation',{name:'Contributing result pages'}).getByRole('link',{name:'Next',exact:true}).click();
  await expect(contributorRows(page)).toHaveCount(1);
  await expect(ackForm(page).getByLabel('Amount',{exact:true})).toHaveValue('14');
  await expect(ackForm(page).locator('textarea[name=note]')).toHaveValue('Preserve this reviewed draft through contribution pages');
  await reconnect(page);
  await expect(contributorRows(page)).toHaveCount(1);
  await expect(ackForm(page).getByLabel('Amount',{exact:true})).toHaveValue('14');
  await expect(ackForm(page).locator('textarea[name=note]')).toHaveValue('Preserve this reviewed draft through contribution pages');
  await page.setViewportSize({width:320,height:740});
  await checkpoint(page,testInfo,'bounded-contribution-history-reconnect-320');
  await page.getByLabel('Delivery status',{exact:true}).selectOption('all');
  await expect(ackForm(page).getByLabel('Amount',{exact:true})).toHaveValue('14');
  const after=await detail(request,group.id,{notification_status:'all'});
  expect(after.notification_counts.total).toBe(populated.notification_counts.total);
  await reset(request);
});

test('incident fly-overs preserve the earlier panels and hand off a real pointer reveal', async ({ page, request }) => {
  const preview = await request.get('/incidents');
  expect(preview.ok()).toBe(true);

  const errors = [];
  page.on('pageerror', (error) => errors.push(error.message));
  await reset(request);
  await samples(request, { used_percent: 96 }, { used_percent: 92 });
  const volume = await measured(request, 'linux-volume-monitoring', 'CRIT');
  await measured(request, 'elasticsearch-monitoring', 'WARN');
  const group = await opened(request, 2);
  const groupDetail = await detail(request, group.id);
  const memberId = groupDetail.contributions.find(item => item.incident.stream_id === volume.id).incident.id;
  await page.setViewportSize({ width: 1280, height: 720 });
  await page.goto('/incidents');
  await connected(page);

  const panel = page.locator('#overview-panel');
  const trail = page.getByRole('navigation', { name: 'Earlier panels' });
  // Observe the first render at each depth. Reading only after Playwright's
  // stability checks could miss a short animation entirely.
  await page.evaluate(() => {
    window.stackMotion = [];
    let previous;
    const observer = new MutationObserver(() => {
      const panel = document.querySelector('#overview-panel');
      const path = panel?.dataset.panelPath;
      if (!path || path === previous) return;
      previous = path;
      const settled = document.documentElement.clientWidth - panel.offsetWidth;
      window.stackMotion.push({ path, start: panel.getBoundingClientRect().left - settled });
    });
    observer.observe(document.querySelector('#incidents-preview'), {
      attributes: true, attributeFilter: ['data-panel-path'], childList: true, subtree: true,
    });
  });
  const groupOpener = page.getByRole('link', { name: 'Search storage capacity', exact: true });
  await groupOpener.click();
  await expect(panel).toHaveAttribute('data-panel-path', new RegExp(group.id));
  const entryMotion = await page.evaluate(() => window.stackMotion[0]?.start);
  expect(entryMotion).toBeGreaterThan(0);
  const memberOpener = panel.getByRole('link', { name: 'Search volume used space', exact: true });
  await memberOpener.click();

  const resultOpener = panel.getByRole('link', { name: /View latest check result/ });
  const history = panel.locator('details').filter({ has: page.getByText('Measurement history', { exact: true }) });
  await expect(resultOpener).toBeVisible();
  await history.locator(':scope > summary').click();
  await expect(history).toHaveAttribute('open', '');
  // Activating the focused link by keyboard lets us leave the panel scrolled.
  await resultOpener.focus();
  const scrollBefore = await panel.evaluate((el) => {
    el.scrollTop = 125;
    return el.scrollTop;
  });
  expect(scrollBefore).toBeGreaterThan(0);
  await page.keyboard.press('Enter');
  await expect(panel.getByRole('heading', { name: volume.label === volume.check_label ? volume.label : `${volume.check_label} · ${volume.label}`, exact: true })).toBeVisible();
  const resultUrl = page.url();
  const ancestorLink = async token => {
    const links = trail.locator('a.preview-panel-back-hit');
    let position;
    await expect.poll(async () => {
      position = await links.evaluateAll((nodes, identity) => nodes.findIndex(node => {
        const destination = new URL(node.href);
        const selected = destination.searchParams.get('inspect');
        return selected ? selected.split(',').at(-1) === identity
          : destination.pathname.endsWith('/' + identity.split(':')[1]);
      }), token);
      return position >= 0;
    }).toBe(true);
    return links.nth(position);
  };
  const sharedBack = await ancestorLink(`health:${group.id}`);
  const memberBack = await ancestorLink(`health:${memberId}`);
  await expect(sharedBack).toHaveAttribute('aria-label', 'Return to Shared incident: Search storage capacity');
  await expect(memberBack).toHaveAttribute('aria-label', 'Return to Health incident: Search volume capacity');
  const sharedCard = sharedBack.locator('..');
  const memberCard = memberBack.locator('..');
  const sharedCopy = sharedCard.locator('.preview-panel-snapshot');
  const memberCopy = memberCard.locator('.preview-panel-snapshot');
  await expect(sharedCopy).toContainText('Contributing results');
  await expect(memberCopy.locator('details').filter({ hasText: 'Measurement history' })).toHaveAttribute('open', '');
  await expect.poll(() => memberCopy.evaluate((el) => el.scrollTop)).toBe(scrollBefore);

  // Traverse both exposed edges quickly. Passing over them must not reveal either card.
  const ready = async (locator, predicate) => expect.poll(async () => {
    const bounds = await locator.boundingBox();
    return bounds && predicate(bounds);
  }).toBeTruthy();
  await expect.poll(() => panel.evaluate(el => getComputedStyle(el).transform)).toBe('none');
  const initialShared = await sharedBack.boundingBox();
  const initialMember = await memberBack.boundingBox();
  await page.mouse.move(initialShared.x + 12, 180);
  await page.mouse.move(initialMember.x + 12, 180);
  await page.mouse.move(700, 180);
  await expect(sharedCopy).toHaveCSS('filter', 'blur(2px)');
  await expect(memberCopy).toHaveCSS('filter', 'blur(2px)');

  // A deliberate hover reveals the bottom card and leaves both upper edges exposed.
  await page.mouse.move(initialShared.x + 12, 180);
  await expect(sharedCopy).toHaveCSS('filter', 'none');
  await expect(panel.locator(':scope > .pf-v6-c-card__body')).toHaveCSS('filter', 'blur(2px)');
  await ready(memberCard, (box) => box.x > 1100);
  const sharedBox = await sharedCard.boundingBox();
  const shiftedMember = await memberBack.boundingBox();

  // Go through the physical border seam, not straight from one hover target to another.
  await page.mouse.move(Math.floor(sharedBox.x + sharedBox.width), 180);
  await page.mouse.move(shiftedMember.x + 12, 180);
  await expect(memberCopy).toHaveCSS('filter', 'none');
  await expect(sharedCopy).toHaveCSS('filter', 'blur(2px)');

  const revealedMember = await memberBack.boundingBox();
  await page.mouse.click(revealedMember.x + 12, 180);
  await expect(panel.getByRole('heading', { name: 'Search volume capacity', exact: true })).toBeVisible();
  const returnMotion = await page.evaluate(() => window.stackMotion.at(-1)?.start);
  expect(returnMotion).toBeLessThan(0);
  await expect(history).toHaveAttribute('open', '');
  await expect.poll(() => panel.evaluate((el) => el.scrollTop)).toBe(scrollBefore);

  // A fresh load has no snapshots, so both rear panels need complete server-backed content.
  await page.goto(resultUrl);
  await connected(page);
  await expect(sharedCopy).toContainText('Contributing results');
  await expect(memberCopy).toContainText('Measurement history');
  await page.setViewportSize({ width: 390, height: 740 });
  await expect(trail).toBeHidden();
  await panel.getByRole('link', {name: '← Back one level', exact: true}).click();
  await expect(panel.getByRole('heading', {name: 'Search volume capacity', exact: true})).toBeVisible();
  await expect(panel).toHaveAttribute('data-panel-path', new RegExp(memberId));
  await panel.getByRole('link', {name: '← Back one level', exact: true}).click();
  await expect(panel.getByRole('heading', { name: 'Search storage capacity', exact: true })).toBeVisible();
  await expect(panel).toHaveAttribute('data-panel-path', new RegExp(group.id));
  // The reverse direction uses the same stack, with Checks as the host.
  await page.setViewportSize({ width: 1280, height: 720 });
  const checksResult = `/checks/${volume.id}?health=CRIT`;
  await page.goto(checksResult);
  await connected(page);
  await panel.getByRole('link', { name: 'View shared incident' }).click();
  await expect(page.locator('#checks-heading')).toBeVisible();
  await expect(panel.getByText('Contributing results', { exact: true })).toBeVisible();
  const resultBack = await ancestorLink(`result:${volume.id}`);
  await expect(resultBack).toHaveAttribute('aria-label', `Return to Check result: ${volume.label}`);
  const resultReturn = await resultBack.getAttribute('href');
  const resultOwner = new URL(resultReturn, page.url());
  expect(resultOwner.pathname).toBe(`/checks/${volume.id}`);
  expect(resultOwner.searchParams.get('health')).toBe('CRIT');
  expect(resultOwner.searchParams.get('inspect')).toBe(`result:${volume.id}`);
  await expect(resultBack.locator('..').locator('.preview-panel-snapshot')).toContainText('Latest measurement');
  await page.reload();
  await connected(page);
  await expect(resultBack.locator('..').locator('.preview-panel-snapshot')).toContainText('Latest measurement');
  await panel.getByRole('link', { name: 'Latest check result' }).and(panel.locator(`a[href=${JSON.stringify(resultReturn)}]`)).click();
  await expect(page).toHaveURL(new URL(resultReturn, page.url()).href);
  await expect(trail).toHaveCount(0);
  await expect(panel.getByText('Check result', { exact: true })).toBeVisible();

  expect(errors).toEqual([]);
  await reset(request);
});
