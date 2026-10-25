# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Own a bounded group of real runner CLI processes and separate journals."""

import os
import signal
import subprocess
import sys
import threading
import time

count = int(os.environ.get("MONDEK_PROFILE_RUNNERS", "1"))
if not 0 <= count <= 12 or os.environ.get("MONDEK_PROFILE_MODE", "idle") not in {
    "idle",
    "active",
}:
    raise ValueError("profile needs 0..12 runners and idle/active mode")
stopped = threading.Event()
for sig in (signal.SIGINT, signal.SIGTERM):
    signal.signal(sig, lambda *_: stopped.set())
children: list[subprocess.Popen] = []
try:
    for index in range(1, count + 1):
        if stopped.is_set():
            break
        children.append(
            subprocess.Popen(
                [
                    sys.executable,
                    "-m",
                    "mondek_runner",
                    "--consumer",
                    "consumer:app",
                    "--state-dir",
                    f"/state/runner-{index}",
                ],
                env={**os.environ, "MONDEK_PROFILE_INDEX": str(index)},
            )
        )
        stopped.wait(0.3)
    while not stopped.wait(0.5):
        if any(child.poll() is not None for child in children):
            raise RuntimeError("a profiling runner exited unexpectedly")
finally:
    for child in children:
        if child.poll() is None:
            child.terminate()
    deadline = time.monotonic() + 12
    for child in children:
        try:
            child.wait(timeout=max(0.01, deadline - time.monotonic()))
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait()
