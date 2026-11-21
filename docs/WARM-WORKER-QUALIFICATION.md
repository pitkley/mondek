# Warm-worker qualification

The trivial and Kubernetes GET fixtures qualified for opt-in warm execution on Docker Desktop's Linux ARM64 VM. The installed SDK was Mondek 0.0.9 from `d30b905`, with Python 3.13.15 and Kubernetes client 34.1.0. The VM had 8 vCPUs and 7.65 GiB of RAM. The comparison used image `sha256:43da3a30fae336ba8d7f12358f536290318829214fc1e21be41a46bbef8e890b`.

## Matched performance

The [installed comparison harness](../tests/performance/README.md#matched-warm-worker-comparison) validated 1,104 timed executions, using 46 assignments and three matched pairs at each workload and concurrency. Each warm burst used the broker for all 46 executions. CPU includes the driver, live broker, and reaped workers. The p95 values pool all three bursts for each backend.

| Workload | Concurrency | Exec / warm CPU per execution (ms) | Warm share of exec CPU | Exec / warm p95 wall (ms) | Exec / warm p95 queue (ms) |
| --- | ---: | ---: | ---: | ---: | ---: |
| Trivial | 1 | 72.18 / 10.23 | 14.2% | 80.03 / 10.60 | 3,142 / 418 |
| Trivial | 3 | 84.22 / 12.54 | 14.9% | 101.40 / 34.44 | 1,197 / 345 |
| Kubernetes GET | 1 | 227.96 / 13.40 | 5.9% | 259.46 / 14.19 | 9,897 / 556 |
| Kubernetes GET | 3 | 270.81 / 14.02 | 5.2% | 291.76 / 24.64 | 3,843 / 333 |

The trivial workload passed the one-third CPU gate and both absolute budgets of 23.8 and 26.9 ms. The Kubernetes fixture created a client during each execution and used an isolated loopback HTTP endpoint. The queue measurements reflect synchronized bursts in the harness.

| Workload | Concurrency | Cold warm startup and first preparation CPU / wall (ms) | All 46 exec preparations CPU / wall (ms) | All 46 warm preparations CPU / wall (ms) |
| --- | ---: | ---: | ---: | ---: |
| Trivial | 1 | 93 / 101 | 3,315 / 3,325 | 493 / 470 |
| Trivial | 3 | 51 / 73 | 3,277 / 3,288 | 487 / 457 |
| Kubernetes GET | 1 | 212 / 229 | 10,384 / 10,394 | 476 / 454 |
| Kubernetes GET | 3 | 172 / 192 | 10,460 / 10,468 | 507 / 479 |

Quiescent broker RSS after bursts was 28.1–28.2 MiB for trivial collection and 75.3–77.2 MiB for Kubernetes. The comparison container started at 7.1 MiB and peaked at 278.9 MiB across both workloads and backends, including the fixture server.

## Isolation and recovery

All 12 Linux regressions in `runner/tests/test_warm_pool.py` passed with the installed SDK in a network-isolated container with an init process. They exercised fresh globals and datasources, snapshot and installed-dependency validation after preload, unsafe import refusal, cancellation and descendant cleanup, deadlines and output overflow with partial evidence, broker and runner loss, and revision turnover. After broker loss, the existing report kept its identity and partial evidence, and a later execution used exec.

A separate installed Linux run passed 21 journal, worker-evidence and consumer-state tests, covering spool bounds, result capture, and cache expiry and invalidation. Run the warm-pool suite by mounting `runner/tests` read-only into the installed image and invoking `python -m unittest discover -s /qualification -p test_warm_pool.py -v`. Use Docker's `--init` to reap orphaned test descendants and `--network none` to keep fixture traffic on loopback.

Qualification covers these two fixture consumers on this ARM64 VM. Before enabling warm execution in a target deployment, validate its consumer's import and fork behavior and repeat the matched comparison on its hardware with representative authentication, network latency and load. See the [prototype opt-in and integrity contract](WARM-WORKER-PROTOTYPE.md).
