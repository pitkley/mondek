# Acceptance coverage

This inventory maps the maintained commands in [scripts/mondek](../scripts/mondek) and the [browser harness](../tests/browser/run.py) to the checked-in [CI workflow](../.github/workflows/ci.yml). Run every command below through `devenv shell --`. The workflow runs on main pushes, pull requests and manual dispatch. Its presence alone is not evidence that a hosted run has passed. See [the acceptance guide](../tests/e2e/README.md) for workload and cleanup boundaries.

See [the CI entry guide](CI.md) for job failures, retained evidence and the image build graph.

## Default CI

The **Unit tests and checks** (`checks`) job runs locked Python and PostgreSQL tests, static/installed-SDK checks, license/credit policy and Hex advisory auditing in one cached `ci` devenv profile, with the pinned language runtimes and editor servers disabled. It uses devenv 2.3.1 and a 35-minute limit. See [license collection](LICENSING.md).

The **Integration and browser tests** (`integration`) job uses Python/uv and Docker directly, with no Nix setup. One Bake graph builds seven distinct images for full coverage, or four for smoke. Exact-image license audits and all Compose/browser harnesses reuse recorded immutable image IDs with rebuilding disabled. Missing or mismatched images fail. Python worker and fixture images precompile bytecode at build time so repeated non-root worker/health processes reuse their imports. Per-image BuildKit caches persist between runs; exported intermediate build cache is pruned before testing while loaded images remain. On the disposable GitHub-hosted packaged runner, remove only the unused preinstalled Android SDK and record disk usage, leaving headroom for Docker and real filesystem-capacity scenarios.

Both jobs use Ubuntu 24.04 and commit-pinned Node 24 JavaScript actions. Packaged smoke has a 25-minute limit, manual full has a 90-minute limit, and manual browser mode has a 60-minute limit; heavy suites execute sequentially against isolated Compose projects. Independent suite failures retain their timings and allow the other suites to run, then fail the job together; image/license admission failures stop before behavioral testing. PRs and main pushes select smoke; manual dispatch also defaults to smoke. Deliberately select manual full mode for all fifteen service acceptance and seventeen browser suites. To investigate browser failures, select browser mode and provide space-separated names in browser_suites, for example inventory coverage; blank selects all browser suites. Browser mode omits service acceptance, builds the full image graph once, and records each selected suite separately. Unknown or duplicate names fail. Every mode retains all native and licensing gates. Superseded runs are cancelled, and branch pushes outside main do not duplicate PR runs. No scheduled full runs are configured.

| Command | Implementation and coverage | CI coverage |
| --- | --- | --- |
| `mondek test` | Locked runner, harness and installed-consumer Python tests; PostgreSQL controller/LiveView tests and asset build | `checks`, every mode |
| `mondek acceptance` | `tests/e2e/acceptance.py`: real installed workers, controller, PostgreSQL and local receiver; collection, preparation, configuration, outages, original-age retry, restart, partial evidence and text admission | `integration`, smoke/full |
| `mondek gateway-acceptance` | `tests/e2e/gateway.py`: two independent observers through local TLS; revoke one credential, verify peer collection and retained coverage, restart with buffered evidence, rotate the private header file and inspect restored current measurements | `integration`, smoke/full |
| `mondek check` | Native formatters, Ruff, installed-wheel consumer typing with Pyright, shell syntax/ShellCheck, actionlint and strict offline zizmor workflow audits, Nix/Compose checks, coordinated dependency/resolved-toolchain pins and browser JavaScript syntax | `checks`, every mode |
| `mondek parity-acceptance` | `tests/e2e/parity.py`: independent node/service observers, source deployment/recovery, buffered transport and 500 additional real file results | `integration`, full |
| `mondek placement-acceptance` | `tests/e2e/placement.py`: one consumer on three observer contexts, capability/access selection, cross-environment results, custom policy failure, withdrawal and reconnect | `integration`, full |
| `mondek consumer-acceptance` | `tests/e2e/consumers.py`: installed node/Prometheus starters, actual files/processes/scrapes and threshold failures | `integration`, full |
| `mondek discovery-configuration-acceptance` | `tests/e2e/discovery_configuration.py`: real reviewed local/host selection, two hosts/three observers, masking, re-inclusion/history, outage, failed scan and restart with desktop/320/390px Chromium checks | Focused local qualification; not yet in a hosted CI suite |
| `mondek linux-acceptance` | `tests/e2e/linux_pack.py`: two installed Linux pack observers, native/kernel-fixture evidence, failures/recovery, restart, exact buffered replay and Chromium shared-policy walkthrough | `integration`, full (includes its own browser run) |
| `mondek starter-acceptance` | `tests/e2e/starter.py`: fresh generated project, delegated settings, source retirement and recovery | `integration`, full |
| `mondek rules-acceptance` | `tests/e2e/durable_rules.py`: durable rules, moving targets, conflicts, schema recovery and offline adoption | `integration`, full |
| `mondek policy-acceptance` | `tests/e2e/policy.py`: declarative CLI ownership, replay, exceptions and real runner adoption | `integration`, full |
| `mondek configuration-acceptance` | `tests/e2e/configuration_repository.py`: durable configuration Git history, authenticated fetch/push, conflict/replay and real runner adoption | `integration`, full |
| `mondek acknowledgement-acceptance` | `tests/e2e/acknowledgements.py`: acknowledgement lifetime, expiry, restart, recovery and held delivery | `integration`, full |
| `mondek maintenance-acceptance` | `tests/e2e/maintenance.py`: one-off/weekly windows, overlapping holds, restart, delivery and moving targets | `integration`, full |
| `mondek grouped-acceptance` | `tests/e2e/grouped.py`: shared incidents, independent contributors/controls, recovery and durable delivery | `integration`, full |
| `mondek coverage-acceptance` | `tests/e2e/coverage.py`: declarations, missing placement, independent evidence and catalogue recovery | `integration`, full |
| `mondek publisher-acceptance` | `tests/e2e/publishers.py`: reviewed retirement/replacement, fencing, restoration and retained evidence | `integration`, full |
| `mondek browser` | `tests/browser/run.py`, default `--suite all`; actual Chromium operator workflows, reconnects, desktop/narrow layouts and whole-page axe scans | `integration`, full; empty/lifecycle also in smoke; selected suites in browser mode |

