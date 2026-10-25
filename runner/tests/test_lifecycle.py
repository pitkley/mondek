# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0

from __future__ import annotations

import asyncio
import copy
import json
import os
import tempfile
import threading
import unittest
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from itertools import pairwise
from pathlib import Path
from unittest.mock import patch

from test_runner import assignment

from mondek_runner.bundle import snapshot
from mondek_runner.config import validate
from mondek_runner.runtime import Runner
from mondek_runner.state import State, inspect


def baseline(assignments, authorized=None, **overrides):
    return {
        "version": 1,
        "assignments_authoritative": True,
        "assignments": assignments,
        "authorized": authorized or {},
        **overrides,
    }


class MembershipTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.state = State(self.temp.name)
        self.first = assignment("http", id=str(uuid.uuid4()))
        self.second = assignment("http", id=str(uuid.uuid4()))
        self.state.adopt(self.first, 0)
        self.state.adopt(self.second, 0)

    async def asyncTearDown(self):
        self.state.close()
        self.temp.cleanup()

    async def test_invalid_or_partial_baselines_cannot_remove_accepted_checks(self):
        runner = Runner(self.state, "http://unused", consumer="demo_checks.app:app")
        original = copy.deepcopy(runner.active)
        bad_params = copy.deepcopy(self.first)
        bad_params["params"] = []
        malformed = (
            baseline(None),
            baseline([self.first], assignments_authoritative="true"),
            baseline([self.first, self.first]),
            baseline([bad_params]),
            baseline([self.first, None]),
            baseline([self.first], {"unknown": 1}),
            baseline([self.first], {self.first["id"]: True}),
            baseline([assignment("http", id=str(uuid.uuid4())) for _ in range(513)]),
        )
        for response in malformed:
            with self.subTest(response=response), self.assertRaises(ValueError):
                runner.reconcile(response)
            self.assertEqual(runner.active, original)
            self.assertEqual(self.state.assignments(), original)
            self.assertEqual(runner.desired, {})

        # Old/partial v1 responses may update listed checks, but omission has no
        # removal authority without the explicit complete-baseline marker.
        runner.reconcile({"assignments": [self.first], "authorized": {}})
        self.assertEqual(runner.active, original)
        runner.reconcile(baseline([self.first]))
        self.assertEqual(set(runner.active), {self.first["id"]})

    async def test_removal_survives_restart_without_erasing_allocated_evidence(self):
        started, release = asyncio.Event(), asyncio.Event()

        async def worker(config, **kwargs):
            started.set()
            await release.wait()
            return {"results": [], "complete": False, "diagnostic": "controlled"}

        runner = Runner(
            self.state, "http://unused", worker=worker, consumer="demo_checks.app:app"
        )
        await runner.step()
        await started.wait()
        allocations = {
            row["assignment_id"]: json.loads(row["payload"])
            for row in self.state.db.execute("SELECT * FROM inflight")
        }
        runner.reconcile(baseline([]))
        self.assertEqual(runner.active, {})
        self.assertEqual(self.state.assignments(), {})
        self.assertEqual(set(inspect(self.temp.name)["inflight"]), set(allocations))

        tasks = list(runner.running.values())
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
        self.state.close()
        self.state = State(self.temp.name)
        restarted = Runner(self.state, "http://unused", consumer="demo_checks.app:app")
        await restarted.step()
        self.assertEqual(restarted.running, {})
        reports = self.state.batch()
        self.assertEqual(len(reports), 2)
        for report in reports:
            allocated = allocations[report["assignment_id"]]
            for key, value in allocated.items():
                self.assertEqual(report[key], value)
            self.assertFalse(report["complete"])
            self.assertIn("restart interrupted", report["diagnostic"])

    async def test_removed_inflight_run_finishes_without_blocking_new_identity(self):
        started, release = asyncio.Event(), asyncio.Event()
        executed = []

        async def worker(config, **kwargs):
            executed.append(config["id"])
            if config["id"] == self.first["id"]:
                started.set()
                await release.wait()
            return {"results": [], "complete": False, "diagnostic": "controlled"}

        runner = Runner(
            self.state, "http://unused", worker=worker, consumer="demo_checks.app:app"
        )
        runner.reconcile(baseline([self.first]))
        await runner.step()
        await started.wait()
        replacement = assignment("http", id=str(uuid.uuid4()))
        runner.prepared[replacement["id"]] = replacement
        runner.reconcile(baseline([replacement], {replacement["id"]: 1}))
        await runner.step()
        await runner.running[replacement["id"]]
        self.assertIn(self.first["id"], runner.running)
        release.set()
        await asyncio.gather(*runner.running.values())
        runner.due[replacement["id"]] = float("inf")
        await runner.step()
        self.assertEqual(executed, [self.first["id"], replacement["id"]])
        reports = self.state.batch()
        self.assertEqual({r["assignment_id"] for r in reports}, set(executed))
        self.assertEqual(len({r["id"] for r in reports}), 2)
        self.assertEqual(len({r["sequence"] for r in reports}), 2)

    async def test_superseded_preparation_cannot_readd_removed_checks_or_errors(self):
        for outcome in ({"prepared": True}, {"prepared": False, "diagnostic": "old"}):
            with self.subTest(outcome=outcome):
                started, release = asyncio.Event(), asyncio.Event()
                prepared_ids = []

                async def worker(
                    config,
                    prepared_ids=prepared_ids,
                    started=started,
                    release=release,
                    outcome=outcome,
                    **kwargs,
                ):
                    prepared_ids.append(config["id"])
                    started.set()
                    await release.wait()
                    return outcome

                runner = Runner(
                    self.state,
                    "http://unused",
                    worker=worker,
                    consumer="demo_checks.app:app",
                )
                runner.reconcile(baseline([self.first, self.second]))
                task = asyncio.create_task(runner.prepare())
                await asyncio.wait_for(started.wait(), 1)
                runner.reconcile(baseline([]))
                release.set()
                await asyncio.sleep(0)
                await asyncio.sleep(0)
                self.assertEqual(prepared_ids, [self.first["id"]])
                self.assertEqual(runner.prepared, {})
                self.assertEqual(runner.preparation_errors, {})
                self.assertEqual(runner.active, {})
                task.cancel()
                await asyncio.gather(task, return_exceptions=True)

    async def test_code_preparation_failure_keeps_prior_authority(self):
        failed = asyncio.Event()

        async def worker(config, **kwargs):
            failed.set()
            return {"prepared": False, "diagnostic": "import unavailable"}

        runner = Runner(
            self.state, "http://unused", worker=worker, consumer="demo_checks.app:app"
        )
        changed = {**self.first, "generation": 2}
        runner.reconcile(baseline([changed, self.second]))
        task = asyncio.create_task(runner.prepare())
        await asyncio.wait_for(failed.wait(), 1)
        self.assertEqual(runner.active[self.first["id"]]["generation"], 1)
        self.assertIn("import unavailable", runner.status()["diagnostic"])
        task.cancel()
        await asyncio.gather(task, return_exceptions=True)

    async def test_sixteen_instances_share_bounded_slots_without_starvation(self):
        configs = [assignment("http", id=str(uuid.uuid4())) for _ in range(16)]
        executed = []
        clock = 0.0

        async def worker(config, **kwargs):
            nonlocal clock
            self.assertLessEqual(len(inspect(self.temp.name)["inflight"]), 3)
            executed.append(config["id"])
            clock += 2
            return {"results": [], "complete": False, "diagnostic": "controlled"}

        runner = Runner(
            self.state,
            "http://unused",
            worker=worker,
            monotonic=lambda: clock,
            consumer="demo_checks.app:app",
        )
        runner.prepared = {c["id"]: c for c in configs}
        runner.reconcile(baseline(configs, {c["id"]: 1 for c in configs}))
        self.assertEqual(len(self.state.assignments()), 16)
        for _ in range(16):
            await runner.step()
            await asyncio.gather(*runner.running.values())
        self.assertEqual(set(executed), {c["id"] for c in configs})
        self.assertEqual(len(executed), 48)
        for config in configs:
            positions = [i for i, id_ in enumerate(executed) if id_ == config["id"]]
            self.assertGreaterEqual(len(positions), 2)
            self.assertLess(positions[0], 18)
            self.assertLess(len(executed) - positions[-1] - 1, 18)
            self.assertTrue(all(b - a <= 18 for a, b in pairwise(positions)))


