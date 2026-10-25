# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0

from __future__ import annotations

import asyncio
import json
import os
import signal
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from http.client import RemoteDisconnected
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest.mock import patch

from demo_checks.backlog import BacklogSnapshot, backlog
from source_fixtures import IDS, assignment, worker_source

from mondek_runner import Result, check
from mondek_runner.api import evaluate, timestamp
from mondek_runner.bundle import snapshot
from mondek_runner.config import validate
from mondek_runner.runtime import Runner, execute, post_json
from mondek_runner.state import State, inspect
from mondek_runner.worker import run as run_worker

ROOT = Path(__file__).resolve().parents[2]


def outcome(report):
    return {
        **report,
        "evaluated_at": timestamp(),
        "results": [
            Result("capacity", "OK", "measured", 1, report["started_at"]).to_dict()
        ],
        "complete": True,
        "diagnostic": None,
    }


class StateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.state = State(self.temp.name, max_reports=2, max_bytes=4096)
        self.state.adopt(assignment(), 0)

    def tearDown(self):
        self.state.close()
        self.temp.cleanup()

    def test_membership_reconciliation_writes_only_changed_rows_atomically(self):
        rows = {str(i): assignment(id=str(i)) for i in range(500)}
        self.state.reconcile_assignments(rows, 10)
        allocated = self.state.allocate(rows["0"], 20, timestamp())
        before = self.state.db.total_changes
        self.state.reconcile_assignments(rows, 30)
        self.assertEqual(self.state.db.total_changes, before)
        changed = rows | {"1": assignment(id="1", generation=2)}
        self.state.reconcile_assignments(changed, 40)
        self.assertEqual(self.state.db.total_changes - before, 1)
        deadlines = dict(self.state.db.execute("SELECT id, next_due FROM assignments"))
        self.assertEqual(deadlines["0"], 20)
        self.assertEqual(deadlines["1"], 40)
        self.assertEqual(deadlines["2"], 10)

        # Removal and replacement are one commit even if encoding a later row fails.
        invalid = {key: value for key, value in changed.items() if key != "0"}
        invalid["1"] = assignment(id="1", generation=3)
        invalid["new"] = {"id": "new", "invalid": object()}
        with self.assertRaises(TypeError):
            self.state.reconcile_assignments(invalid, 50)
        self.assertEqual(self.state.assignments(), changed)
        self.state.reconcile_assignments(
            {key: value for key, value in changed.items() if key != "0"}, 60
        )
        self.assertNotIn("0", self.state.assignments())
        inflight = self.state.db.execute("SELECT payload FROM inflight").fetchone()
        self.assertEqual(json.loads(inflight["payload"]), allocated)

    def test_identity_and_run_order_survive_crash_with_incomplete_evidence(self):
        allocated = self.state.allocate(assignment(), 3, timestamp())
        identity, session, boot = (
            self.state.installation_id,
            self.state.session_id,
            self.state.boot,
        )
        self.state.close()
        self.state = State(self.temp.name)
        self.assertEqual(self.state.installation_id, identity)
        self.assertEqual(self.state.boot, boot + 1)
        self.assertNotEqual(self.state.session_id, session)
        interrupted = self.state.batch()[0]
        self.assertEqual(interrupted["id"], allocated["id"])
        self.assertEqual(interrupted["started_at"], allocated["started_at"])
        self.assertEqual(interrupted["session_id"], session)
        self.assertFalse(interrupted["complete"])
        self.assertEqual(interrupted["results"], [])
        next_run = self.state.allocate(assignment(), 5, timestamp())
        self.assertEqual(next_run["sequence"], allocated["sequence"] + 1)

    def test_two_process_owners_and_overlapping_allocations_are_rejected(self):
        with self.assertRaisesRegex(RuntimeError, "another runner"):
            State(self.temp.name)
        self.state.allocate(assignment(), 3, timestamp())
        with self.assertRaises(sqlite3.IntegrityError):
            self.state.allocate(assignment(), 6, timestamp())
        self.assertEqual(
            inspect(self.temp.name)["inflight"],
            ["10000000-0000-4000-8000-000000000001"],
        )
        self.assertEqual(inspect(self.temp.name)["boot"], 1)

    def test_spool_bounds_drop_oldest_without_retimestamping_survivors(self):
        reports = []
        for _ in range(3):
            report = outcome(self.state.allocate(assignment(), 3, timestamp()))
            self.state.complete(report)
            reports.append(report)
        self.assertEqual(self.state.batch(), reports[1:])
        self.assertEqual(self.state.status()["dropped"], 1)
        self.assertEqual(self.state.status()["oldest_at"], reports[1]["started_at"])
        self.assertIn("continuity unknown", self.state.status()["diagnostic"])
        self.assertLessEqual(self.state.status()["queue_bytes"], 4096)
        self.state.acknowledge([reports[1]["id"]])
        self.assertEqual(self.state.batch(), reports[2:])

    def test_oversized_report_is_explicit_loss_and_does_not_poison_queue(self):
        report = outcome(self.state.allocate(assignment(), 3, timestamp()))
        report["diagnostic"] = "x" * 5000
        self.state.complete(report)
        self.assertEqual(self.state.batch(), [])
        self.assertEqual(self.state.status()["dropped"], 1)
        self.assertEqual(inspect(self.temp.name)["inflight"], [])

    def test_cross_language_fixture_preserves_identity_source_age_and_exact_replay(
        self,
    ):
        fixture = json.loads((ROOT / "contracts/v1/observation.json").read_text())
        with self.state.db:
            self.state._enqueue(fixture)
        first = self.state.batch()
        self.assertEqual(first, [fixture])
        self.assertEqual(self.state.batch(), first)  # A lost reply leaves exact bytes.
        self.assertEqual(
            first[0]["results"][0]["source_at"], "2009-09-15T08:00:00.010000Z"
        )
        self.assertEqual(first[0]["sequence"], 7)
        self.state.acknowledge([fixture["id"]])
        self.assertEqual(self.state.batch(), [])


