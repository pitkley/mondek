---
name: mondek-server-setup
description: Set up or upgrade a Mondek server from an image or contributor source, including an empty local evaluation or an explicitly requested hosted deployment. Use for server installation, access and persistence; runner installation and Python check authoring have separate skills.
---

# Set up a Mondek server

Use the selected Mondek release documentation. Paths below are repository documentation references, available in the matching source or online; installing the image does not require a source checkout. Read deploy/README.md for the normal controller/PostgreSQL image recipe and docs/UPGRADING.md for state preservation.

## Choose the installation path

Determine whether the task is a new empty local evaluation, a new hosted installation or an upgrade. Reuse existing user decisions and authorization. Inspect the current services and state before changing an existing installation; a different Compose project or volume creates a different installation.

For ordinary installation, use deploy/compose.yaml with a private mode-0600 environment file. Run only the controller and PostgreSQL, choose the intended notification receiver explicitly, and preserve the database volume. Registry releases may still be pending: use a qualified local image when instructed, never assume an unpublished tag exists. A source-checkout evaluation using devenv is an explicit contributor alternative; the existing demo is not a normal installation dependency.

For a hosted installation, read docs/CONTROLLER-AUTH.md, docs/OPERATIONS.md and controller/config/runtime.exs. Use ordinary Docker/Compose with operator-managed settings. Establish the intended hostname, gateway and complete operator-origin protection, including /live WebSockets and direct-origin isolation. Deployment mode requires an HTTPS public origin, database password and a private session secret. Keep credentials on the host; never put them in Nix env, committed configuration or command output. Choose SMTP settings and a recipient explicitly; use an owned local mail sink during tests. Do not contact a real recipient without authorization. Runtime images built locally are distinct from permission to publish them.

For an upgrade, follow docs/UPGRADING.md. Preserve PostgreSQL, configuration history, runner state, credentials and exact rollback artifacts. Stop the old controller before migrations; do not run old and new controllers against the database together. Keep existing project/volume/role bindings, inspect the resolved configuration and retain complete backups before cutover. Do not reset state or alter stable monitoring identities to make the rename succeed.

## Verify and hand over

Check server health and the real guide/UI, not only a successful build. Verify the expected empty state or preserved inventory/history, persistent data after a normal restart, and reachable documented access through the chosen boundary. Distinguish local HTTP health from authenticated gateway access. Inspect licenses/credits in the packaged app.

Give the operator the source revision, addresses, start/status/log/stop commands and data locations. Local `mondek stop` preserves its data. Record what was actually observed and what remains operator verification; do not claim a migration or remote deployment from a local fixture. Hand off project/runner creation to mondek-runner-setup after the server is usable.
