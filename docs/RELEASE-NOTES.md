# Mondek 0.0.5

Controller and SDK versions are both `0.0.5`, with Git tag `v0.0.5` and controller image tag `0.0.5`. This release adds controller-backed consumer state, manual incident correlation cases and opt-in exact notification batches. Mondek remains experimental; use matching controller and SDK versions.

## Consumer state

Checks can use `CheckContext.state` to share bounded JSON within a source or keep assignment-local state. Reads, writes, compare-and-set, deletion and optional TTL use controller persistence with explicit conflict and indeterminate-write errors. State survives controller restart; writes are not queued or retried as observation evidence. Operator UI and HTTP reads expose current entries and quota usage. Values are operator-visible data, not secret storage. See [consumer state](CONSUMER-STATE.md) for scope, bounds, unavailable-state handling and source-age requirements.

Runner state calls add `POST /api/v1/runner/state`; update operator-managed gateway policies before using them. Existing gateway admission does not establish isolation between mutually untrusted runners. Built-in authentication and authorization remain out of scope.

## Correlation cases and notification batches

Operators can create and review flat cases linking exact incident episodes, optionally identifying a suspected parent. Cases support attach, detach, merge and split, with audit history and replay-safe reviewed commands. HTTP and read-only MCP investigation expose case membership and provenance. Correlation does not change recorded measurements or establish causality. Automatic correlation, SDK hints and external model decisions remain future work. See [runtime correlation](RUNTIME-INCIDENT-CORRELATION.md).

Batching defaults off. Explicitly enabled cases can combine compatible, eligible notification work into immutable exact batches while preserving original attempt budgets and native fallback. Existing queued work remains native-only. A batch's terminal notification means all episodes in that frozen batch ended; it does not claim the whole case recovered. Case acknowledgements cover reviewed membership and severity/impact bounds, ending on topology changes or new qualifying impact. Child controls remain independent. Before enabling batching, update custom webhook receivers/templates for `incident.type="correlation"` and the aggregate `batch` document; see [webhook documents](WEBHOOK-NOTIFICATIONS.md#stable-mondek-document). See [exact batch delivery](EXACT-BATCH-DELIVERY.md).

## Runner startup and release automation

Runners verify saved execution snapshots against the installed runtime before scheduling them. Compatible saved work can resume during a controller outage; incompatible revisions remain blocked with useful status until the runner prepares and adopts an authorized replacement. Existing installation identity, journals and buffered reports are retained.

After successful versioned publication, the release pipeline verifies public SDK bytes and both controller image identities, then commits installation defaults directly to main. This replaces routine post-release pin-update PRs; it does not remove release qualification or publication approval.

## Upgrading

Back up PostgreSQL and complete runner state directories, stop old runners, and upgrade the controller and SDK together. Packaged startup applies three additive migrations for consumer state, correlation cases and case delivery. Keep the database, configuration history, runner identities and buffered reports; do not reset volumes or journals. Older queued notifications gain no new automatic credits. Review gateway access for the added runner-state route and use the generated [OpenAPI contract](../contracts/http/v1/openapi.json) for the expanded API. Rollback requires reviewed preservation of the new state and pending delivery work. See [upgrade guidance](UPGRADING.md#005-consumer-state-and-correlation-delivery).