class AuthoringTests(unittest.IsolatedAsyncioTestCase):
    async def test_source_timestamp_errors_become_valid_incomplete_evidence(self):
        now = "2009-09-15T08:00:00.000000Z"
        invalid = (
            "not-a-time",
            42,
            "2009-09-15T08:00:00Z",
            "2009-09-15T08:00:00.000000+02:00",
            "2009-09-15T08:00:00.000001Z",
            "1999-12-31T23:59:59.999999Z",
            "2009-09-31T08:00:00.000000Z",
        )
        for source_at in invalid:
            with self.subTest(source_at=source_at):

                @check(expected_keys=("capacity",))
                def invalid_source(*, params, source_at=source_at):
                    return Result("capacity", "OK", "invalid source time", 1, source_at)

                messages = []
                with (
                    worker_source(invalid_source),
                    patch("mondek_runner.worker.timestamp", return_value=now),
                    patch("mondek_runner.worker.emit", side_effect=messages.append),
                ):
                    await run_worker(assignment())
                self.assertEqual(len(messages), 1)
                self.assertFalse(messages[0]["complete"])
                self.assertIsInstance(messages[0]["diagnostic"], str)

    async def test_valid_source_timestamp_and_unknown_age_are_preserved(self):
        for source_at in (
            None,
            "2009-09-01T08:00:00.000000Z",
            "2009-09-01T08:00:00.000000+00:00",
        ):

            @check(expected_keys=("capacity",))
            def source(*, params, source_at=source_at):
                return Result("capacity", "OK", "original source time", 1, source_at)

            messages = []
            with (
                worker_source(source),
                patch("mondek_runner.worker.emit", side_effect=messages.append),
            ):
                await run_worker(assignment())
            self.assertEqual(messages[0]["result"]["source_at"], source_at)
            self.assertTrue(messages[-1]["complete"])

    async def test_unicode_worker_errors_fit_protocol_byte_limit(self):
        @check(expected_keys=("capacity",))
        def failing(*, params):
            raise ValueError("💥" * 2000)

        messages = []
        with (
            worker_source(failing),
            patch("mondek_runner.worker.emit", side_effect=messages.append),
        ):
            await run_worker(assignment())
        self.assertFalse(messages[-1]["complete"])
        diagnostic = messages[-1]["diagnostic"]
        self.assertTrue(diagnostic.startswith("ValueError: 💥"))
        self.assertLessEqual(len(diagnostic.encode()), 2048)

    async def test_sync_async_generators_and_single_results(self):
        @check(expected_keys=("capacity",))
        def sync():
            yield Result("capacity", "OK", "sync")

        @check(expected_keys=("capacity",))
        async def async_generator():
            yield Result("capacity", "WARN", "async")

        @check(expected_keys=("capacity",))
        async def coroutine():
            return Result("capacity", "CRIT", "coroutine")

        for function, health in (
            (sync, "OK"),
            (async_generator, "WARN"),
            (coroutine, "CRIT"),
        ):
            self.assertEqual([r.health async for r in evaluate(function)], [health])

    async def test_datasource_injection_preserves_original_source_age(self):
        class Source:
            async def collect(self):
                return BacklogSnapshot(6, "2009-09-01T01:00:00.000000Z")

        result = await backlog(
            params=assignment("10000000-0000-4000-8000-000000000003")["params"],
            datasource=Source(),
        )
        self.assertEqual(result.health, "WARN")
        self.assertEqual(result.source_at, "2009-09-01T01:00:00.000000Z")

    async def test_partial_generator_failure_preserves_fact_without_complete_coverage(
        self,
    ):
        @check(expected_keys=("capacity",))
        def partial(*, params):
            yield Result("capacity", "CRIT", "measured before failure", 95, timestamp())
            raise RuntimeError("source stopped midway")

        messages = []
        with worker_source(partial):
            with patch("mondek_runner.worker.emit", side_effect=messages.append):
                await run_worker(assignment())
        self.assertEqual(messages[0]["result"]["health"], "CRIT")
        self.assertFalse(messages[1]["complete"])
        self.assertIn("source stopped midway", messages[1]["diagnostic"])

    async def test_missing_output_and_summary_cap_do_not_establish_coverage(self):
        @check(expected_keys=("capacity",))
        def missing(*, params):
            return []

        @check(expected_keys=("capacity",))
        def oversized(*, params):
            return Result("capacity", "OK", "ü" * 1025)

        for function, message in (
            (missing, "missing expected"),
            (oversized, "output cap"),
        ):
            messages = []
            with worker_source(function):
                with patch("mondek_runner.worker.emit", side_effect=messages.append):
                    await run_worker(assignment())
            self.assertFalse(messages[-1]["complete"])
            self.assertIn(message, messages[-1]["diagnostic"])


class SchedulerTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.state = State(self.temp.name)
        self.state.adopt(assignment(), 0)
        self.clock = 100.0

    async def asyncTearDown(self):
        self.state.close()
        self.temp.cleanup()

    async def test_control_wait_tracks_complete_adoption_and_registration(self):
        runner = Runner(self.state, "http://unused", consumer="demo_checks.app:app")
        self.assertEqual(runner.control_wait_seconds(), 2)
        runner.desired = dict(runner.active)
        runner.prepared = dict(runner.active)
        runner.control_authoritative = True
        runner.registered.set()
        runner.inventory = {"inventory_revision": 1}
        runner.inventory_sent_session = (self.state.session_id, 1)
        runner.inventory_ready.set()
        runner.inventory_refresh_needed.clear()
        self.assertEqual(runner.control_wait_seconds(), 5)
        runner.prepared = {}
        self.assertEqual(runner.control_wait_seconds(), 2)
        runner.prepared = dict(runner.active)
        runner.desired = {
            "10000000-0000-4000-8000-000000000001": assignment(generation=2)
        }
        self.assertEqual(runner.control_wait_seconds(), 2)
        runner.desired = dict(runner.active)
        runner.control_authoritative = False
        self.assertEqual(runner.control_wait_seconds(), 2)
        runner.control_authoritative = True
        runner.registered.clear()
        self.assertEqual(runner.control_wait_seconds(), 2)

    async def test_consumer_wait_requires_accepted_inventory_without_restoration(self):
        runner = Runner(self.state, "http://unused", consumer="example:app")
        runner.desired = dict(runner.active)
        runner.prepared = dict(runner.active)
        runner.control_authoritative = True
        runner.registered.set()
        runner.inventory_refresh_needed.clear()
        self.assertEqual(runner.control_wait_seconds(), 2)
        runner.inventory = {"inventory_revision": 1}
        self.assertEqual(runner.control_wait_seconds(), 2)
        runner.inventory_sent_session = (self.state.session_id, 1)
        self.assertEqual(runner.control_wait_seconds(), 5)
        runner.inventory_refresh_needed.set()
        self.assertEqual(runner.control_wait_seconds(), 2)
        runner.inventory_refresh_needed.clear()
        runner.inventory_refresh_revision = 2
        runner.inventory_refresh_floor = 1
        self.assertEqual(runner.control_wait_seconds(), 2)
        runner.inventory_refresh_revision = 0
        runner.inventory["inventory_revision"] = 2
        self.assertEqual(runner.control_wait_seconds(), 2)

    async def test_saturated_single_slot_does_not_starve_later_assignments(self):
        for kind in (
            "10000000-0000-4000-8000-000000000002",
            "10000000-0000-4000-8000-000000000003",
        ):
            self.state.adopt(assignment(kind), 0)
        executed = []

        async def worker(config, **kwargs):
            executed.append(config["id"])
            self.assertEqual(len(inspect(self.temp.name)["inflight"]), 1)
            self.clock += 2
            return {"results": [], "complete": False, "diagnostic": "timed out"}

        runner = Runner(
            self.state,
            "http://unused",
            max_concurrency=1,
            monotonic=lambda: self.clock,
            worker=worker,
            consumer="demo_checks.app:app",
        )
        for _ in range(12):
            await runner.step()
            await asyncio.gather(*runner.running.values())
        for kind in (
            "10000000-0000-4000-8000-000000000001",
            "10000000-0000-4000-8000-000000000002",
            "10000000-0000-4000-8000-000000000003",
        ):
            self.assertEqual(executed.count(kind), 4)

    async def test_unicode_supervision_errors_fit_protocol_byte_limit(self):
        async def worker(config, **kwargs):
            raise OSError("💥" * 2000)

        runner = Runner(
            self.state, "http://unused", worker=worker, consumer="demo_checks.app:app"
        )
        await runner.step()
        await asyncio.gather(*runner.running.values())
        report = self.state.batch()[0]
        self.assertFalse(report["complete"])
        self.assertLessEqual(len(report["diagnostic"].encode()), 2048)

    async def test_no_overlap_frozen_configuration_and_no_catchup_storm(self):
        started, release = asyncio.Event(), asyncio.Event()
        executed = []

        async def worker(config, **kwargs):
            executed.append(config)
            self.assertEqual(
                inspect(self.temp.name)["inflight"],
                ["10000000-0000-4000-8000-000000000001"],
            )
            started.set()
            await release.wait()
            return {"results": [], "complete": False, "diagnostic": "controlled"}

        runner = Runner(
            self.state,
            "http://unused",
            monotonic=lambda: self.clock,
            worker=worker,
            consumer="demo_checks.app:app",
        )
        await runner.step()
        await started.wait()
        runner.active["10000000-0000-4000-8000-000000000001"] = assignment(generation=2)
        self.clock += 1000
        for _ in range(100):
            await runner.step()
        self.assertEqual(len(executed), 1)
        self.assertEqual(executed[0]["generation"], 1)
        release.set()
        await asyncio.gather(*runner.running.values())
        await runner.step()
        await asyncio.gather(*runner.running.values())
        self.assertEqual(len(executed), 2)
        self.assertEqual(executed[1]["generation"], 2)
        await runner.step()
        self.assertEqual(runner.running, {})

    async def test_failed_prepare_keeps_prior_config_and_exact_authorization_required(
        self,
    ):
        ready = asyncio.Event()

        async def worker(config, **kwargs):
            ready.set()
            return {"prepared": True}

        runner = Runner(
            self.state, "http://unused", worker=worker, consumer="demo_checks.app:app"
        )
        changed = assignment(generation=2)
        changed["kind"] = "filesystem"  # Pre-source built-ins are not executable.
        with self.assertRaises(ValueError):
            runner.reconcile(
                {
                    "assignments": [changed],
                    "authorized": {"10000000-0000-4000-8000-000000000001": 1},
                }
            )
        task = asyncio.create_task(runner.prepare())
        await asyncio.sleep(0)
        self.assertEqual(
            runner.active["10000000-0000-4000-8000-000000000001"]["generation"], 1
        )
        changed = assignment(generation=3)
        runner.reconcile(
            {
                "assignments": [changed],
                "authorized": {"10000000-0000-4000-8000-000000000001": 1},
            }
        )
        await asyncio.wait_for(ready.wait(), 1)
        self.assertEqual(
            runner.active["10000000-0000-4000-8000-000000000001"]["generation"], 1
        )
        runner.reconcile(
            {
                "assignments": [changed],
                "authorized": {"10000000-0000-4000-8000-000000000001": 3},
            }
        )
        self.assertEqual(
            self.state.assignments()["10000000-0000-4000-8000-000000000001"][
                "generation"
            ],
            3,
        )
        task.cancel()
        await asyncio.gather(task, return_exceptions=True)

    async def test_slow_check_and_blocked_control_do_not_block_upload(self):
        worker_started, worker_release = asyncio.Event(), asyncio.Event()
        control_started, control_release, uploaded = (
            threading.Event(),
            threading.Event(),
            threading.Event(),
        )
        buffered = outcome(self.state.allocate(assignment(), 0, timestamp()))
        self.state.complete(buffered)

        async def worker(config, **kwargs):
            if kwargs.get("prepare"):
                return {"prepared": True}
            worker_started.set()
            await worker_release.wait()
            return {"results": [], "complete": False, "diagnostic": "controlled"}

        def transport(url, body, timeout):
            if url.endswith("control"):
                self.assertEqual(timeout, 8)
                self.assertEqual(body["wait_seconds"], 5)
                control_started.set()
                control_release.wait(2)
                return {
                    "version": 1,
                    "assignments": [assignment()],
                    "authorized": {"10000000-0000-4000-8000-000000000001": 1},
                }
            uploaded.set()
            self.assertEqual(body["reports"], [buffered])
            return {
                "version": 1,
                "dispositions": [{"id": buffered["id"], "disposition": "duplicate"}],
            }

        runner = Runner(
            self.state,
            "http://unused",
            worker=worker,
            transport=transport,
            consumer="demo_checks.app:app",
        )
        runner.desired = dict(runner.active)
        runner.prepared = dict(runner.active)
        runner.control_authoritative = True
        runner.registered.set()
        runner.inventory = {
            "inventory_revision": 1,
            "source_id": "mock",
            "source_revision": "a" * 64,
            "checks": [],
        }
        runner.inventory_sent_session = (self.state.session_id, 1)
        runner.inventory_ready.set()
        runner.inventory_refresh_needed.clear()

        async def retained_inventory():
            await runner.stopped.wait()

        runner.discover = retained_inventory
        task = asyncio.create_task(runner.run())
        try:
            await asyncio.wait_for(worker_started.wait(), 1)
            self.assertTrue(await asyncio.to_thread(control_started.wait, 1))
            self.assertTrue(await asyncio.to_thread(uploaded.wait, 1))
            self.assertEqual(len(runner.running), 1)
        finally:
            control_release.set()
            worker_release.set()
            runner.stopped.set()
            await task

    async def test_background_failure_cannot_leave_a_heartbeat_only_runner(self):
        runner = Runner(self.state, "http://unused", consumer="demo_checks.app:app")

        async def failed_scheduler():
            raise RuntimeError("journal unavailable")

        runner.scheduler = failed_scheduler
        with self.assertRaisesRegex(RuntimeError, "journal unavailable"):
            await runner.run()
        self.assertTrue(runner.stopped.is_set())


