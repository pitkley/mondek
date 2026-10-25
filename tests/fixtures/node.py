#!/usr/bin/env python3
# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Owned local process and export files for real node monitoring acceptance."""

from __future__ import annotations

import json
import os
import signal
import subprocess
import sys
import threading
import time
from datetime import UTC, datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

DIRECTORY = Path(os.environ.get("MONDEK_NODE_DIRECTORY", "/node"))
LOCK = threading.RLock()
STOPPED = threading.Event()
CHILD: subprocess.Popen | None = None
MODES = {"export": "healthy", "process": "running"}


def atomic_json(path: Path, value: Any) -> None:
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(value))
    temporary.chmod(0o644)
    temporary.replace(path)


def process_start(pid: int) -> str:
    # Linux field 22; the executable's parenthesized name may contain spaces.
    return Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()[19]


def reconcile() -> None:
    global CHILD
    with LOCK:
        if MODES["process"] == "running" and (
            CHILD is None or CHILD.poll() is not None
        ):
            CHILD = subprocess.Popen([sys.executable, __file__, "--child"])
            atomic_json(
                DIRECTORY / "process.json",
                {"pid": CHILD.pid, "start": process_start(CHILD.pid)},
            )
            atomic_json(DIRECTORY / "application.pid", CHILD.pid)
        elif MODES["process"] == "stopped" and CHILD is not None:
            CHILD.terminate()
            try:
                CHILD.wait(timeout=3)
            except subprocess.TimeoutExpired:
                CHILD.kill()
                CHILD.wait(timeout=3)
            CHILD = None

        path = DIRECTORY / "export.json"
        if MODES["export"] == "missing":
            path.unlink(missing_ok=True)
        else:
            generated = datetime.fromtimestamp(
                time.time() - (3600 if MODES["export"] == "stale" else 0), UTC
            ).isoformat()
            atomic_json(
                path,
                {
                    "generated_at": generated,
                    "records": "invalid"
                    if MODES["export"] == "invalid"
                    else [{"id": 1}],
                },
            )
            if MODES["export"] == "unreadable":
                path.chmod(0)


def update(changes: dict[str, Any]) -> dict[str, str]:
    with LOCK:
        if set(changes) - set(MODES):
            raise ValueError("unknown node fixture field")
        proposed = MODES | changes
        if proposed["export"] not in {
            "healthy",
            "missing",
            "stale",
            "invalid",
            "unreadable",
        }:
            raise ValueError("invalid export mode")
        if proposed["process"] not in {"running", "stopped"}:
            raise ValueError("invalid process mode")
        MODES.update(proposed)
        atomic_json(DIRECTORY / "fixture-mode.json", MODES)
        reconcile()
        return dict(MODES)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, format: str, *args: object) -> None:
        pass

    def respond(self, status: int, value: Any) -> None:
        raw = json.dumps(value).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        try:
            self.wfile.write(raw)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_GET(self) -> None:
        if self.path == "/health":
            self.respond(200, {"status": "ok"})
        elif self.path == "/mode":
            with LOCK:
                self.respond(200, dict(MODES))
        else:
            self.respond(404, {"error": "unknown path"})

    def do_POST(self) -> None:
        if self.path != "/mode":
            self.respond(404, {"error": "unknown path"})
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if not 0 < length <= 2048:
                raise ValueError("body must fit within 2048 bytes")
            changes = json.loads(self.rfile.read(length))
            if not isinstance(changes, dict):
                raise ValueError("body must be an object")
            self.respond(200, update(changes))
        except (ValueError, TypeError) as error:
            self.respond(400, {"error": str(error)})


def main() -> None:
    if "--child" in sys.argv:
        while True:
            time.sleep(60)

    DIRECTORY.mkdir(parents=True, exist_ok=True)
    # The generic starter reads this ordinary file and decimal PID file; it has
    # no dependency on the demo's structured export or process identity format.
    (DIRECTORY / "ordinary-export.csv").write_text("id,value\n1,42\n")
    (DIRECTORY / "secondary-export.csv").write_text("id,value\n2,84\n")
    stored = DIRECTORY / "fixture-mode.json"
    if stored.exists():
        update(json.loads(stored.read_text()))
    else:
        reconcile()

    def refresh() -> None:
        while not STOPPED.wait(2):
            reconcile()

    thread = threading.Thread(target=refresh, daemon=True)
    thread.start()
    server = ThreadingHTTPServer(("0.0.0.0", 8081), Handler)
    server.daemon_threads = True

    def shutdown(signum: int, frame: object) -> None:
        STOPPED.set()
        threading.Thread(target=server.shutdown, daemon=True).start()

    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, shutdown)
    try:
        server.serve_forever()
    finally:
        STOPPED.set()
        server.server_close()
        with LOCK:
            if CHILD is not None:
                CHILD.terminate()
                CHILD.wait(timeout=3)


if __name__ == "__main__":
    main()
