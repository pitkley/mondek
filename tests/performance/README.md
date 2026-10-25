# Bounded resource profiling

Run from the repository root with Docker running:

```sh
devenv shell -- python3 tests/performance/run.py
```

The default run measures a controller with no runners, then one and twelve idle or active real Python runners. Each case gets a fresh isolated Compose project and journals, waits for registration and initial fresh coverage, settles for ten seconds, then measures for 75 seconds. Active checks read one owned local file every thirty seconds; idle consumers publish an empty inventory. No browser is connected and no external datasource or notification recipient is used. Allow roughly eight to ten minutes for the five cases after image builds. Only the case's own containers and volumes are removed.

Use `--runners 12 --modes idle active --skip-baseline` for a focused comparison. `--seconds` accepts 60–180. Output remains under `.local/performance/` with metadata, before/after counters, SQL templates, request counts, measurement progress, logs, errors and cleanup status. SIGINT/SIGTERM attempt the same owned-project cleanup. A hard kill or daemon failure can still prevent cleanup; use the recorded project name and Compose files to inspect any remaining resources.

CPU is the difference between Linux cgroup cumulative usage counters, reported as seconds and percent of **one CPU core** over each service's actual sampling interval. Runner parent and reaped-child counters help attribute cost; live process counts do not count every short-lived process. Memory current is an endpoint sample; memory peak includes startup. A separate fifteen-request loopback transport benchmark records child CPU and wall time after the workload window. Its requests use the real deadline-protected helper but do not measure network latency to a remote controller.

PostgreSQL uses `pg_stat_statements` only inside the disposable profile project. The report retains SQL templates, not bind parameters. Statistics reset after the before-probes and are read before the after-probes; the actual SQL interval is recorded, with statistics-probe statements separated from workload totals. Database-wide counter deltas and service CPU samples include the small surrounding probes. Logging, the extension, thirty-second health checks and two resource samples remain fixed observer costs. Keep other local workloads consistent when comparing runs.

Every runner must retain its session and advance controller contact. Every active runner must deliver at least two complete, successful measurements whose original start, source, evaluation and receipt times fall within the measured window. Reserved journal sequence numbers and retained fresh evidence do not prove execution. The profiler also rejects reported loss, new diagnostics, missing journals, unexpected restart and an endpoint delivery backlog exceeding two reports per runner. The initial informational restart note is permitted if unchanged.

These are bounded local diagnostic workloads, not maximum-throughput tests or deployment capacity guarantees. They exclude expensive consumer code, large inventories, prolonged outages, retention growth and concurrent UI load. Record host architecture and Docker CPU/memory with any numbers; do not extrapolate one/twelve runners on a shared development VM into an AMD64 production sizing promise.
