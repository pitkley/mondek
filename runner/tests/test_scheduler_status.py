# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0

from __future__ import annotations

import asyncio
import json
import tempfile
import unittest

from mondek_runner.runtime import Runner
from mondek_runner.state import State


def config(index, generation=1):
    return {
        "id": f"00000000-0000-4000-8000-{index:012}",
        "kind": "python",
        "source_id": "scheduler-fixture",
        "source_key": f"check-{index}",
        "source_revision": "a" * 64,
        "definition_revision": "b" * 64,
        "generation": generation,
        "expected_keys": ["readiness"],
        "interval_seconds": 1,
        "timeout_seconds": 0.5,
        "freshness_seconds": 3,
        "params": {"url": "http://localhost/ready"},
    }


class SchedulingStatusTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.state = State(self.temp.name)
        self.clock = 100.0
        self.runner = Runner(
            self.state,
            "http://unused",
            max_concurrency=2,
            monotonic=lambda: self.clock,
            consumer="demo_checks.app:app",
        )

    def tearDown(self):
        self.state.close()
        self.temp.cleanup()

    async def test_512_checks_report_waiting_lag_without_per_check_payload(self):
        entries = [config(i) for i in range(512)]
        self.runner.active = {entry["id"]: entry for entry in entries}
        self.runner.due = {entry["id"]: 100.0 - i for i, entry in enumerate(entries)}
        for entry in entries[:2]:
            self.runner.running[entry["id"]] = (
                asyncio.get_running_loop().create_future()
            )
        status = self.runner.status()["scheduler"]
        self.assertEqual(status["active_checks"], 512)
        self.assertEqual(status["running_checks"], 2)
        self.assertEqual(status["max_concurrency"], 2)
        self.assertEqual(status["due_waiting_checks"], 510)
        self.assertEqual(status["oldest_due_seconds"], 511.0)
        self.assertLess(len(json.dumps(status)), 512)
        self.runner.wall_clock = lambda: -1000000
        self.clock += 5
        self.assertEqual(self.runner.scheduler_status()["oldest_due_seconds"], 516.0)
        self.assertEqual(self.state.status()["queue_count"], 0)

    async def test_preparation_activation_retirement_and_future_due_are_distinct(self):
        old, future, retired = config(0), config(1), config(2)
        changed, unprepared = config(0, generation=2), config(3)
        self.runner.active = {item["id"]: item for item in (old, future, retired)}
        self.runner.due = {old["id"]: 90.0, future["id"]: 110.0, retired["id"]: 1.0}
        self.runner.prepared = {item["id"]: item for item in (changed, future)}
        self.runner.reconcile(
            {
                "assignments": [changed, future, unprepared],
                "authorized": {},
                "assignments_authoritative": True,
            }
        )
        status = self.runner.scheduler_status()
        self.assertEqual(status["active_checks"], 2)
        self.assertEqual(status["due_waiting_checks"], 1)
        self.assertEqual(status["oldest_due_seconds"], 10.0)
        self.assertEqual(status["preparation_pending_checks"], 1)
        self.assertEqual(status["prepared_waiting_checks"], 1)
        self.runner.due[old["id"]] = 105.0
        status = self.runner.scheduler_status()
        self.assertEqual(status["due_waiting_checks"], 0)
        self.assertEqual(status["oldest_due_seconds"], 0.0)

    async def test_overdue_running_check_does_not_inflate_waiting_or_skip_older_work(
        self,
    ):
        entries = [config(i) for i in range(3)]
        self.runner.active = {entry["id"]: entry for entry in entries}
        self.runner.due = {entry["id"]: 90.0 for entry in entries}
        self.runner.max_concurrency = 1
        release = asyncio.Event()
        executed = []

        async def worker(assignment, **kwargs):
            executed.append(assignment["id"])
            await release.wait()
            return {"complete": False, "results": [], "diagnostic": "controlled"}

        self.runner.worker = worker
        await self.runner.step()
        await asyncio.sleep(0)
        self.clock += 10
        status = self.runner.scheduler_status()
        self.assertEqual(status["running_checks"], 1)
        self.assertEqual(status["due_waiting_checks"], 2)
        self.assertEqual(status["oldest_due_seconds"], 20.0)
        await self.runner.step()
        self.assertEqual(len(executed), 1)
        release.set()
        await asyncio.gather(*self.runner.running.values())
        await self.runner.step()
        await asyncio.gather(*self.runner.running.values())
        self.assertEqual(executed, [entries[0]["id"], entries[1]["id"]])


if __name__ == "__main__":
    unittest.main()
