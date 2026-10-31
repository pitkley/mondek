---
name: mondek-runner-setup
description: Create or install a Mondek monitoring project and connect a persistent runner to an existing server, locally or in an explicitly requested deployment. Use for SDK packaging, runner identity and rollout; use the server and check-authoring skills for those separate tasks.
---

# Set up a Mondek runner

Locate the monitoring project and selected installed SDK release; documentation references are available in the matching repository documentation, not this skill's installation directory. Read docs/GETTING-STARTED.md, docs/DISTRIBUTION.md and docs/RUNNER-DEPLOYMENT.md. Determine the server address, source/SDK revision, execution location, data access and a unique durable state directory. A runner location is separate from the environment/target it monitors.

## Install the project

For a new project, install the selected qualified SDK distribution and run `mondek-runner init DIRECTORY`. The generated project pins that version from the registry; no source checkout or devenv is needed. Generation refuses an existing destination and does not start services or register checks. Lock and test the project, then use a non-editable installation for deployment. An optional --sdk-path is a contributor-only editable override. Before a registry release, use a qualified local wheel rather than assuming it has already been uploaded.

Run project tests, `mondek-runner validate --consumer MODULE:app` and a local `run --consumer MODULE:app --all --results` using the installed executable. These import/execute trusted project code and may access its configured datasources; use synthetic inputs first unless actual collection is authorized. Local run uses source defaults, not the server's saved settings. Exit zero means collection completed, not that every result is healthy.

For an existing project, preserve its source/check/output/target identities while updating imports/dependencies. Follow docs/UPGRADING.md for database and runner state-preservation requirements. Reinstall changed non-editable project/SDK packages explicitly; a same-version sync may otherwise reuse stale code. Validate replacements before stopping the accepted deployment, and retain the previous locked environment for rollback.

For explicitly authorized local datasource verification, use docs/SDK.md's private env-file recipe and select the intended check; keep credential values out of output/prompts. Match the project's editable/non-editable installation mode. This local run does not register monitoring or authorize a deployment.

## Connect and verify

Start one process using `MONDEK_CONTROLLER_URL`, the installed consumer and the chosen state directory. Reuse that directory after restart; never copy/share it to create a different runner or run two owners against it. Keep its SQLite journal, bundles and installation-local identity key together. Runtime fencing of an old snapshot under a changed SDK is intentional: prepare/adopt the new source normally rather than editing signatures or clearing state.

For a gateway, read docs/CONTROLLER-AUTH.md. Use an origin-bound private headers file and verify the actual inventory/control/report channels. `mondek-runner doctor` only probes reachability; its reachable_unverified result does not prove registration or accepted measurements. Keep private datasource settings and credentials runner-side; grant only the actual host/network access needed by the selected checks.

Verify complete expected inventory, fresh measurements at the adopted revision, and the distinct saved/prepared/active/measured states. Check failure and measured recovery on an authorized synthetic input with a local notification receiver. Restart the runner and confirm the same installation ID, a higher boot/session and fresh evidence. Retained health and successful control contact alone are not fresh collection. Check expected Coverage exclusions instead of silently dropping checks that cannot reach their datasource.

Hand over the exact installed artifact/source revision, service command, state path, access settings by name and observed results. Runner startup must not automatically apply global configuration policy. Explicit policy plan/apply is a separate reviewed operation. Do not remove old source monitoring merely by switching entrypoints; use the source-withdrawal workflow in docs/RUNNER-DEPLOYMENT.md when needed.
