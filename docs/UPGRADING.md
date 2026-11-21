# Installation state and upgrades

Mondek is experimental. Run the controller and runner SDK from the same reviewed revision and back up PostgreSQL and each runner's complete state directory before changing versions. Keep the previous application artifacts and locked consumer environment available for recovery. Back up a running SQLite journal consistently rather than copying its database file alone.

Consumer state adds an additive startup migration for bounded runtime entries, source accounting and runner admission counters. Back up the database before upgrading. No existing observations, configuration generations, runner journals or source snapshot identities are rewritten. Use matching controller/SDK revisions when adopting the new state API; existing checks remain unchanged. See [consumer state](CONSUMER-STATE.md).

The [packaged consumer-state qualification](CONSUMER-STATE-PACKAGED-QUALIFICATION.md) verifies upgrade from published 0.0.3 without resetting the database, exact retained evidence/configuration, restart persistence and authenticated state traffic through an owned HTTPS gateway.

## Fresh database baseline

The initial database migration creates the current application schema and the pinned Oban schema. It requires a fresh database and refuses a database containing other migration versions. Historical pre-publication installations require a separately reviewed private transition; replacing migration records or pointing a fresh Compose project at an old volume is not an upgrade procedure. The baseline cannot be rolled back destructively through `ecto.rollback`.

The packaged controller automatically applies pending Ecto migrations before starting the web application. Already applied migrations are skipped. Startup logs a concise count of applied migrations; detailed migration instructions are logged at DEBUG rather than INFO. A migration failure stops startup instead of serving against a partially upgraded schema. Ordinary Compose rebuild/restart updates therefore do not require a separate migration command.

Subsequent schema changes use normal Ecto migrations. Inspect the release's migrations and version notes before upgrading. Stop conflicting controller versions before changing database contracts. Do not delete volumes or runner state to force a migration or snapshot to succeed.

## Preserve identity and evidence

Keep the same PostgreSQL database, Compose volume bindings and complete runner state directories. Retain installation, source, check, environment, target and output identities. Buffered reports preserve their original IDs, payloads and execution times. Existing configuration Git objects are immutable history; do not rewrite their contents or commit IDs during an update.

Prepared execution requires the current authenticated snapshot format and complete signed registration list. SDK and consumer updates change frozen runtime identity; normal discovery/preparation creates a matching snapshot. On restart, the runner verifies saved snapshots before scheduling them. Compatible snapshots can collect while the controller is unavailable. If the installed dependencies differ, the runner reports the blocked checks in its status and resumes collection after it prepares and adopts the replacement authorized by the controller. A prolonged gap can still trigger monitoring-loss notifications. Do not edit manifests, recompute signatures or clear journals to bypass the runtime fence.

## Verification and recovery