Each row below is also a focused command: `python3 tests/browser/run.py --suite NAME`. All are included by `mondek browser` in full CI; a focused local run does not imply the others ran.

| Suite | Main workflow |
| --- | --- |
| `lifecycle` | Measurement/configuration detail, failure/recovery, notification retry, original findings and reconnect |
| `diagnostics` | Datasource failure versus controller transport, original-age evidence and investigation navigation |
| `monitoring-loss` | Sustained missing evidence, acknowledgements, maintenance, actual controller restart and restoration |
| `fleet` | Fifty registered observers with real history, at most twelve live, runner inspection and delivery retry |
| `empty` | Empty onboarding, code-first project setup, copyable agent guidance and packaged credits |
| `parity` | 511-result inventory, independent observers, large target selections and 500-scope navigation |
| `bulk` | 500 compatible configurations, concurrent edits, offline adoption and real threshold failures |
| `rules` | Shared-rule preview, conflicts, exceptions, reconnect and source-default fallback |
| `policy` | Code-owned policy, ownership transitions, instance exceptions and adoption |
| `acknowledgements` | Long/until-ended holds, revisions, expiry, reconnect and resumed delivery |
| `maintenance` | Explicit check/target selections, timezone boundaries, recurrence, conflict review and cancellation |
| `inventory` | List / By group, exact-target expansion, observer independence, stale evidence and recovery |
| `grouped` | Shared incidents, late contributors, acknowledgement scope and independent evidence |
| `coverage` | Declared scopes, missing observers, unresolved declarations and preserved navigation |
| `publishers` | Reviewed retirement/replacement/restoration with retained history and reconnect |
| `discovery` | Installed filesystem evidence, reviewed source-change prompts, stale candidate rejection and narrow layouts |
| `check-groups` | Two installed observers, 140 results, 107 groups, local search/loading/reconnect and real source regrouping with retained incidents |

## Intentional manual coverage

| Command | Why outside default CI; when to run |
| --- | --- |
| `mondek capacity` | Isolated 500-result / 50-function workload and reconnect cohort. Complements the combined parity workload; use when changing scheduling, spool or scale behavior. |
| `mondek capacity-checks` | Isolated 500 separately scheduled functions. Browser `bulk` also uses 500 checks, but does not replace this exact reconnect/cohort evidence; use for scheduler/preparation/transport changes. |
| `mondek soak` | Bounded ten-minute churn/restart/reconnect run by default, configurable to 60–3600 seconds. Adds deliberate sustained runtime; run for lifecycle/transport changes and before wider operation. It does not establish unattended lifetime. |
| `mondek acceptance-amd64` | Explicit Linux/AMD64 packaged run with architecture assertions; redundant architecture selection on the workflow's x64 host. Use on ARM development hosts before deployment-related changes, noting emulation is not native-host performance evidence. This command does not run native tests. |
| `python3 tests/performance/run.py` | Controlled empty/idle/active one- and twelve-runner profiling. Shared hosted variability makes it unsuitable as a timing gate; use after runner/control/sweep changes on a quiet Docker engine and record hardware/workload. See the [profiling harness](../tests/performance/run.py). |
| `cd controller && PGPORT=55433 MIX_ENV=test mix test profiles/retention.exs --trace` | Destructive isolated-test-database retention profile with concurrent real ingestion. Choose 10k/100k aged receipts; timings are diagnostic rather than a shared-host CI gate. Normal native tests cover batching/protection correctness. See [retention](RETENTION.md). |
| `mondek study`, `mondek study-reset`, `mondek study-monitor` | Human operator study setup, not unattended acceptance. Participant understanding and accessibility cannot be inferred from browser assertions. |

