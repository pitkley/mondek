# Development quick reference

Requires Nix, devenv 2.3.1 or newer, and a running Docker engine (Docker Desktop or Colima on macOS). Devenv supplies language tools and Docker CLI/plugins; the engine is host-provided. Initial downloads/builds can take several minutes. Entering the shell does not install dependencies, start services or generate secrets.

```sh
devenv version
devenv info
devenv shell -- mondek doctor
devenv shell -- mondek setup
devenv shell -- mondek check
devenv shell -- mondek test
devenv shell -- mondek start
devenv shell -- mondek stop
```

`mondek start` creates a separate persistent empty installation at http://localhost:4001/guide. `mondek stop` stops it and preserves its data. Use `mondek local-status` and `mondek local-logs` to inspect it. `mondek demo` starts the separate sample installation; `mondek services-down` preserves its volumes.

Use `mondek help` for the small installation command set, and `mondek help development`, `mondek help examples` or `mondek help verification` for more. The [advanced Compose overlays](examples/compose/README.md) live under examples/; the root compose.yaml remains the common base.

Use [the acceptance coverage map](docs/ACCEPTANCE-COVERAGE.md) to select meaningful suites. Run native PostgreSQL suites serially; service/browser acceptance uses isolated Compose projects and removes only its own test data. `devenv shell -- python3 tests/browser/run.py --suite empty` verifies onboarding and packaged credits at desktop and narrow widths. Run `mondek browser` for all browser journeys.

After dependency changes, run `devenv shell -- mondek licenses` and review generated notices. `mondek licenses-check` rejects unapproved licenses, missing evidence and stale generated files. See [license collection and credits](docs/LICENSING.md) for coverage and remaining image/runtime inventory work.

Write checks in a separate consumer project using [the authoring API](runner/README.md), [installed examples](examples/consumers/README.md) and [the deployment guide](docs/RUNNER-DEPLOYMENT.md). Keep real secrets in operator-managed runtime configuration. Do not commit runtime data, credentials or acceptance artifacts.

Existing pre-publication installations should follow [the Mondek upgrade guide](docs/UPGRADING.md) to preserve database, runner and configuration history through the rename.

See [source installation and distribution](docs/DISTRIBUTION.md) for a portable consumer using a locally built SDK wheel and the remaining release gates.

[CI](docs/CI.md) runs native tests, static/package checks, locked dependency/credit policy and Hex advisories in one `ci` devenv profile, with the same language versions and no editor servers. The separate packaged job uses Python, uv and Docker directly. Docker Bake builds each required image once; image audits and isolated service/browser suites reuse the recorded immutable image IDs with rebuilding disabled. Layer caches persist between runs. Validation remains nonpublishing; main pushes prepare one SDK pair through the [release workflow](docs/RELEASING.md), run CI alongside both controller architecture qualifications, and publish `edge` to GHCR only after all gates succeed.

`mondek check` includes actionlint and the pinned zizmor workflow security audit, with strict input parsing and the auditor persona. The audit runs offline, without a GitHub token; checks requiring GitHub API access are outside this gate. Workflow actions use immutable commit pins, checkout credentials are not persisted, and validation receives only read permissions.

Pull requests and main pushes run packaged acceptance, TLS gateway/restart checks and empty/lifecycle browser journeys. Manual runs default to the same smoke subset. Explicitly select full for all fifteen service acceptance and seventeen browser suites; budget tens of minutes for this deliberate qualification run. Every mode retains native/license gates. Native and packaged stage timings, image identities, license inventories and failure evidence are retained as workflow artifacts. Locally, `devenv --profile ci shell -- python3 scripts/ci.py native` runs the native CI path; ordinary `mondek` commands keep their local build behavior.
