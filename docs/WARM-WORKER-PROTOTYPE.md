# Opt-in warm workers on Linux

The installed runner profile identified interpreter and import CPU as the largest cost for trivial checks. This prototype tests an exec-launched, single-threaded broker for one authenticated snapshot revision. Enable it with `MONDEK_WORKER_BACKEND=warm` and an explicit `App(warm_worker_safe=True)` declaration. Exec remains available for ordinary consumers, other platforms and assignments that cannot obtain a warm slot. Store a true-only opt-in marker in the authenticated snapshot and bind it to the revision. Missing markers, including older snapshots, use exec. Check the reconstructed declaration before accepting a broker baseline.

## Baseline and child ownership

The broker verifies the manifest, source files, private settings and installed runtime, then constructs and restores the consumer and validates complete registration. It preloads only this authenticated baseline. Before each fork it reruns the same integrity verifier. A mismatch invalidates the broker and blocks the attempted collection. Check Linux thread and descriptor state after loading and before every fork. Additional persistent descriptors or threads reject the warm baseline. The opt-in requires import-safe code without open clients, native locks, background work or mutable state shared through files or descriptors.

The disposable child repeats the existing selected registration and authorization checks, including the full validation path for custom metadata overrides. Only the child uses assignment parameters, constructs datasource instances, creates an event loop and installs an execution watchdog. Keep the existing assignment lock, worker evidence encoder and result capture/validation path. Do not put an event loop, state client or execution context in the broker.

## Dispatch and lifetime

Use an inherited anonymous Unix seqpacket socket for bounded launch control. A small datagram transfers per-request assignment, stdout, stderr, launch-gate and status descriptors. The assignment and bounded execution context use separate size fields on the child input pipe. The assignment limit remains 4 MiB. Context, descriptor count and broker reply size have independent bounds. Close received descriptors on malformed requests or failed forks. Control carries no consumer output or secrets. Snapshot loading has a separate bounded readiness response, process output cap and preparation deadline.

Before acknowledging a launch, the broker puts the child in its own process group. The child closes unrelated inherited descriptors and waits for one explicit launch byte from the runner. EOF and deadline expiry abort before consumer execution. The runner closes the gate on every unsuccessful handoff. The runner learns the group identity before opening the gate and sending the assignment. The deadline starts at dispatch and includes verification, launch and collection. The child watchdog observes runner and broker death and kills its process group. The runner also kills the known group on cancellation, deadline, capture failure or broker loss. The broker closes inherited ownership and reaps each child, killing remaining group members before reaping the leader and reporting exit, independently of pipe EOF. Clean up process groups even if a descendant holds a pipe open.

A warm launch is irreversible once its request can reach the broker. A failed, cancelled or ambiguous launch leaves the allocated report incomplete with its original identity and available partial evidence. Later allocations may use exec; the same allocation is never retried. Integrity failure uses the existing authenticated exec path only for subsequent work, where the same fence still applies.

Reserve at most two resident revision slots. Reuse within the same verified revision and runtime identity. Retain references for startup, active/desired/prepared work and in-flight children until their ownership drains. Fall back to exec when slots are occupied, including while a third revision adopts. Close obsolete brokers when quiescent and keep restart attempts bounded with per-revision backoff. If a ready broker goes silent before launch acknowledgement, make it unavailable to new requests while independently supervised children finish. Preparation validates each assignment independently and remains separate from controller authorization. Broker readiness never adds time to an existing execution deadline.

## Qualification

Compare matched exec and warm on the same installed Linux image with 46 trivial or Kubernetes GET assignments at concurrency 1 and 3. Separate startup and assignment preparation. Include the live broker and reaped child CPU, record p95 queue and wall times and sample container memory. Require at most one-third of matched exec CPU for the trivial workload at both concurrencies before adopting this backend. Verify fresh child state, snapshot mutation, unsafe imports, timeout, output overflow, partial results, descendant cleanup, broker loss, runner loss, and revision turnover. Keep raw timing and test artifacts outside Git.

## Installed Linux results

The matched run used the installed SDK on the Docker Desktop Linux ARM64 VM with 8 vCPUs and 7.65 GiB of memory. The image was `sha256:590f39526cd1fb4849f665c6b88f4ee79f0bc78925142247fe28124ce2302ee7`. The Kubernetes workload used Python client 34.1.0 against an isolated local HTTP fixture. The run validated 1,104 timed executions with 46 assignments and three measured pairs at each workload and concurrency. Each warm burst dispatched 46 warm requests, and each exec burst dispatched zero.

| Workload | Concurrency | Exec CPU (ms) | Warm CPU (ms) | Exec / warm p95 wall (ms) | Exec / warm p95 queue (ms) |
| --- | ---: | ---: | ---: | ---: | ---: |
| Trivial | 1 | 70.95 | 10.01 | 76.70 / 10.03 | 3,090.69 / 412.39 |
| Trivial | 3 | 81.25 | 11.00 | 87.03 / 24.64 | 1,148.95 / 319.68 |
| Kubernetes GET | 1 | 227.64 | 13.33 | 248.37 / 14.66 | 9,895.19 / 553.64 |
| Kubernetes GET | 3 | 275.86 | 13.93 | 309.85 / 25.08 | 3,836.74 / 337.05 |

The trivial warm CPU was 14.1% and 13.5% of matched exec CPU, below both the one-third threshold and the earlier 23.8 and 26.9 ms budgets. Per-execution CPU includes the live broker and its reaped children. The warm broker stays resident during exec comparison bursts. Pooled p95 wall time starts at slot admission and queue delay starts at the common burst due time. The local Kubernetes endpoint excludes cluster work, TLS and remote network latency.

| Workload | Concurrency | Cold warm startup through first preparation CPU / wall (ms) | All 46 exec preparations CPU / wall (ms) | All 46 warm preparations CPU / wall (ms) |
| --- | ---: | ---: | ---: | ---: |
| Trivial | 1 | 72.7 / 88.8 | 3,520.0 / 3,530.5 | 466.3 / 442.7 |
| Trivial | 3 | 51.4 / 71.3 | 3,238.0 / 3,246.7 | 445.5 / 430.1 |
| Kubernetes GET | 1 | 181.5 / 198.7 | 10,476.0 / 10,485.3 | 475.8 / 446.2 |
| Kubernetes GET | 3 | 191.5 / 201.1 | 10,329.8 / 10,343.0 | 465.6 / 450.8 |

Quiescent broker RSS was about 27 MiB for the trivial workload and 74–76 MiB for Kubernetes. The whole measurement container grew from 7.39 MiB before Python to a 273.42 MiB peak across both backends. The local results cover one ARM64 VM and the two fixture consumers. Target deployment and consumer fork-safety qualification remain separate.

Reproduce using the [installed comparison command](../tests/performance/README.md#matched-warm-worker-comparison).
