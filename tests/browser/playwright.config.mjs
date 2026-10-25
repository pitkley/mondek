// Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
// SPDX-License-Identifier: Apache-2.0
import { defineConfig, devices } from '@playwright/test';
import path from 'node:path';

const output = process.env.MONDEK_BROWSER_OUTPUT || './test-results';
const suite = process.env.MONDEK_BROWSER_SUITE || 'lifecycle';
const video = process.env.MONDEK_BROWSER_VIDEO || 'off';
if (!['off', 'retain-on-failure'].includes(video)) throw new Error(`Unknown video mode: ${video}`);
if (!['discovery-configuration', 'linux', 'lifecycle', 'diagnostics', 'discovery', 'monitoring-loss', 'fleet', 'empty', 'parity', 'bulk', 'rules', 'policy', 'acknowledgements', 'maintenance', 'inventory', 'check-groups', 'grouped', 'coverage', 'publishers'].includes(suite)) throw new Error(`Unknown suite: ${suite}`);

export default defineConfig({
  testDir: './specs',
  testMatch: `${suite}.spec.mjs`,
  timeout: suite === 'bulk' ? 900_000 : suite === 'fleet' ? 600_000 : 300_000,
  expect: { timeout: 30_000 },
  fullyParallel: false,
  workers: 1,
  retries: 0,
  forbidOnly: !!process.env.CI,
  outputDir: path.join(output, 'results'),
  reporter: [
    ['line'],
    ['html', { outputFolder: path.join(output, 'report'), open: 'never' }],
    ['json', { outputFile: path.join(output, 'results.json') }],
  ],
  use: {
    ...devices['Desktop Chrome'],
    baseURL: process.env.MONDEK_BROWSER_BASE_URL || 'http://localhost:4000',
    actionTimeout: 15_000,
    navigationTimeout: 30_000,
    trace: 'retain-on-failure',
    screenshot: 'only-on-failure',
    video,
  },
});