Persistent `start`, `demo`, `parity`, `placement`, `rules`, `grouped`, `coverage`, `publishers` and `bulk` commands are operator/demo launchers, not additional verification suites. Their paired stop/down commands preserve volumes. `doctor`, `setup`, `assets`, service inspection are environment/build/deployment helpers, not substitutes for end-to-end acceptance. No default CI command accesses a private consumer, remote server or external notification recipient.

## Runtime, resources and evidence

The private CI rehearsal measures a 247-second cold seven-image build and 90–98 seconds with restored caches. Smoke passes in 10m07s including setup, native checks and packaged verification. The full native job passes in 7m26s. All fifteen service acceptance suites pass in 42m01s, but the complete packaged job reaches its 90-minute limit (90m54s including evidence upload/cleanup). Ten browser suites pass; monitoring-loss, parity, bulk, acknowledgements and inventory fail, coverage is interrupted and publishers does not start. Evidence survives cancellation. This is partial hosted qualification, not a passing full run. The saved failures prompted the selected qualification recorded below; do not increase deadlines to conceal contention. These are individual hosted measurements, not guaranteed budgets.

Subsequent selected hosted runs close those seven failed/unfinished browser scopes: acknowledgements, monitoring-loss including restart, coverage and publishers pass in the first; all five inventory journeys pass in the second; parity and bulk pass in the final run. Final native checks pass in 9m25s (787 controller, 319 runner, 101 consumer and 65 harness tests, with static/installed-SDK/license/advisory gates). The final packaged job passes in 15m00s: five parity journeys take 3m30s including 31s to establish all 511 fresh results; the complete 500-check bulk journey takes 7m50s including 136s readiness. Both retain all accessibility/layout assertions, have zero skips/retries and clean up successfully; exact AMD64 image audits pass. These are selected results across recorded revisions, not a new exhaustive run of the latest tree.

Local evidence is useful for budgeting, not a hosted performance guarantee: previous 511-result and 500-check browser runs each took about seven minutes excluding some build/startup work. Full service/browser coverage is therefore tens of minutes of deliberate failure, outage and recovery work. The smoke subset retains core acceptance, TLS gateway/restart and empty/lifecycle browser journeys. Preserve per-scenario deadlines rather than extending them to hide resource contention.

Run heavy suites sequentially locally and stop only this work's unused demos, retaining their volumes. The fleet suite deliberately limits simultaneous active runners to twelve after fifty live runners exceeded measurement deadlines on the development VM; fifty registered histories are not proof of fifty-runner production capacity. Native and packaged work use separate CI hosts. Service and browser suites run sequentially on the packaged host; this avoids simultaneous heavy-suite contention without guaranteeing adequate resources for every workload.

The parity browser suite applies [a scale overlay](../tests/browser/compose/scale.yaml) with one worker per runner, leaving CPU for Chromium and controller processing. Bulk retains its original three workers. Both establish their complete real measured fixtures before launching Chromium, with a separate 240-second readiness bound and five-second fleet-count polling. Require 511/500 declared and fresh results; save readiness samples and fail if the fixture cannot establish. This separates fixture setup from each operator journey's existing deadline and adds that bounded setup phase to the suite. All check counts, intervals, freshness bounds, worker deadlines and UI timeouts remain unchanged. Service acceptance and standalone capacity profiles retain their configured concurrency. Shared-host timings are not capacity guarantees.

Disposable harnesses retain `.local/acceptance/` or `.local/browser/` results, platform metadata, logs and cleanup status; browser artifacts also contain viewport screenshots, whole-page axe/layout results and failure traces. Video is opt-in via MONDEK_BROWSER_VIDEO=retain-on-failure; routine runs avoid encoding it. Scale suites also retain measured fixture-readiness samples. CI uploads these with image identities, exact-image license reports and packaged stage timings as `packaged-evidence`; native stage timings are `native-evidence`. Abrupt job cancellation or machine termination can prevent normal cleanup/upload, so inspect failure logs as well as the final status. Local `mondek test` uses the separate `mondek-tests` database project and leaves it running; stop it explicitly when finished, preserving its volume. CI removes only its own disposable native database and volume in an always-attempted cleanup step. Normal installation volumes are never reset by these suites.

## Maintaining this map

When adding or renaming a maintained acceptance command or browser suite, update its workflow invocation or intentional exclusion here. Verify the actual `scripts/mondek` dispatch and browser parser/default list, not just documentation mentions. Record local and hosted test results separately, including source revision, workload and limitations; a historical passing run does not establish that every current suite has passed.
