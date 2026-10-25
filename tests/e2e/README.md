# End-to-end acceptance

Run `devenv shell -- mondek acceptance` from the repository root. It runs native Python and PostgreSQL/LiveView tests, then [acceptance.py](acceptance.py) builds a clean randomly named Compose project and executes collection, failures, recovery, configuration, restart and notification scenarios through the real controller, Linux runner, PostgreSQL and local HTTP target/receiver.

The local fixture provides deterministic failure controls and an ingestion proxy that can drop a response after the controller commits. The harness inspects both controller state and the runner's durable journal, and checks real receiver receipts. It stops/restarts only its own containers, deletes only its own volumes, and preserves evidence under `.local/acceptance/<project>/`. A failure retains completed-step results and bounded service logs before cleanup.

Reconnect samples the runner's bounded spool throughout controller restart while collection continues. Atomic journal snapshots record original payloads, session identity, and loss counters; reconciliation requires admitted evidence sampled before controller readiness and accounts for later eviction. The artifacts include `disconnect-offline.json`, `disconnect-spool-samples.jsonl`, and `disconnect-reconciliation.json`. Native harness regressions reject changed payloads, unexplained loss, and a false pass based only on newly collected post-reconnect evidence.

## Runner-owned monitoring

`devenv shell -- mondek gateway-acceptance` exercises two independent node observers through an owned TLS gateway and real controller/PostgreSQL. One private header file is rejected while its peer continues measuring; the denied runner becomes stale, keeps original evidence in its journal and restarts with the same installation. Replacing its credentials restores registration and upload, preserves the complete pre-restart payloads and original ages, and produces new-session fresh evidence and secret-safe recovery logs. The harness retains its exact journal cohort, stored observations and structured events before removing its project and volumes. It uses disposable local test credentials and a generated test certificate; it does not contact Cloudflare, run systemd, emulate network namespaces on the Pi or establish that live Backrest measurements are correct.

`devenv shell -- mondek coverage-acceptance` covers pre-selection declarations with installed consumers: never-installed nodes, environment exclusions, new eligibility, independent Critical/unavailable/stale evidence, complete source withdrawal, rejected discovery, public versus private revisions and original-age replay after real controller/runner restart. It requires new post-deployment measurements to prove accepted-code fallback. All measurement sources and notification recipients are owned local fixtures; no external monitoring is changed.

`devenv shell -- mondek acknowledgement-acceptance` covers incident acknowledgement lifetimes with packaged services: indefinite holds across controller restart, independent maintenance, long durations, stale cancellation, shortened explicit expiry, severity ceilings, recovery and existing notification retries. See [acknowledgements](../../docs/ACKNOWLEDGEMENTS.md).

`devenv shell -- mondek maintenance-acceptance` covers future and long one-off windows with packaged services: activation across restart, exact shortened expiry, overlapping windows and acknowledgement, cancellation, existing retries, truthful recovery and a stable target moving between observers. See [scheduled maintenance](../../docs/MAINTENANCE.md).

Run these commands sequentially, with the persistent demos stopped to avoid competing workloads:

```sh
devenv shell -- mondek parity-acceptance
devenv shell -- mondek consumer-acceptance
devenv shell -- mondek capacity-checks
devenv shell -- mondek browser
devenv shell -- mondek soak
```

`parity-acceptance` covers dedicated Prometheus and node-local runners, source changes and failed imports, withdrawal/restoration, independent target failures, buffered transport across restart, and 500 additional real file results. Its additive-schema deployment preserves operator values and history, measures a newly defaulted field, rejects an incompatible replacement and restores an accepted deployment. `capacity-checks` measures 500 separately scheduled functions; `capacity` groups the same number of results into 50 functions. Both capacity modes require an original offline report from every scheduled check to survive restart, commit unchanged, be acknowledged, and give way to fresh new-session evidence.

`consumer-acceptance` runs locked installed packages against ordinary files, a real process/PID file and Prometheus. It tests file absence/size/age/permissions, process stop/restart and invalid PID input, target rebinding, failed scrape/recovery, malformed replacement settings with retained executable snapshots, and several resources on one node. Its two-query local CLI proof retains original batch evidence with `--results` and is explicitly separate from controller ingestion. A numeric metric runner separately crosses warning and critical equality boundaries through the controller, preserves actual Prometheus sample times, recovers and retains edited thresholds across restart. Peer continuity requires execution after each recorded fault boundary, not merely late arrival of earlier measurements.

The [browser suite](../browser/README.md) covers the real UI, including exact compatible bulk saves, reconnects, concurrent edits, and actual notification delivery/retry. `soak` repeatedly alternates source churn with scoped outage/restart/retry for ten minutes by default. All destructive operations are confined to their randomly named Compose projects; artifacts remain under `.local/acceptance/` or `.local/browser/` after cleanup.

## Installed image and SDK

`devenv shell -- python tests/e2e/install.py --image LOCAL_CONTROLLER_TAG` exercises deploy/compose.yaml under a unique project with only controller/PostgreSQL services. It builds and installs the SDK wheel into an isolated environment outside the checkout, generates and installs a monitoring project, measures live input, verifies firing/recovery mail against an owned local SMTP receiver, and recreates the controller while preserving its database, runner identity and configured retention. It deletes only its own project/volume. CI smoke/full modes use their exact prebuilt controller image. This qualifies local packaging; public registry consumption remains a separate release check.
