# Installed Linux runner CPU profile

This profile measures how much process-tree CPU an execution spends before collecting a result. It uses the installed SDK and the normal worker subprocess, including signed snapshot reads, dependency inventory, the execution lock, watchdog and bounded result handling.

The trivial workload returns one OK result. The Kubernetes workload imports the official Python client, constructs a client, sends `GET /api/v1/namespaces/runner-cpu` to a local HTTP fixture and verifies the decoded namespace. Both workloads use the same installed environment. The container has loopback access and no external network. The Kubernetes measurement omits TLS, authentication, remote API latency and cluster work.

## Reproduce

From the repository root, build the packaged Linux consumer and add the Kubernetes client to a disposable profiling layer:

```sh
docker build -f examples/consumers/Dockerfile -t mondek-runner-cpu:base .
docker build -t mondek-runner-cpu:kubernetes - <<'DOCKERFILE'
FROM mondek-runner-cpu:base
USER 0:0
RUN uv pip install --python /app/.venv/bin/python --compile-bytecode kubernetes==34.1.0
USER 65532:65532
DOCKERFILE
docker run --rm --pull never --network none --workdir /profile \
  --mount "type=bind,source=$PWD/tests/performance,target=/profile,readonly" \
  mondek-runner-cpu:kubernetes python profile_runner_cpu.py
```

The default runs three bursts of 46 distinct assignments at each concurrency. Use `--checks 3 --repeats 1` for a smoke check. The JSON includes installed package versions and per-burst CPU. Keep raw timing output outside Git.

CPU is user plus system time from the driver and all reaped workers, divided by the number of validated executions. The local Kubernetes fixture remains live across the sampled interval, so its CPU is excluded. Queue delay starts at the shared burst due time and ends when a slot opens. Wall time starts at slot admission and ends when the complete worker reply has returned. The p95 values pool the three measured bursts. One small warm-up at each phase and concurrency precedes measurement.

The comparisons are cumulative. Interpreter starts Python with an empty command. Worker imports loads the SDK worker module. The verification path adds snapshot and dependency validation along with worker setup and IPC. Prepare adds consumer import, check registration and argument validation. Full execution adds collection, datasource setup as applicable, output validation and result IPC. Subtracting adjacent phases gives approximate costs, and small differences can reflect run-to-run variation. Discovery is measured separately from execution.

Queue figures describe the synchronized workload. Controller polling, report spooling, upload and production scheduling are outside the measured interval.

## Results

The baseline used Mondek 0.0.5 with the notification delivery off change, Python 3.13.15 and Kubernetes client 34.1.0. The Docker Desktop Linux ARM64 VM had 8 vCPUs and 7.65 GiB of memory on an Apple M2. The installed profiling image was `sha256:09ecce1f0bf06649084e3d32cfacddb72ad2a03ae4e928bebebf9b330eff05fc`.

| Workload | Concurrency | CPU per execution (ms) | p95 wall (ms) | p95 queue (ms) |
| --- | ---: | ---: | ---: | ---: |
| Trivial | 1 | 71.5 | 79.2 | 3,101 |
| Trivial | 3 | 80.6 | 87.4 | 1,138 |
| Kubernetes GET | 1 | 219.9 | 233.2 | 9,576 |
| Kubernetes GET | 3 | 265.1 | 289.1 | 3,765 |

Cumulative CPU per execution in milliseconds:

| Workload | Concurrency | Interpreter | Worker imports | Verify snapshot | Prepare | Execute |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Trivial | 1 | 8.9 | 60.0 | 68.0 | 69.5 | 71.5 |
| Trivial | 3 | 9.2 | 69.0 | 83.5 | 79.1 | 80.6 |
| Kubernetes GET | 1 | 8.7 | 59.6 | 68.1 | 218.5 | 219.9 |
| Kubernetes GET | 3 | 9.3 | 71.5 | 79.2 | 262.3 | 265.1 |

Starting Python and importing the SDK account for roughly 84–86% of the trivial baseline. Verification and worker setup add about 8–15 ms over imports. The Kubernetes client and consumer preparation add approximately 150–183 ms over verification. Full execution adds roughly 1–3 ms to preparation for these small results. That final difference is close to repeat variation, and trivial verification at concurrency 3 ran slower than preparation in these measurements. Snapshot discovery for all 46 assignments used 81 ms of CPU for the trivial workload and 248 ms for Kubernetes.

Concurrency 3 reduced the burst's p95 queue delay by 63% for the trivial workload and 61% for Kubernetes. CPU per execution increased by 13% and 21%, respectively.

**Proceed with a warm-worker prototype.** A threefold gain requires trivial execution to stay within 23.8 ms of CPU at concurrency 1 and 26.9 ms at concurrency 3. The observed gap between full execution and worker imports is about 12 ms in both cases. That leaves room for a prototype that keeps per-execution integrity checks. The prototype still needs to measure retained verification, process isolation, cleanup and steady-state CPU on the target deployment.
