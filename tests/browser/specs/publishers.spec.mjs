// Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
// SPDX-License-Identifier: Apache-2.0
import { test, expect } from '@playwright/test';
import { checkpoint, connected, keyboardSubmit, mode, streams } from '../support/helpers.mjs';

const source = 'elasticsearch-monitoring';
const healthy = { available: true, used_percent: 40, sample_age_seconds: 0, writes_blocked: false };

async function api(request, path, data) {
  const response = data === undefined ? await request.get(path) : await request.post(path, { data });
  expect(response.ok(), `${path}: ${await response.text()}`).toBeTruthy();
  return response.json();
}

async function publisher(request, id) {
  return api(request, `/api/v1/publishers/${id}`);
}

async function observerResult(request, runner, health, { after = 0, excludedId } = {}) {
  let row;
  await expect.poll(async () => {
    row = (await streams(request, { runner_id: runner })).items.find((item) => item.source_id === source);
    return !!row && row.id !== excludedId && row.current?.knowledge === 'fresh' && row.current.health === health
      && row.active_generation === row.desired_generation && row.current.confirmed_generation === row.desired_generation
      && row.current.observation_id === row.current.confirmed_observation_id
      && ['source_at', 'evaluated_at', 'confirmed_evaluated_at'].every((key) => Date.parse(row.current[key]) > after);
  }, { timeout: 90_000, message: 'Each publisher must supply its own desired measurement' }).toBe(true);
  return row;
}

async function reset(request) {
  await mode(request, { webhook: 'ok', offline_installations: [], grouped_samples: {
    'service-a/elasticsearch': healthy, 'service-b/elasticsearch': healthy,
  } });
  let list;
  await expect.poll(async () => {
    list = await api(request, `/api/v1/coverage/publishers?source_id=${source}`);
    return list.items.length;
  }, { timeout: 90_000 }).toBe(2);
  const a = list.items.find((row) => row.runner_context.id === 'service-a');
  const b = list.items.find((row) => row.runner_context.id === 'service-b');
  for (const publication of [a, b]) {
    const current = await publisher(request, publication.id);
    if (current.publisher.lifecycle_status === 'retired') {
      const review = await api(request, '/api/v1/publishers/preview', { proposal: {
        publisher_id: publication.id, action: 'restore', reason: 'Start the next owned browser scenario',
      } });
      await api(request, '/api/v1/publishers/apply', { proposal: review.proposal, review_token: review.review_token });
    }
    await observerResult(request, publication.runner_id, 'OK');
  }
  return { a, b };
}

async function review(page, reason) {
  if (await page.locator('#publisher-preview').isVisible() && !await page.locator('#publisher-preview-button').isVisible()) {
    await page.getByRole('button', { name: 'Discard review', exact: true }).click();
  }
  await page.locator('#publisher-reason').fill(reason);
  await keyboardSubmit(page, page.locator('#publisher-preview-button'));
  await expect(page.locator('#publisher-preview')).toBeVisible();
  await expect(page.locator('#publisher-reason')).toHaveValue(reason);
}

async function apply(page) {
  await keyboardSubmit(page, page.locator('#publisher-apply'));
  await expect(page.locator('#publisher-preview')).not.toBeVisible();
}