class LocalService:
    def __init__(self):
        self.status = 200
        self.data = {"backlog": 2}
        self.accepted = []
        owner = self

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(owner.status if self.path == "/ready" else 200)
                self.end_headers()
                self.wfile.write(json.dumps(owner.data).encode())

            def do_POST(self):
                payload = json.loads(
                    self.rfile.read(int(self.headers["Content-Length"]))
                )
                owner.accepted.append(payload)
                if len(owner.accepted) == 1:
                    self.close_connection = True  # Commit then lose the reply.
                    return
                self.send_response(200)
                self.end_headers()
                self.wfile.write(
                    json.dumps(
                        {
                            "version": 1,
                            "dispositions": [
                                {"id": report["id"], "disposition": "duplicate"}
                                for report in payload["reports"]
                            ],
                        }
                    ).encode()
                )

            def log_message(self, format, *args):
                pass

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.url = f"http://127.0.0.1:{self.server.server_port}"

    def close(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()


class ProcessTransportTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.service = LocalService()
        self.temp = tempfile.TemporaryDirectory()
        self.bundles = Path(self.temp.name)
        with patch.dict(os.environ, {"MONDEK_DEMO_TARGET_URL": self.service.url}):
            self.inventory = await snapshot("demo_checks.app:app", self.bundles)

    def assignment(self, kind="filesystem", **overrides):
        key = next((key for key, value in IDS.items() if value == kind), kind)
        entry = next(row for row in self.inventory["checks"] if row["key"] == key)
        return {
            **entry,
            "id": IDS[key],
            "kind": "python",
            "generation": 1,
            "source_id": self.inventory["source_id"],
            "source_key": key,
            "source_revision": self.inventory["source_revision"],
            "expected_keys": [output["key"] for output in entry["outputs"]],
            **overrides,
        }

    async def execute(self, config, **kwargs):
        return await execute(config, bundle_dir=self.bundles, **kwargs)

    async def asyncTearDown(self):
        await asyncio.to_thread(self.service.close)
        self.temp.cleanup()

    def consumer(self, **overrides):
        config = self.assignment("10000000-0000-4000-8000-000000000003", **overrides)
        config["params"]["url"] = self.service.url + "/data"
        return config

    async def test_real_filesystem_and_http_failure_then_measured_recovery(self):
        measured = await self.execute(self.assignment())
        self.assertTrue(measured["complete"], measured)
        self.assertGreaterEqual(measured["results"][0]["value"], 0)
        config = self.assignment("10000000-0000-4000-8000-000000000002")
        config["params"]["url"] = self.service.url + "/ready"
        for status, health in ((503, "CRIT"), (200, "OK")):
            self.service.status = status
            result = await self.execute(config)
            self.assertTrue(result["complete"])
            self.assertEqual(result["results"][0]["health"], health)
            self.assertIsNotNone(result["results"][0]["source_at"])

    async def test_real_async_consumer_recollects_unchanged_data(self):
        first = await self.execute(self.consumer())
        second = await self.execute(self.consumer())
        self.assertTrue(first["complete"], first)
        self.assertTrue(second["complete"], second)
        self.assertEqual(first["results"][0]["value"], second["results"][0]["value"])
        self.assertLess(
            first["results"][0]["source_at"], second["results"][0]["source_at"]
        )

    async def test_real_slow_crashed_noisy_and_huge_source_workers_are_bounded(self):
        cases = (
            ({"backlog": 2, "delay_seconds": 10}, "timed out"),
            ({"backlog": 2, "crash": True}, "crashed"),
            ({"backlog": 2, "output_bytes": 100000}, "output exceeded"),
            ({"backlog": 2, "padding": "x" * 70000}, "response exceeded"),
            ({"backlog": "invalid"}, "nonnegative integer"),
        )
        for data, expected in cases:
            with self.subTest(expected=expected):
                self.service.data = data
                result = await self.execute(self.consumer(timeout_seconds=0.5))
                self.assertFalse(result["complete"], result)
                self.assertIn(expected, result["diagnostic"])

    async def test_lost_http_reply_retries_exact_envelope_and_source_age(self):
        fixture = json.loads((ROOT / "contracts/v1/observation.json").read_text())
        envelope = {
            "version": 1,
            "installation_id": fixture["installation_id"],
            "session_id": fixture["session_id"],
            "reports": [fixture],
        }
        with self.assertRaises(RemoteDisconnected):
            await asyncio.to_thread(post_json, self.service.url, envelope, 1)
        response = await asyncio.to_thread(post_json, self.service.url, envelope, 1)
        self.assertEqual(response["dispositions"][0]["disposition"], "duplicate")
        self.assertEqual(self.service.accepted, [envelope, envelope])

    async def test_preparation_imports_real_consumer_without_collecting_datasource(
        self,
    ):
        config = self.assignment(
            "10000000-0000-4000-8000-000000000003"
        )  # Unreachable target does not block preparation.
        result = await self.execute(config, prepare=True)
        self.assertTrue(result["prepared"], result)

    async def test_slow_preparation_outlives_old_watchdog_and_collection_budget(self):
        # Delay inside load_snapshot, after the child watchdog starts. Preparation
        # must not inherit this assignment's two-second collection deadline.
        with tempfile.TemporaryDirectory() as directory:
            Path(directory, "sitecustomize.py").write_text(
                "import time\n"
                "import mondek_runner.bundle as bundle\n"
                "original = bundle.load_snapshot\n"
                "def delayed(*args, **kwargs):\n"
                "    time.sleep(5)\n"
                "    return original(*args, **kwargs)\n"
                "bundle.load_snapshot = delayed\n"
            )
            with patch.dict(
                os.environ,
                {
                    "PYTHONPATH": directory
                    + os.pathsep
                    + os.environ.get("PYTHONPATH", "")
                },
            ):
                result = await self.execute(
                    self.assignment("10000000-0000-4000-8000-000000000003"),
                    prepare=True,
                )
            self.assertEqual(result, {"prepared": True, "diagnostic": None})

    async def test_hung_preparation_is_killed_and_next_preparation_recovers(self):
        with tempfile.TemporaryDirectory() as directory:
            pid_file = Path(directory, "pid")
            Path(directory, "sitecustomize.py").write_text(
                "import os, time\n"
                "from pathlib import Path\n"
                "import mondek_runner.bundle as bundle\n"
                "def hung(*args, **kwargs):\n"
                f"    Path({str(pid_file)!r}).write_text(str(os.getpid()))\n"
                "    time.sleep(60)\n"
                "bundle.load_snapshot = hung\n"
            )
            with (
                patch.dict(
                    os.environ,
                    {
                        "PYTHONPATH": directory
                        + os.pathsep
                        + os.environ.get("PYTHONPATH", "")
                    },
                ),
                patch("mondek_runner.runtime.PREPARATION_TIMEOUT_SECONDS", 2),
            ):
                result = await self.execute(
                    self.assignment("10000000-0000-4000-8000-000000000003"),
                    prepare=True,
                )
            self.assertFalse(result["prepared"])
            self.assertIn("preparation timed out after 2s", result["diagnostic"])
            self.assertIn("no collection attempted", result["diagnostic"])
            with self.assertRaises(ProcessLookupError):
                os.kill(int(pid_file.read_text()), 0)
            recovered = await self.execute(
                self.assignment("10000000-0000-4000-8000-000000000003"), prepare=True
            )
            self.assertTrue(recovered["prepared"], recovered)


class TransportDeadlineTests(unittest.TestCase):
    def setUp(self):
        self.requests = []
        requests = self.requests

        class DripHandler(BaseHTTPRequestHandler):
            def do_POST(self):
                self.rfile.read(int(self.headers["Content-Length"]))
                requests.append(self.path)
                try:
                    if self.path == "/headers":
                        raw = (
                            b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n"
                        )
                    else:
                        self.send_response(200)
                        self.end_headers()
                        raw = b'{"version":1,"padding":"' + b"x" * 100 + b'"}'
                    for byte in raw:
                        self.wfile.write(bytes([byte]))
                        self.wfile.flush()
                        time.sleep(0.03)
                except (BrokenPipeError, ConnectionResetError):
                    pass

            def log_message(self, *args):
                pass

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), DripHandler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.url = f"http://127.0.0.1:{self.server.server_port}"

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()

    def test_drip_headers_and_body_hit_total_deadline_and_helpers_are_reaped(self):
        helpers = []
        popen = subprocess.Popen

        def track_helper(*args, **kwargs):
            child = popen(*args, **kwargs)
            helpers.append(child)
            return child

        with patch(
            "mondek_runner.transport.subprocess.Popen", side_effect=track_helper
        ):
            for path in ("/headers", "/body", "/headers", "/body"):
                with self.subTest(path=path):
                    started = time.monotonic()
                    with self.assertRaisesRegex(TimeoutError, "total deadline"):
                        post_json(self.url + path, {"version": 1}, 0.4)
                    self.assertLess(time.monotonic() - started, 1.5)
                    self.assertIn(path, self.requests)
                    self.assertIsNotNone(helpers[-1].returncode)
                    with self.assertRaises(ChildProcessError):
                        os.waitpid(helpers[-1].pid, os.WNOHANG)
        self.assertEqual(len(helpers), 4)

    def test_helper_deadline_terminates_without_supervisor_timeout(self):
        child = subprocess.Popen(
            [
                sys.executable,
                "-m",
                "mondek_runner.transport",
                "0.4",
                self.url + "/body",
            ],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        try:
            child.communicate(b'{"version":1}', timeout=2)
            self.assertEqual(child.returncode, -signal.SIGALRM)
            self.assertEqual(self.requests, ["/body"])
        finally:
            if child.poll() is None:
                child.kill()
                child.wait()


class ValidationTests(unittest.TestCase):
    def test_typed_complete_bounds_and_fixed_membership(self):
        for kind in (
            "10000000-0000-4000-8000-000000000001",
            "10000000-0000-4000-8000-000000000002",
            "10000000-0000-4000-8000-000000000003",
        ):
            self.assertEqual(validate(assignment(kind)), assignment(kind))
        for field, value in (
            ("kind", "filesystem"),
            ("id", "filesystem"),
            ("expected_keys", []),
            ("source_revision", "bad"),
            ("params", []),
        ):
            with self.subTest(field=field), self.assertRaises(ValueError):
                config = assignment()
                config[field] = value
                validate(config)

    def test_generation_matches_controller_integer_storage_bound(self):
        self.assertEqual(
            validate(assignment(generation=2_147_483_647))["generation"], 2_147_483_647
        )
        for generation in (True, 0, -1, 2_147_483_648):
            with self.subTest(generation=generation), self.assertRaises(ValueError):
                validate(assignment(generation=generation))


if __name__ == "__main__":
    unittest.main()
