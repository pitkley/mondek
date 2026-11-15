# Installation state and upgrades

Mondek is experimental. Run the controller and runner SDK from the same reviewed revision and back up PostgreSQL and each runner's complete state directory before changing versions. Keep the previous application artifacts and locked consumer environment available for recovery. Back up a running SQLite journal consistently rather than copying its database file alone.

## Fresh database baseline

The initial database migration creates the current application schema and the pinned Oban schema. It requires a fresh database and refuses a database containing other migration versions. Historical pre-publication installations require a separately reviewed private transition; replacing migration records or pointing a fresh Compose project at an old volume is not an upgrade procedure. The baseline cannot be rolled back destructively through `ecto.rollback`.

The packaged controller automatically applies pending Ecto migrations before starting the web application. Already applied migrations are skipped. Startup logs a concise count of applied migrations; detailed migration instructions are logged at DEBUG rather than INFO. A migration failure stops startup instead of serving against a partially upgraded schema. Ordinary Compose rebuild/restart updates therefore do not require a separate migration command.

Subsequent schema changes use normal Ecto migrations. Inspect the release's migrations and version notes before upgrading. Stop conflicting controller versions before changing database contracts. Do not delete volumes or runner state to force a migration or snapshot to succeed.

## Preserve identity and evidence

Keep the same PostgreSQL database, Compose volume bindings and complete runner state directories. Retain installation, source, check, environment, target and output identities. Buffered reports preserve their original IDs, payloads and execution times. Existing configuration Git objects are immutable history; do not rewrite their contents or commit IDs during an update.

Prepared execution requires the current authenticated snapshot format and complete signed registration list. SDK and consumer updates change frozen runtime identity; normal discovery/preparation creates a matching snapshot. Do not edit manifests, recompute signatures or clear journals to bypass the runtime fence.

## Verification and recovery

After a coordinated update, verify stable runner installation IDs, higher boot/session counters, unchanged scheduled-check identities and fresh measurements at the adopted revision. Verify retained incidents, rules/exceptions, configuration history and held/retrying notifications. A healthy controller or recent runner contact alone does not prove fresh monitoring.

Restore a coordinated backup with its matching controller, consumer and locked Python environment if recovery is required. Restoring controller and runner state independently can change evidence or notification behavior; review those consequences before restarting.

Webhook-enabled builds require no new database migration. Existing SMTP and local recording-webhook occurrences retain their formats and destinations. New production webhooks freeze a separate delivery envelope and bind a runtime destination ID to its URL fingerprint; retain old destination definitions and transport credentials until their queued work drains. See [webhook configuration and retry compatibility](WEBHOOK-NOTIFICATIONS.md).

Production database configuration no longer falls back to the development port/database: the default port is now 5432, and `PGDATABASE` must be explicitly set (or supplied through `DATABASE_URL` outside deployment mode). Before upgrading a directly launched production controller that previously relied on implicit values, set `PGPORT=55432` and `PGDATABASE=mondek_dev` explicitly if those are its intended existing database settings. The maintained Compose recipes already supply both values and need no change. Development and test defaults remain unchanged.

## Unified HTTP API cutover

Upgrade controller and runners/CLI together to this revision; old HTTP paths have no aliases. Stop the old runner before replacing its binary, retain its state directory and installation/journal, upgrade the controller against the existing database, then start the matching runner. The controller initializes configuration repository identity before accepting HTTP; reading its revision no longer bootstraps durable state. No schema reset, journal deletion or observation rewrite is required. Existing migration startup remains authoritative.

Runner exchanges now use `/api/v1/runner/{control,inventory,observations}`. Update any operator-managed gateway path policies together with the deployment. Resource reads use `{data,meta}`, errors use `{error:{code,message,details?},request_id}`, and scheduled assignment settings are read/written through `/api/v1/assignments/:id/configuration`. See the complete [route disposition table](API-ROUTES.md). Buffered reports keep their original identity, age, session and generation; replays must continue to produce their original receipt or historical disposition.
