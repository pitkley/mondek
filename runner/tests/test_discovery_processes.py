# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Real discovery process groups remain bounded after abrupt supervisor loss."""

from __future__ import annotations

import asyncio
import contextlib
import json
import os
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

from mondek_runner.bundle import snapshot


class DiscoveryProcessTests(unittest.TestCase):
    def test_abrupt_supervisor_loss_kills_discovery_descendants_and_allows_reuse(self):
        for frozen in (False, True):
            with self.subTest(helper_stopped=frozen):
                self._exercise_loss(frozen)

    def _exercise_loss(self, freeze_helper: bool):
        with tempfile.TemporaryDirectory(prefix="mondek-discovery-process-") as temp:
            directory = Path(temp)
            bundles = directory / "bundles"
            bundles.mkdir()
            marker = directory / "retained-state"
            marker.write_text("preserved")
            pidfile = directory / "pids.json"
            (directory / "hung_discovery.py").write_text(
                "import json, os, subprocess, sys, time\n"
                "from pathlib import Path\n"
                "child = subprocess.Popen([sys.executable, '-c', "
                "'import time; time.sleep(90)'], "
                "stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)\n"
                f"Path({str(pidfile)!r}).write_text(json.dumps("
                "{'helper': os.getpid(), 'child': child.pid}))\n"
                "time.sleep(90)\n"
            )
            env = dict(os.environ)
            env["PYTHONPATH"] = str(directory) + os.pathsep + env.get("PYTHONPATH", "")
            supervisor = subprocess.Popen(
                [
                    sys.executable,
                    "-B",
                    "-c",
                    "import asyncio, sys; from pathlib import Path; "
                    "from mondek_runner.bundle import snapshot; "
                    "asyncio.run(snapshot('hung_discovery:app', Path(sys.argv[1])))",
                    str(bundles),
                ],
                env=env,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            pids = None
            try:
                deadline = time.monotonic() + 5
                while pids is None and time.monotonic() < deadline:
                    try:
                        pids = json.loads(pidfile.read_text())
                    except (FileNotFoundError, json.JSONDecodeError):
                        time.sleep(0.02)
                self.assertIsNotNone(pids, "consumer did not enter discovery")
                self.assertEqual(os.getpgid(pids["helper"]), pids["helper"])
                if freeze_helper:
                    # Even a completely unresponsive helper cannot prevent its
                    # independent guardian from bounding the group lifetime.
                    os.kill(pids["helper"], signal.SIGSTOP)
                supervisor.kill()
                supervisor.wait(timeout=5)
                for name in ("helper", "child"):
                    deadline = time.monotonic() + 5
                    while time.monotonic() < deadline:
                        try:
                            os.kill(pids[name], 0)
                        except ProcessLookupError:
                            break
                        time.sleep(0.02)
                    else:
                        self.fail(f"orphaned discovery {name} outlived its supervisor")
                recovered = asyncio.run(snapshot("demo_checks.app:app", bundles))
                self.assertTrue(recovered["checks"])
                self.assertEqual(marker.read_text(), "preserved")
            finally:
                if supervisor.poll() is None:
                    supervisor.kill()
                supervisor.wait()
                if pids:
                    with contextlib.suppress(ProcessLookupError):
                        os.killpg(pids["helper"], signal.SIGKILL)