test('reviewed replacement accepts independent Critical evidence and restores new membership without copying controls', async ({ page, request }, testInfo) => {
  const { a, b } = await reset(request);
  await mode(request, { grouped_samples: { 'service-a/elasticsearch': { used_percent: 96 }, 'service-b/elasticsearch': { used_percent: 96 } } });
  const boundary = Date.now();
  const predecessor = await observerResult(request, a.runner_id, 'CRIT', { after: boundary });
  const successor = await observerResult(request, b.runner_id, 'CRIT', { after: boundary });
  let incident;
  await expect.poll(async () => {
    const list = await api(request, '/api/v1/incidents');
    incident = list.items[0];
    return list.total === 1 && incident.open_contribution_count === 2;
  }).toBe(true);
  await page.goto('/coverage/publishers');
  await connected(page);
  await page.locator(`a[href*="/coverage/publishers/${a.id}"]`).first().click();
  await connected(page);
  await expect(page.locator('#publisher-heading')).toContainText('Predecessor');
  await page.locator('#publisher-action').selectOption('replace');
  await page.locator('#publisher-successor-search').fill('Successor');
  await page.locator(`[data-successor-id="${b.id}"]`).getByRole('button', { name: 'Choose observer' }).click();
  await expect(page.locator('#publisher-selected-successor')).toContainText('Successor');
  const reason = 'Move collection to the reviewed independent successor; keep the shared storage failure visible.';
  await page.evaluate(() => window.liveSocket.disconnect());
  await expect(page.locator('[data-phx-main]')).not.toHaveClass(/phx-connected/);
  await page.locator('#publisher-reason').fill(reason);
  await page.evaluate(() => window.liveSocket.connect());
  await connected(page);
  await expect(page.locator('#publisher-reason')).toHaveValue(reason);
  await expect(page.locator('#publisher-action')).toHaveValue('replace');
  await expect(page.locator('#publisher-selected-successor')).toContainText('Successor');
  await mode(request, { grouped_samples: { 'service-b/elasticsearch': { sample_age_seconds: 60 } } });
  await expect.poll(async () => (await streams(request, { runner_id: b.runner_id })).items.find((row) => row.id === successor.id)?.current?.knowledge).toBe('stale');
  await review(page, reason);
  await expect(page.locator('#publisher-preview-blockers')).toBeVisible();
  await expect(page.locator('#publisher-apply')).toBeDisabled();
  await checkpoint(page, testInfo, 'replacement-blocked-by-stale-evidence');
  await mode(request, { grouped_samples: { 'service-b/elasticsearch': { sample_age_seconds: 0 } } });
  await observerResult(request, b.runner_id, 'CRIT', { after: Date.now() });
  await review(page, reason);
  await expect(page.locator('#publisher-apply')).toBeEnabled();
  await checkpoint(page, testInfo, 'critical-successor-review-desktop');
  const group = await api(request, `/api/v1/incidents/${incident.id}`);
  const contribution = group.contributions.find((row) => row.incident.stream_id === predecessor.id).incident;
  await api(request, `/api/v1/incidents/${contribution.id}/acknowledge`, {
    mode: 'until_incident_ends', revision: contribution.acknowledgement_revision,
    attention_revision: contribution.attention_revision, note: 'Only the predecessor contribution',
  });
  // Reconnect with the original reviewed token after authority changed. It must
  // preserve the draft and require a new review, never silently renew approval.
  await page.evaluate(() => window.liveSocket.disconnect());
  await expect(page.locator('[data-phx-main]')).not.toHaveClass(/phx-connected/);
  await page.evaluate(() => window.liveSocket.connect());
  await connected(page);
  await expect(page.locator('#publisher-reason')).toHaveValue(reason);
  await expect.poll(async () => !await page.locator('#publisher-apply').isVisible() || await page.locator('#publisher-apply').isDisabled()).toBe(true);
  await expect(page.locator('#publisher-preview-button')).toHaveText('Preview again');
  expect((await publisher(request, a.id)).publisher.lifecycle_status).toBe('active');
  await review(page, reason);
  await page.setViewportSize({ width: 320, height: 760 });
  await checkpoint(page, testInfo, 'replacement-reviewed-after-stale-control-320');
  await apply(page);
  await expect(page.locator('#publisher-status')).toContainText('Retired from this controller');
  await expect(page.locator('#publisher-history')).toContainText(reason);
  const retained = await api(request, `/api/v1/incidents/${incident.id}?state=all`);
  expect(retained.incident.status).toBe('open');
  expect(retained.counts.open).toBe(1);
  const closed = (await api(request, `/api/v1/incidents/${contribution.id}`)).incident;
  expect(closed.closure_reason).toBe('publisher_replaced');
  expect(closed.closing_observation_id).toBeNull();
  expect((await observerResult(request, b.runner_id, 'CRIT')).id).toBe(successor.id);
  await checkpoint(page, testInfo, 'replacement-history-320');
  await page.locator('#publisher-action').selectOption('restore');
  const restoreReason = 'Restore this publication explicitly and require its own new inventory and measurements.';
  await review(page, restoreReason);
  await checkpoint(page, testInfo, 'restore-review-320');
  const restoreBoundary = Date.now();
  await apply(page);
  const restored = await observerResult(request, a.runner_id, 'CRIT', { after: restoreBoundary, excludedId: predecessor.id });
  expect(restored.assignment_id).not.toBe(predecessor.assignment_id);
  await expect(page.locator('#publisher-status')).toContainText('Active');
  await expect(page.locator('#publisher-history')).toContainText(restoreReason);
  await expect(page.locator('#publisher-history')).toContainText(reason);
  const now = await api(request, `/api/v1/incidents/${incident.id}?state=all`);
  expect(now.incident.status).toBe('open');
  expect(now.contributions.find((row) => row.incident.stream_id === restored.id).coverage.individual_acknowledgement).toBe(false);
  await checkpoint(page, testInfo, 'restored-new-membership-history-320');
  const saved = (await publisher(request, a.id)).history.items.find((event) => event.action === 'replace');
  const witness = await api(request, `/api/v1/publishers/${a.id}/events/${saved.id}`);
  expect(witness.items[0].successor_stream_id).toBe(successor.id);
  expect(witness.items[0].successor_health).toBe('CRIT');
  await mode(request, { grouped_samples: { 'service-b/elasticsearch': healthy } });
  const recovered = await observerResult(request, b.runner_id, 'OK', { after: Date.now() });
  expect(await api(request, `/api/v1/publishers/${a.id}/events/${saved.id}`)).toEqual(witness);
  await page.locator('#publisher-history .publisher-history-event').filter({ hasText: reason }).getByRole('link', { name: 'Inspect saved decision and evidence', exact: true }).click();
  await expect(page.locator('#publisher-saved-decision-heading')).toBeInViewport();
  await expect(page.locator('#publisher-saved-decision')).toContainText('Critical');
  await expect(page.locator('#publisher-saved-decision')).toContainText(reason);
  await page.locator('#publisher-saved-decision details summary').click();
  await expect(page.locator('#publisher-saved-decision')).toContainText(witness.items[0].successor_observation_id);
  const evidence = await api(request, `/api/v1/publishers/${a.id}/events/${saved.id}/evidence/${witness.items[0].successor_observation_id}`);
  const report = evidence.observation;
  const original = report.payload.results.find((row) => row.key === successor.result_key);
  expect(evidence.referenced_result_keys).toEqual([successor.result_key]);
  expect(original.health).toBe('CRIT');
  expect(original.value).toBe(96);
  expect(Date.parse(original.source_at)).toBeLessThan(Date.parse(recovered.current.source_at));
  expect(report.id).not.toBe(recovered.current.observation_id);
  expect(evidence.configuration.generation).toBe(report.generation);
  await page.locator('#publisher-saved-decision').getByRole('link', { name: 'Inspect saved measurement', exact: true }).click();
  await expect(page.locator('#publisher-saved-measurement-heading')).toBeInViewport();
  const measurement = page.locator('#publisher-saved-measurement');
  await expect(measurement).toHaveAttribute('data-observation-id', report.id);
  await expect(measurement.locator('[data-saved-result-key]')).toHaveCount(1);
  await expect(measurement.locator(`[data-saved-result-key="${successor.result_key}"]`)).toContainText('Critical');
  await expect(measurement).toContainText(original.summary);
  await expect(measurement).toContainText(original.details);
  await expect(measurement).toContainText('Measured value: 96');
  await expect(measurement.locator(`time[datetime="${original.source_at}"]`)).toBeVisible();
  await expect(measurement.locator(`time[datetime="${report.evaluated_at}"]`)).toBeVisible();
  await expect(measurement.locator('dl > div').filter({ has: page.getByText('Configuration version', { exact: true }) }).locator('dd')).toHaveText(String(report.generation));
  await page.locator('#publisher-saved-measurement-provenance summary').click();
  await expect(measurement).toContainText(report.session_id);
  expect(JSON.parse(await measurement.locator('pre').innerText())).toEqual(evidence.configuration.params);
  await page.evaluate(() => window.liveSocket.disconnect());
  await expect(page.locator('[data-phx-main]')).not.toHaveClass(/phx-connected/);
  await page.evaluate(() => window.liveSocket.connect());
  await connected(page);
  await expect(measurement).toHaveAttribute('data-observation-id', report.id);
  await expect(measurement).toContainText(original.summary);
  await expect(page.locator('#publisher-saved-measurement-missing')).not.toBeVisible();
  await checkpoint(page, testInfo, 'saved-replacement-witness-after-successor-recovery-320');
  await page.locator('#publisher-saved-decision').getByRole('link', { name: 'Inspect replacement result', exact: true }).click();
  await connected(page);
  await expect(page.locator('main')).toContainText('Elasticsearch storage is 40% used');
  await page.goBack();
  await connected(page);
  await expect(page.locator('#publisher-saved-measurement')).toHaveAttribute('data-observation-id', report.id);
  await expect(page.locator('#publisher-saved-measurement')).toContainText(original.summary);
});

