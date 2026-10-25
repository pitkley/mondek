// Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
// SPDX-License-Identifier: Apache-2.0
import { test, expect } from '@playwright/test';
import { mkdir, rename, rm } from 'node:fs/promises';
import { checkpoint, connected, mode, snapshot, streams } from '../support/helpers.mjs';

const root = '/discovery-fixture';
async function inventory(request) {
  return (await streams(request)).items.find((item) => item.source_id === 'discovery-example');
}
async function reconnect(page) {
  await page.evaluate(() => window.liveSocket.disconnect());
  await expect(page.locator('[data-phx-main]')).not.toHaveClass(/phx-connected/);
  await page.evaluate(() => window.liveSocket.connect());
  await connected(page);
}

// The browser manipulates only this disposable named volume. The installed
// consumer discovers its actual directories through a read-only runner mount.
test('consumer discoveries propose source changes without accepting inventory and preserve drafts across evidence changes', async ({ page, context, request }, testInfo) => {
  const errors = [];
  page.on('pageerror', (error) => errors.push(error.message));
  await mode(request, { offline_installations: [] });
  await mkdir(`${root}/volumes/app`, { recursive: true });
  await mkdir(`${root}/volumes/data`, { recursive: true });
  try {
    await expect.poll(async () => (await inventory(request))?.current?.knowledge).toBe('fresh');
    const initial = await inventory(request);
    const before = await snapshot(request);
    const declarations = before.assignments.map((item) => ({ id: item.id, source_revision: item.source_revision, desired_generation: item.desired_generation }));
    const incident = before.incidents.find((item) => item.stream_id === initial.id && item.status === 'open');
    expect(incident).toBeTruthy();
    await page.goto(`/incidents/${incident.id}`);
    await connected(page);
    await expect(page.locator('#incident-check-now h2')).toHaveText('Latest measurement');
    await expect(page.locator('#incident-current-details')).toContainText("- 'app'");
    await expect(page.locator('#incident-current-details')).toContainText("- 'data'");
    await expect(page.locator('#incident-measurements')).not.toHaveAttribute('open', '');
    await checkpoint(page, testInfo, 'incident-discovery-findings-1280');
    await page.setViewportSize({ width: 390, height: 844 });
    await checkpoint(page, testInfo, 'incident-discovery-findings-390');
    await page.locator('#incident-discovery-review').click();
    await expect(page.locator('#discovery-back')).toHaveAttribute('href', `/incidents/${incident.id}`);
    await page.locator('#discovery-back').click();
    await expect(page).toHaveURL(new RegExp(`/incidents/${incident.id}$`));
    await expect(page.locator('#incident-current-details')).toBeVisible();
    await page.setViewportSize({ width: 1280, height: 900 });

    await page.goto(`/checks/${initial.id}`);
    await connected(page);
    await page.locator('#result-discovery-review').click();
    await connected(page);
    await expect(page.locator('#discovery-candidate-0')).toContainText('app');
    await expect(page.locator('#discovery-candidate-1')).toContainText('data');
    await page.locator('#discovery-select-0').check();
    await page.locator('#discovery-choice-0').selectOption('monitor');
    await page.locator('#discovery-params-0-limit').fill('85');
    await page.locator('#discovery-select-1').check();
    await page.locator('#discovery-choice-1').selectOption('ignore');
    await expect.poll(async () => (await inventory(request)).current.observation_id).not.toBe(initial.current.observation_id);
    await expect(page.locator('#discovery-params-0-limit')).toHaveValue('85');
    await reconnect(page);
    await expect(page.locator('#discovery-params-0-limit')).toHaveValue('85');
    await expect(page.locator('#discovery-choice-1')).toHaveValue('ignore');
    await page.locator('#discovery-review').click();
    await expect(page.locator('#discovery-proposal-review')).toContainText('85');
    await page.locator('#discovery-generate').click();
    const prompt = page.locator('#discovery-prompt-text');
    await expect(prompt).toBeVisible();
    const proposal = await prompt.inputValue();
    expect(proposal).toContain('discovery_demo.py');
    expect(proposal).toContain('85');
    expect(proposal).toContain('ignore');
    await context.grantPermissions(['clipboard-read', 'clipboard-write']);
    await page.locator('#discovery-prompt-copy').click();
    await expect.poll(() => page.evaluate(() => navigator.clipboard.readText())).toBe(proposal);
    const after = await snapshot(request);
    expect(after.assignments.map((item) => ({ id: item.id, source_revision: item.source_revision, desired_generation: item.desired_generation }))).toEqual(declarations);
    expect((await inventory(request)).current.health).toBe('WARN');
    await checkpoint(page, testInfo, 'discovery-reviewed-source-proposal');
    await page.setViewportSize({ width: 320, height: 740 });
    await checkpoint(page, testInfo, 'discovery-reviewed-source-proposal-320');

    // Failed collection retains previous evidence but cannot authorize a proposal.
    await rename(`${root}/volumes`, `${root}/unavailable`);
    await expect.poll(async () => (await inventory(request)).current.knowledge).toBe('unavailable');
    await expect(page.locator('#discovery-unavailable')).toBeVisible();
    await expect(page.locator('#discovery-review')).toBeDisabled();
    await reconnect(page);
    await expect(page.locator('#discovery-select-0')).toBeChecked();
    await expect(page.locator('#discovery-params-0-limit')).toHaveValue('85');
    await expect(page.locator('#discovery-review')).toBeDisabled();
    await checkpoint(page, testInfo, 'discovery-unavailable-draft-320');
    await rename(`${root}/unavailable`, `${root}/volumes`);
    await expect.poll(async () => (await inventory(request)).current.knowledge).toBe('fresh');
    await expect(page.locator('#discovery-review')).toBeEnabled();

    // A live inventory change must not silently rebind the operator's choices.
    await mkdir(`${root}/volumes/new-volume`);
    await expect(page.locator('#discovery-changed')).toBeVisible();
    await expect(page.locator('#discovery-review')).toBeDisabled();
    await reconnect(page);
    await expect(page.locator('#discovery-changed')).toBeVisible();
    await expect(page.locator('#discovery-params-0-limit')).toHaveValue('85');
    await page.locator('#discovery-reload').click();
    await expect(page.locator('[id^="discovery-candidate-"]')).toHaveCount(3);
    await expect(page.locator('#discovery-select-0')).not.toBeChecked();
    await page.locator('#discovery-select-0').check();
    await page.locator('#discovery-choice-0').selectOption('monitor');
    await page.locator('#discovery-params-0-limit').fill('82');

    // Controller transport loss ages evidence while the worker keeps scanning.
    await mode(request, { offline_installations: [initial.runner_id] });
    await expect(page.locator('#discovery-unavailable')).toBeVisible({ timeout: 30_000 });
    await expect(page.locator('#discovery-review')).toBeDisabled();
    await reconnect(page);
    await expect(page.locator('#discovery-params-0-limit')).toHaveValue('82');
    await expect(page.locator('#discovery-review')).toBeDisabled();
    await mode(request, { offline_installations: [] });
    await expect(page.locator('#discovery-review')).toBeEnabled({ timeout: 45_000 });
    await expect(page.locator('#discovery-params-0-limit')).toHaveValue('82');
    await checkpoint(page, testInfo, 'discovery-transport-restored-320');
    await page.goto(`/incidents/${incident.id}`);
    await connected(page);
    await expect(page.locator('#incident-check-now')).toContainText('3 directories need review');
    await expect(page.locator('#incident-current-details')).toContainText("- 'new-volume'");
    await page.locator('#incident-measurements > summary').click();
    await expect(page.locator('#incident-measurements')).toContainText('When this incident opened');
    await expect(page.locator('#incident-measurements')).toContainText('2 directories need review');
    await checkpoint(page, testInfo, 'incident-updated-findings-history-320');
    expect(errors).toEqual([]);
  } finally {
    await mode(request, { offline_installations: [] });
    await rm(`${root}/volumes`, { recursive: true, force: true });
    await rm(`${root}/unavailable`, { recursive: true, force: true });
  }
});