class IdentityTests(unittest.TestCase):
    def test_identity_is_independent_of_kind_and_cannot_escape_execution_lock_path(
        self,
    ):
        for kind in ("filesystem", "http", "consumer"):
            config = assignment(kind, id=str(uuid.uuid4()))
            self.assertEqual(validate(config), config)
        for identity in ("../http", "/http", "", "x" * 5000, None, [], "http/other"):
            with self.subTest(identity=identity), self.assertRaises(ValueError):
                validate(assignment("http", id=identity))
        with self.assertRaises(ValueError):
            validate(assignment("filesystem", id="http"))
        for field in (
            "source_id",
            "source_key",
            "source_revision",
            "definition_revision",
        ):
            config = assignment()
            config[field] = ""
            with self.subTest(field=field), self.assertRaises(ValueError):
                validate(config)


class IndependentHttpTests(unittest.IsolatedAsyncioTestCase):
    async def test_real_two_instance_schedule_continues_during_control_failure(self):
        requests = []
        control_failed = threading.Event()

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                requests.append(self.path)
                self.send_response(503 if self.path == "/unready" else 200)
                self.end_headers()

            def do_POST(self):
                control_failed.set()
                self.send_response(503)
                self.end_headers()

            def log_message(self, *args):
                pass

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            with tempfile.TemporaryDirectory() as directory:
                state = State(directory)
                url = f"http://127.0.0.1:{server.server_port}"
                source = Path(directory, "http_schedule.py")
                source.write_text(
                    """from urllib.request import urlopen
from urllib.error import HTTPError
from mondek_runner import App, Binding, Environment, Result, check
from mondek_runner.api import timestamp
@check(id="request", expected_keys=("readiness",), interval_seconds=0.1,
       timeout_seconds=2, freshness_seconds=12)
def request(*, params):
    try:
        with urlopen(params["url"], timeout=1) as response:
            status = response.status
    except HTTPError as error:
        status = error.code
    return Result("readiness", "OK" if status == 200 else "CRIT",
                  f"HTTP {status}", status, timestamp())
app = App(source_id="http-schedule", environment=Environment("local"), checks=[
    Binding(request, key="ready", params={"url": """
                    + repr(url + "/ready")
                    + """}),
    Binding(request, key="unready", params={"url": """
                    + repr(url + "/unready")
                    + """}),
])
"""
                )
                with patch.dict(
                    os.environ,
                    {
                        "PYTHONPATH": directory
                        + os.pathsep
                        + os.environ.get("PYTHONPATH", "")
                    },
                ):
                    inventory = await snapshot(
                        "http_schedule:app", state.directory / "bundles"
                    )
                    entries = [
                        {
                            **item,
                            "id": str(uuid.uuid4()),
                            "kind": "python",
                            "generation": 1,
                            "source_id": inventory["source_id"],
                            "source_key": item["key"],
                            "source_revision": inventory["source_revision"],
                            "expected_keys": ["readiness"],
                        }
                        for item in inventory["checks"]
                    ]
                    first, second = entries
                    for entry in entries:
                        state.adopt(entry, 0)
                    runner = Runner(
                        state, url, max_concurrency=1, consumer="http_schedule:app"
                    )
                    # Workers use the durable signed snapshot, independently of
                    # controller contact and subsequent discovery attempts.
                    runner.inventory_ready.set()

                    async def retained_inventory():
                        await runner.stopped.wait()

                    runner.discover = retained_inventory
                task = asyncio.create_task(runner.run())
                try:
                    async with asyncio.timeout(8):
                        while state.status()["queue_count"] < 6:
                            await asyncio.sleep(0.05)
                    self.assertTrue(control_failed.is_set())
                    self.assertFalse(runner.registered.is_set())
                    reports = state.batch()
                    for config, health in ((first, "OK"), (second, "CRIT")):
                        matching = [
                            r for r in reports if r["assignment_id"] == config["id"]
                        ]
                        self.assertGreaterEqual(len(matching), 2)
                        self.assertTrue(all(r["complete"] for r in matching))
                        self.assertTrue(
                            all(r["results"][0]["health"] == health for r in matching)
                        )
                        self.assertLess(
                            matching[0]["results"][0]["source_at"],
                            matching[-1]["results"][0]["source_at"],
                        )
                    self.assertIn("/ready", requests)
                    self.assertIn("/unready", requests)
                    self.assertEqual(len({r["id"] for r in reports}), len(reports))
                    self.assertEqual(
                        len({r["sequence"] for r in reports}), len(reports)
                    )
                finally:
                    runner.stopped.set()
                    await task
                    state.close()
        finally:
            await asyncio.to_thread(server.shutdown)
            server.server_close()
            thread.join()
