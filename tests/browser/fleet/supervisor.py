#!/usr/bin/env python3
# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Own bounded real runner processes and an HTTP datasource in one test container."""

from __future__ import annotations

import json
import os
import signal
import subprocess
import threading
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, BinaryIO

LOCK = threading.RLock()
PROCESSES: dict[int, subprocess.Popen[bytes]] = {}
LOGS: dict[int, BinaryIO] = {}
SAMPLES: dict[int, str] = {}
RUNS: dict[int, int] = {}
STOPPING = threading.Event()


def start(index: int) -> None:
    if STOPPING.is_set():
        return
    if index in PROCESSES and PROCESSES[index].poll() is None:
        return
    state = Path(f"/state/runner-{index:03d}")
    state.mkdir(parents=True, exist_ok=True)
    if index in LOGS:
        LOGS[index].close()
    LOGS[index] = (state / "process.log").open("ab")
    env = os.environ | {
        "MONDEK_FLEET_INDEX": str(index),
        "MONDEK_CONSUMER": "fleet_checks:app",
        "MONDEK_STATE_DIR": str(state),
        "MONDEK_CONTROLLER_URL": "http://target:8080",
        "MONDEK_MAX_CONCURRENCY": "1",
        "MONDEK_SPOOL_MAX_REPORTS": "64",
        "MONDEK_SPOOL_MAX_BYTES": "262144",
    }
    PROCESSES[index] = subprocess.Popen(
        ["python", "-m", "mondek_runner"],
        env=env,
        stdout=LOGS[index],
        stderr=subprocess.STDOUT,
    )


def stop(index: int) -> None:
    process = PROCESSES.get(index)
    if process and process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=8)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=3)


def state() -> dict[str, Any]:
    return {
        "processes": [
            {
                "index": index,
                "pid": process.pid,
                "state_directory": f"/state/runner-{index:03d}",
                "alive": process.poll() is None,
                "sample_requests": RUNS.get(index, 0),
                "mode": SAMPLES.get(index, "OK"),
            }
            for index, process in sorted(PROCESSES.items())
        ]
    }


def start_selected(indices: list[int]) -> None:
    # Each runner prepares and executes in child interpreters. Spread startup
    # over time on the shared Docker VM without blocking datasource requests.
    for index in indices:
        if STOPPING.is_set():
            break
        with LOCK:
            existing = PROCESSES.get(index)
            starting = existing is None or existing.poll() is not None
            start(index)
        if starting:
            time.sleep(0.7)


def resize(count: int) -> None:
    start_selected(list(range(1, count + 1)))
    with LOCK:
        for index in list(PROCESSES):
            if index > count:
                stop(index)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args: object) -> None:
        pass

    def respond(self, status: int, body: Any) -> None:
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self) -> None:
        if self.path == "/health":
            self.respond(200, {"ready": True})
        elif self.path == "/fleet":
            with LOCK:
                self.respond(200, state())
        elif self.path.startswith("/samples/"):
            try:
                index = int(self.path.removeprefix("/samples/"))
                if not 1 <= index <= 50:
                    raise ValueError
            except ValueError:
                self.respond(404, {"error": "unknown node"})
                return
            with LOCK:
                RUNS[index] = RUNS.get(index, 0) + 1
                sample = SAMPLES.get(index, "OK")
            self.respond(
                503 if sample == "unavailable" else 200,
                {
                    "health": sample,
                    "source_at": datetime.now(timezone.utc)
                    .isoformat(timespec="microseconds")
                    .replace("+00:00", "Z"),
                    "error": "Owned datasource unavailable"
                    if sample == "unavailable"
                    else None,
                },
            )
        else:
            self.respond(404, {"error": "unknown path"})

    def do_POST(self) -> None:
        try:
            size = int(self.headers.get("Content-Length", "0"))
            if self.path != "/fleet" or not 0 < size <= 8192:
                raise ValueError("bounded fleet control required")
            changes = json.loads(self.rfile.read(size))
            if not isinstance(changes, dict) or set(changes) - {
                "count",
                "samples",
                "start",
                "restart",
                "stop",
            }:
                raise ValueError("invalid fleet controls")
            count = changes.get("count")
            if count is not None and (type(count) is not int or not 0 <= count <= 50):
                raise ValueError("count must be in 0–50")
            samples = changes.get("samples", {})
            if not isinstance(samples, dict) or len(samples) > 50:
                raise ValueError("invalid samples")
            for key, value in samples.items():
                if not 1 <= int(key) <= 50 or value not in {
                    "OK",
                    "WARN",
                    "CRIT",
                    "unavailable",
                }:
                    raise ValueError("invalid sample mode")
            for action in ("start", "restart", "stop"):
                if (
                    not isinstance(changes.get(action, []), list)
                    or len(changes.get(action, [])) > 50
                    or any(
                        type(index) is not int or not 1 <= index <= 50
                        for index in changes.get(action, [])
                    )
                ):
                    raise ValueError("invalid process selection")
            with LOCK:
                SAMPLES.update({int(key): value for key, value in samples.items()})
            if count is not None:
                resize(count)
            start_selected(changes.get("start", []))
            with LOCK:
                for index in changes.get("stop", []):
                    stop(index)
                for index in changes.get("restart", []):
                    stop(index)
                    start(index)
                result = state()
            self.respond(200, result)
        except (ValueError, TypeError, json.JSONDecodeError) as error:
            self.respond(400, {"error": str(error)})


def main() -> None:
    server = ThreadingHTTPServer(("0.0.0.0", 8082), Handler)
    server.daemon_threads = True
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    for signum in (signal.SIGTERM, signal.SIGINT):
        signal.signal(signum, lambda *_: STOPPING.set())
    resize(12)
    STOPPING.wait()
    server.shutdown()
    with LOCK:
        # Terminate the fleet together, so a slow child cannot consume the
        # Compose stop timeout once per runner during otherwise normal cleanup.
        for process in PROCESSES.values():
            if process.poll() is None:
                process.terminate()
        deadline = time.monotonic() + 8
        for process in PROCESSES.values():
            if process.poll() is None:
                try:
                    process.wait(timeout=max(0, deadline - time.monotonic()))
                except subprocess.TimeoutExpired:
                    process.kill()
        for process in PROCESSES.values():
            process.wait(timeout=3)
        for log in LOGS.values():
            log.close()


if __name__ == "__main__":
    main()
