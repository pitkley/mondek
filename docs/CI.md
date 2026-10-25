# CI: tests, checks and test images

[The CI workflow](../.github/workflows/ci.yml) has two independent jobs. Pull requests run both directly; main pushes run both once through the [release workflow](RELEASING.md), alongside image qualification after shared SDK preparation. GHCR `edge` publication waits for CI and image qualification to succeed. Other branch pushes do not create duplicate runs. Validation has read-only repository permissions and does not publish packages or images.

| Job | What it checks | When it fails |
| --- | --- | --- |
| **Unit tests and checks** (`checks`) | Python/Elixir unit and PostgreSQL tests, formatting, static analysis, installed SDK typing/package checks, locked dependencies, licenses/credits and Hex advisories | Open the named stage and its command output; download `native-evidence` for command timings |
| **Integration and browser tests** (`integration`) | Exact built-image license audits, real server/runner/TLS/restart scenarios and Chromium accessibility/UI journeys | Build failures point to a Dockerfile stage; test failures have named suite logs and reports in `packaged-evidence` |

The job summary records each stage's exact command, result and duration, distinguishing elapsed wall time from summed command time when stages overlap. Timings exclude workflow setup and image builds, which have their own step durations. `.local/ci/` holds timings, separate command logs, immutable image identities and audit reports; `.local/acceptance/` holds service evidence and `.local/browser/` holds Playwright reports, screenshots and application snapshots. Completed command logs are replayed as separate Actions groups; logs remain available in the evidence artifact if a command is interrupted. Artifacts are retained for seven days, including on failure. A failed image/license admission stops before testing; independent behavioral suites continue to collect evidence, then fail the job together.

## Toolchain and cost

Only the unit/check job installs Nix and devenv, using pinned devenv 2.3.1 and the binary cache. Its `ci` profile uses the committed language pins without editor servers; dependency caches are reused between runs. The integration job uses Python, uv and Docker directly. Entering a local devenv shell starts no services, installs no project dependencies and generates no secrets.

Native CI prepares dependencies, assets and the test database once, then overlaps the sequential Python suites with one controller test process. It waits for both lanes before code/package checks and advisory auditing. Controller database cases remain serial within that process. Ordinary `mondek test` keeps its sequential local behavior; the explicit `test-prepare`, `test-python` and `test-controller` commands expose the same phases for CI.

After image/license admission, packaged smoke overlaps core acceptance with a second lane containing installed image/SDK acceptance, gateway acceptance, empty browser and lifecycle browser in that order. Both lanes reuse the same loaded images but use separate Compose projects, volumes, evidence directories and Docker-assigned host ports. Suite failures do not cancel the peer lane or later packaged suites. Full and selected-browser modes remain sequential to avoid overlapping heavier workloads; browser journeys within each installation also remain sequential.

On disposable hosted runners, smoke skips Android SDK deletion when at least 60 GiB is available before building, retaining conservative headroom for image export and real filesystem checks. Below that threshold, and for full/browser qualification, the workflow removes only the unused Android SDK as before. Disk space is recorded before/after cleanup, build-cache pruning and packaged verification. The threshold is an initial conservative budget, not a measured peak-space guarantee.

Default **smoke** coverage runs the core service scenario, TLS gateway/restart scenario and the empty/lifecycle browser suites. It is the normal PR check, with 35-minute unit/check and 25-minute integration limits. Manual dispatch defaults to smoke too. **Browser** mode selects named suites (blank means all) and has a 60-minute integration limit. **Full** mode explicitly selects all fifteen service and seventeen browser suites and has a 90-minute integration limit. Native/check coverage is unchanged across modes. Superseded direct CI runs on the same ref cancel automatically; main publication runs serialize through the release workflow without cancelling an active promotion. There is no scheduled full run. See [the coverage map](ACCEPTANCE-COVERAGE.md) for exact suite boundaries.

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

The separate [release workflow](RELEASING.md) prepares and retains the SDK pair in an independent job, then calls this CI workflow with prepared_release_sdk=true for main pushes as well as release qualification. That path downloads and verifies the original pair before the installed-package gate and bypasses the native dependency-cache restore. PR CI remains nonpublishing. In parallel with CI, the release workflow builds and tests both native image architectures against the same SDK and exports those exact images for promotion. Publication waits for CI and both architecture jobs to succeed; main pushes then automatically publish `edge`, while versioned releases retain their publication gates and also update `latest`. It never builds application code inside a registry publishing job. Qualification itself stores private GitHub Actions artifacts, so a local-only/no-upload request also excludes launching that hosted workflow.
