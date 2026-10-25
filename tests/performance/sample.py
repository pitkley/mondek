# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Cumulative Linux container/process counters; diff snapshots, not CPU percentages.

Parent cutime/cstime includes reaped children only, not currently running helpers.
Cgroup CPU covers all processes, including this sampler. Process counts are live
snapshots, never lifetime spawn counts. Start ticks distinguish reused PIDs.
"""

import json
import os
import platform
import resource
import sys
import threading
import time
from collections import Counter
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


def snapshot() -> dict:
    from mondek_runner.state import inspect

    cgroup = Path("/sys/fs/cgroup")
    cpu = {
        key: int(value)
        for key, value in (
            line.split() for line in (cgroup / "cpu.stat").read_text().splitlines()
        )
    }
    ticks = os.sysconf("SC_CLK_TCK")
    processes, runners, kinds = 0, [], Counter()
    for entry in Path("/proc").iterdir():
        if not entry.name.isdigit():
            continue
        processes += 1
        if processes > 4096:
            raise RuntimeError("profiling process bound exceeded")
        try:
            args = (entry / "cmdline").read_bytes().split(b"\0")
            module = args[args.index(b"-m") + 1] if b"-m" in args else b""
            if module.startswith(b"mondek_runner"):
                kinds[module.decode()] += 1
            if module != b"mondek_runner" or b"--consumer" not in args:
                continue
            fields = (entry / "stat").read_text().rsplit(")", 1)[1].split()
            runners.append(
                {
                    "pid": int(entry.name),
                    "start_ticks": int(fields[19]),
                    "user_seconds": int(fields[11]) / ticks,
                    "system_seconds": int(fields[12]) / ticks,
                    "reaped_child_user_seconds": int(fields[13]) / ticks,
                    "reaped_child_system_seconds": int(fields[14]) / ticks,
                }
            )
        except (FileNotFoundError, ProcessLookupError):
            continue
    journals = []
    for directory in sorted(Path("/state").glob("runner-*")):
        if not (directory / "runner.sqlite3").exists():
            continue
        if len(journals) >= 12:
            raise RuntimeError("profiling journal bound exceeded")
        status = inspect(directory)
        journals.append(
            {
                "directory": directory.name,
                **{
                    key: status.get(key)
                    for key in (
                        "installation_id",
                        "session_id",
                        "boot",
                        "sequence",
                        "queue_count",
                        "dropped",
                        "loss_at",
                        "diagnostic",
                    )
                },
                "inflight_count": len(status["inflight"]),
            }
        )
    return {
        "monotonic": time.monotonic(),
        "unix_time": time.time(),
        "cpu": cpu,
        "memory_current": int((cgroup / "memory.current").read_text()),
        "memory_peak": int((cgroup / "memory.peak").read_text())
        if (cgroup / "memory.peak").exists()
        else None,
        "process_count": processes,
        "process_kinds": dict(kinds),
        "runners": runners,
        "journals": journals,
        "platform": platform.platform(),
        "python": platform.python_version(),
        "clock_ticks_per_second": ticks,
    }


def microbench() -> dict:
    from mondek_runner.transport import post_json

    class Handler(BaseHTTPRequestHandler):
        def do_POST(self) -> None:
            self.rfile.read(int(self.headers["Content-Length"]))
            self.send_response(200)
            self.send_header("Content-Length", "13")
            self.end_headers()
            self.wfile.write(b'{"version":1}')

        def log_message(self, *_: object) -> None:
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    samples = []
    try:
        for _ in range(15):
            before = resource.getrusage(resource.RUSAGE_CHILDREN)
            start = time.monotonic()
            response = post_json(
                f"http://127.0.0.1:{server.server_port}/api/v1/control",
                {"version": 1},
                8,
            )
            after = resource.getrusage(resource.RUSAGE_CHILDREN)
            if response != {"version": 1}:
                raise RuntimeError("unexpected local transport response")
            samples.append(
                {
                    "wall_seconds": time.monotonic() - start,
                    "child_user_seconds": after.ru_utime - before.ru_utime,
                    "child_system_seconds": after.ru_stime - before.ru_stime,
                }
            )
    finally:
        server.shutdown()
        server.server_close()
        thread.join()
    return {
        "mode": "microbench",
        "helpers": 15,
        "samples": samples,
        "platform": platform.platform(),
        "python": platform.python_version(),
    }


if __name__ == "__main__":
    if sys.argv[1:] not in ([], ["--microbench"]):
        raise SystemExit("usage: sample.py [--microbench]")
    print(json.dumps(microbench() if sys.argv[1:] else snapshot(), allow_nan=False))