After a coordinated update, verify stable runner installation IDs, higher boot/session counters, unchanged scheduled-check identities and fresh measurements at the adopted revision. Verify retained incidents, rules/exceptions, configuration history and held/retrying notifications. A healthy controller or recent runner contact alone does not prove fresh monitoring. The [installed dependency rollout acceptance](../tests/e2e/README.md#installed-dependency-rollout) verifies that an established gap keeps its deadline through adoption and clears after fresh authorized evidence.

Restore a coordinated backup with its matching controller, consumer and locked Python environment if recovery is required. Restoring controller and runner state independently can change evidence or notification behavior; review those consequences before restarting.

Webhook-enabled builds require no new database migration. Existing SMTP and local recording-webhook occurrences retain their formats and destinations. New production webhooks freeze a separate delivery envelope and bind a runtime destination ID to its URL fingerprint; retain old destination definitions and transport credentials until their queued work drains. See [webhook configuration and retry compatibility](WEBHOOK-NOTIFICATIONS.md).

Production database configuration no longer falls back to the development port/database: the default port is now 5432, and `PGDATABASE` must be explicitly set (or supplied through `DATABASE_URL` outside deployment mode). Before upgrading a directly launched production controller that previously relied on implicit values, set `PGPORT=55432` and `PGDATABASE=mondek_dev` explicitly if those are its intended existing database settings. The maintained Compose recipes already supply both values and need no change. Development and test defaults remain unchanged.

## 0.0.2: unified HTTP API cutover

Upgrade the controller and runners/CLI together from 0.0.1 to 0.0.2; mixed versions are incompatible and old HTTP paths have no aliases. Stop the old runner before replacing its binary, retain its state directory and installation/journal, upgrade the controller against the existing database, then start the matching runner. The controller initializes configuration repository identity before accepting HTTP; reading its revision no longer bootstraps durable state. No schema reset, journal deletion or observation rewrite is required. Existing migration startup remains authoritative.

Runner exchanges now use `/api/v1/runner/{control,inventory,observations}`. Update any operator-managed gateway path policies together with the deployment. Resource reads use `{data,meta}`, errors use `{error:{code,message,details?},request_id}`, and scheduled assignment settings are read/written through `/api/v1/assignments/:id/configuration`. See the complete [route disposition table](API-ROUTES.md). Buffered reports keep their original identity, age, session and generation; replays must continue to produce their original receipt or historical disposition.

## 0.0.3: historical incident findings

Upgrade the matching controller and SDK after backing up PostgreSQL and runner state. Packaged startup automatically applies a new additive migration adding the nullable `incidents.latest_failure_observation_id` column. Published baseline migration history is unchanged. Retained incident/report identities and runner transport formats are preserved; do not reset the database or journals.

New failure measurements advance the reference transactionally, including failures with unchanged severity. Recovery preserves it; retention protects opening, latest-failure and closing evidence while their incident is retained. Older `latest_observation_id` values are not reinterpreted: closed grouped contributions can legitimately point at recovery there. The migration does not invent or reconstruct historical latest failures. Existing incidents show verified opening/notification evidence as explicit fallback, or unavailable evidence; the next admitted failure establishes the new latest-failure reference for an open incident.

Health API details add a resolved `recorded_measurement` block; shared contributions replace the ambiguous `measured_result` field with the same block. This intentionally changes the experimental response contract. Update clients using the generated OpenAPI and the [incident evidence guide](HTTP-API.md#investigate-monitoring). Keep current results separate from historical findings and check fallback basis/gaps before describing evidence as latest.

## 0.0.4: Plug multipart security fix

Version 0.0.4 updates Plug from 1.20.3 to 1.20.4 for [CVE-2026-120287](https://github.com/elixir-plug/plug/security/advisories/GHSA-qj4r-jh2r-rw3f). The multipart parser previously failed to count all framing/header bytes against the request length budget, allowing memory exhaustion. Mondek enables this parser. Published 0.0.3 and earlier controller images retain the affected dependency; a source lock update does not change those immutable images.

Replace the controller with the published 0.0.4 artifact and use the matching SDK. Until upgraded, enforce an aggregate request-body size limit at the external gateway as described by the upstream advisory. Do not rebuild or overwrite the published 0.0.3 tag/image under its existing version.

This patch adds no database migration, API or runner transport format change. Preserve PostgreSQL, runner state, buffered reports and configuration history through the normal upgrade procedure. Multipart requests exceeding their budget return an error while ordinary forms and JSON APIs retain their existing behavior.

## 0.0.5: consumer state and correlation delivery

Upgrade controller and SDK together after backing up PostgreSQL and each runner's complete state directory. From 0.0.4, packaged startup applies three additive migrations: `20261116120000_add_consumer_state`, `20261116120100_add_correlations` and `20261116160000_add_case_delivery`. Preserve the existing database, configuration history, installation identities, journals and buffered observations. Do not reset migration records or delete state to force startup.

Before adopting consumer state, allow `POST /api/v1/runner/state` through the runner gateway policy and review the separate operator-read policy for `/api/v1/consumer-state`. State values are operator-visible persisted data, not secrets. Existing source/session admission does not isolate mutually untrusted runners. See [consumer state](CONSUMER-STATE.md).

The updated runner checks saved snapshots against installed dependencies before scheduling. Compatible saved work may run during a controller outage; incompatible revisions wait for preparation and controller-authorized adoption, and prolonged gaps can cause monitoring-loss notifications. Keep the previous locked consumer environment available for recovery.

Correlation batching defaults off and case acknowledgements require explicit reviewed actions. Existing queued work remains native-only with its original budget. Preserve new state, case history and pending exact-batch terminal obligations when planning recovery; older code is not an automatic database rollback. The packaged consumer-state qualification's historical one-migration result predates the full 0.0.5 migration set.

## 0.0.6: delivery, Configuration Git and measurement freshness

Back up PostgreSQL and complete runner state directories and upgrade the controller and SDK together. Upgrading from 0.0.5 adds no database migration. Preserve configuration Git history, runner installation identities, journals and buffered observations. Upgrade both components before publishing checks whose source measurement freshness exceeds the former two-day limit.

Notification delivery still defaults to SMTP in deployment mode. If you opt into delivery off, review how pending retries are recorded and how to resume delivery before switching. For a group-readable Kubernetes webhook configuration file, match the configured GID to the Pod's dedicated file group. See [notification delivery](RUNNERS-AND-NOTIFICATIONS.md#turn-delivery-off) and [webhook settings](WEBHOOK-NOTIFICATIONS.md).

Existing Configuration Git token settings continue to work. When adopting file-based rotation, mount the containing directory and preserve access from the controller UID. If enabling the separate Git token header behind a gateway, update gateway rules and client credentials together. See [Configuration Git](CONFIGURATION-GIT.md).

## Runtime cases

The additive correlation migration runs at packaged startup. Existing evidence, controls, jobs and identities remain unchanged. Back up before upgrading. Correlation batching defaults off and case acknowledgements remain explicit; rollback to older code requires a reviewed database rollback and must not discard case history silently.

## Exact case delivery

The additive case-delivery migration preserves original occurrences, attempts and jobs. Existing work has no new automatic credits and remains native-only; new work and explicit retry budgets receive credit epochs. Case batching defaults off. Back up before upgrade. Batch/acknowledgement/witness and credit history is protected by retention. Rollback needs reviewed preservation of pending terminal work rather than dropping these tables.
