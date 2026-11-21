# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Measure the installed Linux runner's process tree on a bounded burst of checks."""

import argparse
import asyncio
import importlib.metadata
import json
import math
import os
import platform
import resource
import statistics
import sys
import sysconfig
import tempfile
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import mondek_runner
from mondek_runner.bundle import snapshot
from mondek_runner.runtime import execute

PHASES = ("interpreter", "worker_imports", "verify_snapshot", "prepare", "execute")


class KubernetesFixture(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/api/v1/namespaces/runner-cpu":
            self.send_error(404)
            return

        body = (
            b'{"apiVersion":"v1","kind":"Namespace","metadata":{"name":"runner-cpu"}}'
        )
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


def serve_api():
    with ThreadingHTTPServer(("127.0.0.1", 0), KubernetesFixture) as server:
        print(f"http://127.0.0.1:{server.server_port}", flush=True)
        server.serve_forever()


def tree_cpu():
    # The fixture server remains live for every sample, so its CPU is excluded.
    own = resource.getrusage(resource.RUSAGE_SELF)
    children = resource.getrusage(resource.RUSAGE_CHILDREN)
    return own.ru_utime + own.ru_stime + children.ru_utime + children.ru_stime


def p95(samples):
    return sorted(samples)[math.ceil(0.95 * len(samples)) - 1]


async def run_phase(phase, assignment, directory, workload):
    if phase in ("interpreter", "worker_imports"):
        source = "pass" if phase == "interpreter" else "import mondek_runner.worker"
        process = await asyncio.create_subprocess_exec(
            sys.executable, "-c", source, start_new_session=True
        )
        if await process.wait():
            raise RuntimeError(f"{phase} subprocess failed")
        return

    report = await execute(
        assignment,
        bundle_dir=directory,
        lock_path=directory / assignment["id"],
        verify_snapshot=phase == "verify_snapshot",
        prepare=phase == "prepare",
    )

    if phase == "execute":
        validate_execution(report, workload)
        return
    elif report.get("prepared"):
        return
    raise RuntimeError(f"{workload} {phase} failed: {report}")


def validate_execution(report, workload):
    summary = "Read namespace" if workload == "kubernetes_get" else "Trivial result"
    results = report.get("results", [])
    if (
        report.get("complete")
        and len(results) == 1
        and results[0]["health"] == "OK"
        and results[0]["summary"] == summary
    ):
        return
    raise RuntimeError(f"{workload} execution failed: {report}")


async def measure(phase, assignments, directory, workload, concurrency, repeats):
    async def burst(configs):
        return await timed_burst(
            configs,
            concurrency,
            lambda config: run_phase(phase, config, directory, workload),
        )

    await burst(assignments[:concurrency])
    cpu_per_run = []
    queue = []
    wall = []
    for _ in range(repeats):
        before = tree_cpu()
        samples = await burst(assignments)
        cpu_per_run.append(1000 * (tree_cpu() - before) / len(assignments))
        for queue_ms, wall_ms in samples:
            queue.append(queue_ms)
            wall.append(wall_ms)

    return {
        "workload": workload,
        "phase": phase,
        "concurrency": concurrency,
        "cpu_ms_per_execution": round(statistics.mean(cpu_per_run), 3),
        "run_cpu_ms_per_execution": [round(cpu, 3) for cpu in cpu_per_run],
        "wall_p95_ms": round(p95(wall), 3),
        "queue_p95_ms": round(p95(queue), 3),
    }


async def timed_burst(configs, concurrency, run):
    slots = asyncio.Semaphore(concurrency)
    due = time.monotonic()

    async def one(config):
        async with slots:
            started = time.monotonic()
            await run(config)
            return (started - due) * 1000, (time.monotonic() - started) * 1000

    return await asyncio.gather(*(one(config) for config in configs))


def proc_sample(pid):
    # Linux stat starts with (pid, parenthesized comm, state); comm may contain spaces.
    fields = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()
    return {
        "start_ticks": int(fields[19]),
        "cpu_seconds": sum(int(ticks) for ticks in fields[11:15])
        / os.sysconf("SC_CLK_TCK"),
        "rss_kib": int(fields[21]) * os.sysconf("SC_PAGE_SIZE") // 1024,
    }


async def compare_backends(assignments, directory, workload, concurrency, repeats):
    from mondek_runner.warm_pool import WarmPool

    pool = WarmPool()
    revision = assignments[0]["source_revision"]
    try:
        before = tree_cpu()
        started = time.monotonic()
        if not await pool.prepare(assignments[0], bundle_dir=directory):
            raise RuntimeError("warm broker declined startup")
        pid = pool.pid_for(revision)
        if not pid:
            raise RuntimeError("warm broker disappeared during startup")
        initial = proc_sample(pid)
        cold = {
            "wall_ms": 1000 * (time.monotonic() - started),
            "cpu_ms": 1000 * (tree_cpu() - before + initial["cpu_seconds"]),
            "broker_rss_kib": initial["rss_kib"],
        }

        def sample():
            status = pool.status()
            if (
                not status["supported"]
                or status["ready_revisions"] != 1
                or status["in_flight"] != 0
                or status["diagnostic"]
            ):
                raise RuntimeError(f"unexpected warm pool status: {status}")
            if pool.pid_for(revision) != pid:
                raise RuntimeError(
                    "warm broker restarted or disappeared during benchmark"
                )
            broker = proc_sample(pid)
            if broker["start_ticks"] != initial["start_ticks"]:
                raise RuntimeError("warm broker process identity changed")
            return tree_cpu() + broker["cpu_seconds"], broker["rss_kib"]

        async def prepare(config):
            if not await pool.prepare(config, bundle_dir=directory):
                raise RuntimeError("warm broker declined assignment preparation")

        async def warm(config):
            result = await pool.execute(
                config, bundle_dir=directory, lock_path=directory / config["id"]
            )
            if result is None:
                raise RuntimeError("warm broker declined execution")
            validate_execution(result, workload)

        preparations = {}
        for backend, run in (
            ("exec", lambda config: run_phase("prepare", config, directory, workload)),
            ("warm", prepare),
        ):
            before, _ = sample()
            started = time.monotonic()
            for config in assignments:
                await run(config)
            preparations[backend] = {
                "wall_ms": 1000 * (time.monotonic() - started),
                "cpu_ms": 1000 * (sample()[0] - before),
                "assignments": len(assignments),
            }

        backends = {
            "exec": lambda config: run_phase("execute", config, directory, workload),
            "warm": warm,
        }
        for run in backends.values():
            await timed_burst(assignments[:concurrency], concurrency, run)
        bursts = []
        samples = {backend: [] for backend in backends}
        for i in range(repeats):
            order = tuple(backends) if i % 2 == 0 else tuple(reversed(backends))
            for backend in order:
                prior_requests = pool.status()["warm_requests"]
                before, _ = sample()
                timings = await timed_burst(assignments, concurrency, backends[backend])
                after, rss = sample()
                warm_requests = pool.status()["warm_requests"] - prior_requests
                if warm_requests != (len(assignments) if backend == "warm" else 0):
                    raise RuntimeError(
                        "broker dispatch count differs from measured executions"
                    )
                samples[backend].extend(timings)
                bursts.append(
                    {
                        "pair": i + 1,
                        "backend": backend,
                        "cpu_ms_per_execution": 1000
                        * (after - before)
                        / len(assignments),
                        "driver_rss_kib_after": proc_sample(os.getpid())["rss_kib"],
                        "warm_requests": warm_requests,
                        "broker_rss_kib_after": rss,
                        "wall_p95_ms": p95([wall for _, wall in timings]),
                        "queue_p95_ms": p95([queue for queue, _ in timings]),
                    }
                )
        summary = {
            backend: {
                "cpu_ms_per_execution": statistics.mean(
                    b["cpu_ms_per_execution"] for b in bursts if b["backend"] == backend
                ),
                "wall_p95_ms": p95([wall for _, wall in timings]),
                "queue_p95_ms": p95([queue for queue, _ in timings]),
                "validated_executions": len(timings),
            }
            for backend, timings in samples.items()
        }
        ratio = (
            summary["warm"]["cpu_ms_per_execution"]
            / summary["exec"]["cpu_ms_per_execution"]
        )
        result = {
            "concurrency": concurrency,
            "broker_start_and_first_prepare": cold,
            "prepare_all": preparations,
            "bursts": bursts,
            "steady_state": summary,
            "warm_to_exec_cpu_ratio": ratio,
        }
        if workload == "trivial":
            limit = {1: 23.8, 3: 26.9}[concurrency]
            result["cpu_gate"] = {
                "absolute_limit_ms": limit,
                "meets_absolute_limit": summary["warm"]["cpu_ms_per_execution"]
                <= limit,
                "meets_matched_one_third": ratio <= 1 / 3,
            }
        return result
    finally:
        await pool.close()


async def profile_workload(workload, endpoint, count, repeats, compare_warm):
    os.environ["MONDEK_CPU_PROFILE_WARM"] = "1" if compare_warm else "0"
    os.environ["MONDEK_CPU_PROFILE_API"] = endpoint
    os.environ["MONDEK_CPU_PROFILE_CHECKS"] = str(count)
    with tempfile.TemporaryDirectory(prefix="mondek-cpu-profile-") as tmp:
        directory = Path(tmp)
        before = tree_cpu()
        started = time.monotonic()
        inventory = await snapshot("runner_cpu_workload:app", directory)
        discovery = {
            "cpu_ms": round(1000 * (tree_cpu() - before), 3),
            "wall_ms": round(1000 * (time.monotonic() - started), 3),
        }
        assignments = [
            {
                **check,
                "id": str(uuid.UUID(int=index)),
                "kind": "python",
                "generation": 1,
                "source_id": inventory["source_id"],
                "source_key": check["key"],
                "source_revision": inventory["source_revision"],
                "expected_keys": [output["key"] for output in check["outputs"]],
            }
            for index, check in enumerate(inventory["checks"], 1)
        ]
        if len(assignments) != count:
            raise RuntimeError("profiling inventory does not match requested size")
        if compare_warm:
            comparisons = [
                await compare_backends(
                    assignments, directory, workload, concurrency, repeats
                )
                for concurrency in (1, 3)
            ]
            return {
                "workload": workload,
                "discovery": discovery,
                "comparison": comparisons,
            }
        phases = [
            await measure(phase, assignments, directory, workload, concurrency, repeats)
            for concurrency in (1, 3)
            for phase in PHASES
        ]
    return {"workload": workload, "discovery": discovery, "phases": phases}


async def profile(count, repeats, compare_warm=False):
    packages = {
        item.metadata["Name"]: item.version
        for item in importlib.metadata.distributions()
    }
    installed = Path(sysconfig.get_path("purelib"))
    if not Path(mondek_runner.__file__).resolve().is_relative_to(installed.resolve()):
        raise RuntimeError(
            "profile requires the installed SDK, outside the source checkout"
        )

    server = await asyncio.create_subprocess_exec(
        sys.executable, __file__, "--serve", stdout=asyncio.subprocess.PIPE
    )
    try:
        endpoint = (
            (await asyncio.wait_for(server.stdout.readline(), 5)).decode().strip()
        )
        if not endpoint.startswith("http://127.0.0.1:"):
            raise RuntimeError("local profiling server did not start")
        results = [
            await profile_workload("trivial", "", count, repeats, compare_warm),
            await profile_workload(
                "kubernetes_get", endpoint, count, repeats, compare_warm
            ),
        ]
        if server.returncode is not None:
            raise RuntimeError("profiling server stopped during collection")
    finally:
        if server.returncode is None:
            server.terminate()
            await server.wait()
    return {
        "platform": platform.platform(),
        "python": platform.python_version(),
        "installed_packages": packages,
        "checks_per_burst": count,
        "bursts_per_phase": repeats,
        "workloads": results,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--checks", type=int, default=46)
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument(
        "--compare-warm", action="store_true", help="run paired warm and exec bursts"
    )
    parser.add_argument("--serve", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.serve:
        serve_api()
        return
    if not 3 <= args.checks <= 512 or not 1 <= args.repeats <= 5:
        parser.error("use 3–512 checks and 1–5 repeats")
    if sys.platform != "linux":
        parser.error("run the profile inside the installed Linux consumer image")
    print(
        json.dumps(
            asyncio.run(profile(args.checks, args.repeats, args.compare_warm)), indent=2
        )
    )


if __name__ == "__main__":
    main()
