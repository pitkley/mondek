# Packaged consumer-state qualification

The focused [packaged harness](../tests/e2e/consumer_state_packaged.py) qualifies the 0.0.5 candidate controller against an existing published 0.0.4 installation. It uses the production [Compose recipe](../deploy/compose.yaml), packaged automatic migrations, separate installed old/new SDK wheels, and an owned HTTPS gateway. It never pushes images, wheels or branches.

## Reproduce

Build a local candidate from the checkout, then run the focused harness through devenv:

```sh
devenv shell -- docker build -f controller/Dockerfile -t mondek-state:qualification .
devenv shell -- python3 tests/e2e/consumer_state_packaged.py --image mondek-state:qualification
```

The default baseline is an already available local `ghcr.io/pitkley/mondek/controller:0.0.4` image. Use `--baseline-image` to select another local reference and `--baseline-ref` to select the corresponding old SDK source when the image has no revision label. Both controller images are resolved to immutable local image IDs before starting; neither controller tag is pulled or replaced. The harness pulls only the pinned PostgreSQL dependency. The baseline must have migrations `1` and `20261115150000` with no consumer-state entry table; an incompatible baseline fails explicitly.

The old SDK wheel is built from the baseline image's labelled Git revision, and the new wheel from the checkout. Both are installed into separate temporary environments, along with a small installed consumer built using the pinned `uv_build` backend. Runner subprocesses use isolated Python mode; package provenance records verify SDK imports from site-packages rather than checkout/PYTHONPATH imports. No SDK or consumer is installed into the operator's environment.

Each run has a unique Compose project, database volume, private temporary deployment/auth files, test certificate and local SMTP sink. Inherited Mondek, PostgreSQL and SMTP settings are excluded so operator credentials or recipients cannot override the disposable setup. All cleanup steps are attempted independently, with failures recorded. Only that run's containers, network and volume are removed; ordinary development installations remain untouched.

## What is asserted

1. Two old-SDK observers create real Critical measurements and incidents on the old packaged controller. A delegated threshold is edited and measured, creating saved configuration and configuration Git history.
2. After stopping the old writers, the harness captures complete immutable observation/configuration/Git rows and selected stable runner, assignment, stream and incident fields. Counts alone cannot establish preservation.
3. The old controller stops and the candidate starts against the same PostgreSQL container and volume. Its normal entrypoint applies the three additive 0.0.5 migrations for state, correlations and case delivery (`20261116120000`, `20261116120100`, `20261116160000`); all captured monitoring/configuration rows compare equal before any new runner starts. No manual migration, schema reset or migration-record editing occurs.
4. Two installed candidate-SDK runners execute real checks through certificate-verified HTTPS. Their state checks publish/read an unpredictable shared nonce and maintain distinct assignment-local roles. Fresh result summaries must demonstrate that exact shared value; gateway records must show successful forwarded state POSTs.
5. Missing and incorrect gateway credentials each receive 403 without forwarding a mutation. An authenticated SDK read confirms the denied key is absent.
6. Writers stop before capturing all live state rows and namespace accounting. A second controller recreation applies zero migrations and preserves exact IDs, values, versions, writer identities, update/expiry timestamps and quota counters. A long-TTL key retains its original expiry. SDK reads agree before/after restart; CAS with the retained version succeeds once and a stale retry conflicts.
7. Restarted runners produce state-derived measurements with original source timestamps later than the restart boundary. Retained fresh evidence from before restart cannot satisfy this gate.

Evidence is retained outside Git under `.local/acceptance/mondek-state-packaged-*/`: image/platform and schema results, SDK wheel hashes/import paths, source provenance, pre/post upgrade rows, startup logs, pre/post restart state/accounting, SDK readbacks, resumed measurements, safe gateway records and cleanup status. Credentials and certificate private keys remain in temporary private files and are removed at completion. The helper regression suite rejects changed data with unchanged counts, pre-restart evidence, inherited operator notification settings and skipped cleanup after failures.

The maintained harness now defaults to published 0.0.4 as the pre-state baseline; 0.0.3 and 0.0.4 have the same two-migration schema. The historical result section records the earlier state-only qualification and does not establish a full 0.0.5 upgrade pass.

## 0.0.5 preparation qualification

The 2026-11-17 Linux/ARM64 run passed from published 0.0.4 image `sha256:5d8368a96fe65c433d9648dbe2b4a06d4b22a31d9aae0d7a1399eae2e41610e2` (source `57607a1720ebf4ff888259f14829a3680f8e24f8`) to local 0.0.5 candidate `sha256:4e94eb3950bf23b63d176db6de158d13eef738d45e0b1d3ec8694b60897d0c4c`, built from `cd8f873` with the release version bump. Packaged startup applied all three new migrations and recreation applied none. Exact retained data checks preserved 7 observations, 3 configurations, 2 configuration revisions, 7 configuration Git objects, and 2 each of assignments, streams, runners and incidents.

All four state entries and accounting survived restart. Authenticated state traffic, both denied mutation controls, post-restart CAS and newly executed state-derived measurements passed. Task-owned cleanup completed. Evidence is under `.local/acceptance/mondek-state-packaged-13029d7077/` in the preparation checkout. This qualifies that local ARM64 candidate and the state upgrade/restart/gateway path; it does not qualify AMD64, all case-delivery behavior or the eventual published artifacts. Release CI and native architecture qualification remain required.

## Historical local result

The 2026-11-16 qualification passed on Linux/ARM64 using baseline image `sha256:8e618c8cbfe171963dabe806d2b6932b1320d50a29cbb96f258d8c4a38654ba1` and candidate image `sha256:6f2a7de34c433f7c3714ae12ef6bfcc7a9302c37eb188c65e530458e264c6a5e`, built from state implementation commit `11e18be`. The baseline revision `1489e55937ea0b86a7905674c3a2d545af05ed31` has the same controller/runner source as pre-state parent `d612233`.

The final run retained 8 observations, 3 configurations, 2 configuration revisions, 7 Git objects, and 2 each of assignments, result streams, runners and incidents across upgrade. All 4 state entries and their accounting survived recreation. Startup applied one migration on upgrade and zero on restart. Authenticated state read/write and post-restart CAS passed; both unauthorized writes were denied without forwarding. Task-owned cleanup completed. The 82 acceptance-harness regression tests and Ruff checks passed.

GPT-6 Astra reviewed the approach and recorded evidence. Its requested environment isolation, independent cleanup, stronger evidence retention and subprocess lifetime fixes were incorporated before the final passing run. No production controller/SDK defect was found during this qualification.

This qualifies the built ARM64 package, installed wheels and a local certificate-verified header gateway. It does not establish AMD64 behavior, a particular external gateway provider's policy, deployed firewall/origin isolation, host service-manager behavior, or unattended operation. It is a deliberate focused local qualification, outside routine CI because it requires a locally available pre-state release image and its Git source. No publication or deployment approval is implied.