test('intentional retirement and restore use explicit reasons while unrelated monitoring keeps measuring', async ({ page, request }, testInfo) => {
  const { a } = await reset(request);
  const before = await observerResult(request, a.runner_id, 'OK');
  const unrelated = (await streams(request)).items.find((row) => row.source_id === 'declared-coverage');
  await page.goto(`/coverage/publishers/${a.id}`);
  await connected(page);
  await page.locator('#publisher-action').selectOption('retire');
  const reason = 'This observer is intentionally being removed; this is not measured recovery.';
  await review(page, reason);
  await page.setViewportSize({ width: 390, height: 844 });
  await checkpoint(page, testInfo, 'intentional-retirement-review-390');
  await apply(page);
  await expect(page.locator('#publisher-status')).toContainText('Retired from this controller');
  await expect(page.locator('#publisher-history')).toContainText(reason);
  expect((await streams(request)).items.some((row) => row.id === before.id)).toBe(false);
  expect((await streams(request)).items.some((row) => row.id === unrelated.id && row.current.knowledge === 'fresh')).toBe(true);
  await page.evaluate(() => window.liveSocket.disconnect());
  await expect(page.locator('[data-phx-main]')).not.toHaveClass(/phx-connected/);
  await page.evaluate(() => window.liveSocket.connect());
  await connected(page);
  await expect(page.locator('#publisher-status')).toContainText('Retired from this controller');
  await page.locator('#publisher-action').selectOption('restore');
  await review(page, 'Resume intentional monitoring with fresh new membership.');
  const boundary = Date.now();
  await apply(page);
  const after = await observerResult(request, a.runner_id, 'OK', { after: boundary, excludedId: before.id });
  expect(after.assignment_id).not.toBe(before.assignment_id);
  await expect(page.locator('#publisher-status')).toContainText('Active');
  await page.setViewportSize({ width: 1280, height: 900 });
  await checkpoint(page, testInfo, 'retirement-and-restoration-history-desktop');
});
