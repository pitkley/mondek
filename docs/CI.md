# CI: tests, checks and test images

[The CI workflow](../.github/workflows/ci.yml) has two independent jobs. Pull requests and main pushes run both; other branch pushes do not create duplicate runs. Validation has read-only repository permissions and does not publish packages or images.

| Job | What it checks | When it fails |
| --- | --- | --- |
| **Unit tests and checks** (`checks`) | Python/Elixir unit and PostgreSQL tests, formatting, static analysis, installed SDK typing/package checks, locked dependencies, licenses/credits and Hex advisories | Open the named stage and its command output; download `native-evidence` for command timings |
| **Integration and browser tests** (`integration`) | Exact built-image license audits, real server/runner/TLS/restart scenarios and Chromium accessibility/UI journeys | Build failures point to a Dockerfile stage; test failures have named suite logs and reports in `packaged-evidence` |

The job summary records each stage's exact command, result and duration. Timings exclude workflow setup and image builds, which have their own step durations. `.local/ci/` holds timings, immutable image identities and audit reports; `.local/acceptance/` holds service evidence and `.local/browser/` holds Playwright reports, screenshots and application snapshots. Artifacts are retained for seven days, including on failure. A failed image/license admission stops before testing; independent behavioral suites continue to collect evidence, then fail the job together.

## Toolchain and cost

Only the unit/check job installs Nix and devenv, using pinned devenv 2.3.1 and the binary cache. Its `ci` profile uses the committed language pins without editor servers; dependency caches are reused between runs. The integration job uses Python, uv and Docker directly. Entering a local devenv shell starts no services, installs no project dependencies and generates no secrets.

Default **smoke** coverage runs the core service scenario, TLS gateway/restart scenario and the empty/lifecycle browser suites. It is the normal PR check, with 35-minute unit/check and 25-minute integration limits. Manual dispatch defaults to smoke too. **Browser** mode selects named suites (blank means all) and has a 60-minute integration limit. **Full** mode explicitly selects all fifteen service and seventeen browser suites and has a 90-minute integration limit. Native/check coverage is unchanged across modes. Superseded runs on the same ref cancel automatically; there is no scheduled full run. See [the coverage map](ACCEPTANCE-COVERAGE.md) for exact suite boundaries.

## Why Docker Bake and Compose both exist

`tests/ci/docker-bake.hcl` is the image build graph, not another application deployment. Its `smoke` group builds four inputs; `full` builds seven:

| Image | Purpose | Smoke | Full/browser |
| --- | --- | --- | --- |
| `controller` | Packaged Mondek server | Yes | Yes |
| `runner` | Sample Python runner | Yes | Yes |
| `fixture` | Local target and notification receiver | Yes | Yes |
| `browser` | Chromium/Playwright test driver | Yes | Yes |
| `consumer` | Installed node/Prometheus consumer examples | No | Yes |
| `node` | Controlled Linux host fixture | No | Yes |
| `fleet` | Many independent runner processes | No | Yes |

The flow is **Bake → record image IDs → audit those images → Compose service/browser suites**. Bake builds each image once, restores/saves its own BuildKit layer cache and loads it into the local Docker engine. `scripts/ci.py images` records immutable config digests in `.local/ci/images.json`. The workflow prunes exported build-cache space while preserving loaded images. `scripts/ci.py packaged` audits the controller/runner filesystems and passes that manifest to the acceptance harnesses.

Compose describes services, networks, ports and isolated test volumes. During CI the harnesses substitute the recorded images, disable rebuilding/pulling, and reject missing or changed identities. A tag alone is not sufficient evidence: audits and tests must refer to the same immutable image. Each suite removes only its own Compose project and test data. Registry publication is outside this workflow.

## Local entry points

Use ordinary `mondek test`, `mondek check` and `mondek licenses-check` for focused local verification. `devenv --profile ci shell -- python3 scripts/ci.py native` exercises the unit/check dispatch. Use the [coverage map](ACCEPTANCE-COVERAGE.md) for individual real-service/browser commands; running all modes locally is unnecessary for a small change. The internal phase names `native`, `images` and `packaged` in the dispatcher describe tool execution; GitHub presents the job names above.

If branch protection is configured, require **Unit tests and checks** and **Integration and browser tests**, replacing the earlier job names. Renaming a workflow alone does not update repository rules.

## Release qualification

The separate [release workflow](RELEASING.md) calls this CI workflow with prepare_release=true. Only that path prepares a retained SDK pair before the installed-package gate and bypasses the native dependency-cache restore. Normal push/PR CI remains nonpublishing. The release workflow subsequently tests both native image architectures against the original SDK and exports those exact images for gated promotion; it never builds application code inside a registry publishing job. Qualification itself stores private GitHub Actions artifacts, so a local-only/no-upload request also excludes launching that hosted workflow.
