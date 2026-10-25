// Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
// SPDX-License-Identifier: Apache-2.0
import { test, expect } from '@playwright/test';
import { attachState, checkpoint, snapshot, tabTo } from '../support/helpers.mjs';

test('packaged credits remain readable at desktop and narrow widths', async ({ page, request }, testInfo) => {
  await page.goto('/guide');
  await page.getByRole('link', { name: 'Licenses and credits', exact: true }).click();
  await expect(page).toHaveURL(/\/licenses$/);
  await expect(page.getByRole('heading', { name: 'Licenses and credits', exact: true })).toBeVisible();
  await page.locator('#credit-lucide-static summary').click();
  await expect(page.locator('#credit-lucide-static')).toContainText('Lucide Icons and Contributors');
  await page.locator('#credit-telemetry summary').click();
  await expect(page.locator('#credit-telemetry')).toContainText('NOTICE');
  for (const width of [1280, 320]) {
    await page.setViewportSize({ width, height: 900 });
    await checkpoint(page, testInfo, `packaged-credits-${width}`);
  }
  const response = await request.get('/licenses/notices');
  expect(response.ok()).toBeTruthy();
  expect(response.headers()['content-type']).toContain('text/plain');
  const notices = await response.text();
  expect(notices).toContain('telemetry');
  expect(notices).toContain('Lucide Icons and Contributors');
  expect(notices).toContain('Cole Bemis');
  const sprite = await request.get('/assets/icons.svg');
  expect(sprite.ok()).toBeTruthy();
  expect(await sprite.text()).toContain('<symbol id="send"');
  await expect(page.locator('svg use').first()).toHaveAttribute('href', /^\/assets\/icons\.svg#/);
  expect(notices).toContain('Chris McCord');
});

test('empty installation explains source ownership and offers keyboard-accessible runner inspection', async ({ page, request }, testInfo) => {
  expect((await snapshot(request)).assignments).toEqual([]);
  await page.setViewportSize({ width: 320, height: 740 });
  await page.goto('/');
  await tabTo(page, page.getByRole('link', { name: 'Skip to content', exact: true }));
  await page.keyboard.press('Enter');
  await expect(page.locator('#main-content')).toBeFocused();
  await expect(page.locator('#runner-onboarding')).toContainText('Install your consumer package on a runner');
  await expect(page.getByRole('button', { name: /Create|Configure three/ })).toHaveCount(0);
  await checkpoint(page, testInfo, 'empty-runner-onboarding-320');
  await tabTo(page, page.getByRole('link', { name: 'Inspect runner connections', exact: true }));
  await page.keyboard.press('Enter');
  await expect(page).toHaveURL(/\/runners$/);
  await checkpoint(page, testInfo, 'empty-runner-inspection-320');
  await page.goto('/configuration/new');
  await expect(page.getByRole('heading', { name: 'Configuration', exact: true })).toBeVisible();
  await expect(page.getByRole('link', { name: 'Add check', exact: true })).toHaveCount(0);
  await checkpoint(page, testInfo, 'legacy-bookmark-shows-inventory');
  await page.goto('/checks');
  await expect(page.locator('#check-inventory')).toContainText('0 matching');
  await checkpoint(page, testInfo, 'empty-result-inventory');
  await page.getByRole('link', { name: 'Runner setup', exact: true }).click();
  await expect(page).toHaveURL(/\/guide$/);
  await expect(page.getByText('Set up a local Mondek server', { exact: true })).toHaveCount(0);
  await expect(page.locator('#runner-launch-example')).toContainText("--controller 'http://localhost:4000'");
  await expect(page.locator('#runner-launch-example')).toContainText('--state-dir .mondek-state');
  await expect(page.locator('#project-starter-example')).toContainText('mondek-runner init');
  await checkpoint(page, testInfo, 'runnable-source-setup-guide-320');
  await attachState(request, testInfo, 'empty-installation-state');
});

test('agent prompts copy the reviewed text and offer an honest keyboard fallback', async ({ page, context }, testInfo) => {
  await context.grantPermissions(['clipboard-read', 'clipboard-write']);
  await page.setViewportSize({ width: 320, height: 740 });
  await page.goto('/guide');
  expect(await page.evaluate(() => window.isSecureContext && !!navigator.clipboard)).toBe(true);
  const prompt = page.locator('#runner-agent-prompts-project');
  await prompt.locator('summary').click();
  const field = prompt.locator('textarea');
  const reviewed = await field.inputValue();
  expect(reviewed).toContain('mondek-runner init');
  expect(reviewed).toContain('UNTRUSTED');
  await tabTo(page, prompt.getByRole('button', { name: 'Copy prompt', exact: true }));
  await page.keyboard.press('Enter');
  await expect(prompt.getByRole('status')).toContainText('Prompt copied');
  expect(await page.evaluate(() => navigator.clipboard.readText())).toBe(reviewed);
  await page.waitForTimeout(1500);
  await expect(prompt).toHaveAttribute('open', '');
  await checkpoint(page, testInfo, 'agent-prompt-real-clipboard-320');

  await page.evaluate(() => {
    Object.defineProperty(navigator.clipboard, 'writeText', {
      configurable: true,
      value: () => Promise.reject(new DOMException('Test clipboard denial', 'NotAllowedError')),
    });
  });
  await prompt.getByRole('button', { name: 'Copy prompt', exact: true }).click();
  await expect(prompt.getByRole('status')).toContainText('Clipboard unavailable');
  await expect(prompt.getByRole('status')).not.toContainText('copied');
  await expect(field).toBeFocused();
  expect(await field.evaluate((element) => element.selectionStart === 0 && element.selectionEnd === element.value.length)).toBe(true);
  await checkpoint(page, testInfo, 'agent-prompt-copy-denied-320');

  await prompt.getByRole('button', { name: 'Select text', exact: true }).click();
  await expect(field).toBeFocused();
  await expect(prompt.getByRole('status')).toContainText('Prompt selected');
  const relationships = page.locator('#runner-agent-prompts-relationships');
  await relationships.locator('summary').click();
  await expect(relationships.locator('textarea')).toContainText('no relationship graph');
  await checkpoint(page, testInfo, 'agent-relationships-boundary-320');
});
