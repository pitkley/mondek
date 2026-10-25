# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0

from __future__ import annotations

import asyncio
import json
import tempfile
import unittest
import uuid
from unittest.mock import AsyncMock

from mondek_runner.runtime import Runner
from mondek_runner.state import State, inspect


class StatusTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.state = State(self.temp.name)
        self.catalog = self.state.record_inventory(
            {
                "source_id": "large-consumer",
                "source_revision": "f" * 64,
                "checks": [
                    {
                        "key": f"check-{i}",
                        "label": "catalog-only-" + "x" * 180,
                        "outputs": [
                            {"key": str(key), "label": "r" * 200} for key in range(16)
                        ],
                    }
                    for i in range(512)
                ],
            }
        )
        with self.state.db:
            self.state.set("private_internal_setting", "must-not-leak")

    def tearDown(self):
        self.state.close()
        self.temp.cleanup()

    async def test_inspection_allowlist_omits_full_catalog_and_internal_metadata(self):
        self.assertGreater(len(json.dumps(self.catalog)), 256 * 1024)
        status = inspect(self.temp.name)
        encoded = json.dumps(status)
        self.assertLess(len(encoded), 4096)
        self.assertNotIn("catalog-only", encoded)
        self.assertNotIn("must-not-leak", encoded)
        self.assertNotIn("private_internal_setting", status)
        self.assertEqual(status["installation_id"], self.state.installation_id)
        self.assertEqual(status["session_id"], self.state.session_id)
        self.assertEqual(status["boot"], 1)
        self.assertEqual(status["inventory"]["check_count"], 512)
        self.assertEqual(status["inventory"]["result_count"], 8192)
        self.assertEqual(status["inventory"]["inventory_revision"], 1)
        self.assertEqual(status["inventory"]["source_id"], "large-consumer")
        self.assertEqual(self.state.get("boot"), "1")
        self.assertEqual(self.state.inventory(), self.catalog)

    async def test_actual_control_payload_remains_bounded_with_512_groups(self):
        payloads = []
        loop = asyncio.get_running_loop()

        def transport(url, payload, timeout):
            self.assertTrue(url.endswith("/control"))
            payloads.append(payload)
            loop.call_soon_threadsafe(runner.stopped.set)
            return {
                "version": 1,
                "assignments": [],
                "authorized": {},
                "assignments_authoritative": True,
            }

        runner = Runner(
            self.state,
            "http://local.invalid",
            consumer="local_consumer:app",
            transport=transport,
        )
        runner.inventory_sent_session = (self.state.session_id, 1)
        runner.inventory_ready.set()
        runner.active = runner.prepared = {
            str(uuid.uuid4()): {"generation": 1} for _ in range(512)
        }
        await asyncio.wait_for(runner.control(), 2)
        self.assertEqual(len(payloads), 1)
        self.assertEqual(len(payloads[0]["active"]), 512)
        self.assertEqual(len(payloads[0]["prepared"]), 512)
        self.assertLess(len(json.dumps(payloads[0]).encode()), 256 * 1024)
        self.assertLess(len(json.dumps(payloads[0]["status"]).encode()), 16 * 1024)
        self.assertNotIn("catalog-only", json.dumps(payloads[0]))
        self.assertNotIn("must-not-leak", json.dumps(payloads[0]))
        self.assertEqual(payloads[0]["status"]["inventory"]["check_count"], 512)

    async def test_generated_diagnostics_are_safe_to_persist_and_legacy_reads_are_safe(
        self,
    ):
        self.state.diagnostic("bad\x00\ud800" + "é" * 2048)
        diagnostic = self.state.get("diagnostic")
        self.assertTrue(diagnostic.startswith(r"bad\x00\ud800"))
        self.assertLessEqual(len(diagnostic.encode("utf-8")), 2048)
        self.assertNotIn("\x00", diagnostic)
        self.assertEqual(self.state.status()["diagnostic"], diagnostic)

        # Simulate a value written by an older runner without using the new
        # write boundary. Reading status must not change persisted evidence.
        legacy = "old\x00" + "é" * 2048
        with self.state.db:
            self.state.set("diagnostic", legacy)
        runner = Runner(
            self.state, "http://local.invalid", consumer="demo_checks.app:app"
        )
        for status in (runner.status(), inspect(self.temp.name)):
            self.assertTrue(status["diagnostic"].startswith(r"old\x00"))
            self.assertLessEqual(len(status["diagnostic"].encode("utf-8")), 2048)
            self.assertNotIn("\x00", status["diagnostic"])
        self.assertEqual(self.state.get("diagnostic"), legacy)
        self.assertEqual(self.state.inventory(), self.catalog)

    async def test_control_recovers_after_exception_with_non_wire_text(self):
        payloads = []
        loop = asyncio.get_running_loop()

        def transport(url, payload, timeout):
            payloads.append(payload)
            if len(payloads) == 1:
                raise ValueError("bad\x00\udfff" + "é" * 2048)
            loop.call_soon_threadsafe(runner.stopped.set)
            return {
                "version": 1,
                "assignments": [],
                "authorized": {},
                "assignments_authoritative": True,
            }

        runner = Runner(
            self.state,
            "http://local.invalid",
            transport=transport,
            consumer="demo_checks.app:app",
        )

        async def yield_pause(_seconds):
            # Let the transport thread's queued stop callback run even when its
            # future completes before the control task next awaits it.
            await asyncio.sleep(0)

        runner.inventory_ready.set()
        runner.pause = AsyncMock(side_effect=yield_pause)
        await asyncio.wait_for(runner.control(), 2)
        self.assertEqual(len(payloads), 2)
        diagnostic = payloads[1]["status"]["diagnostic"]
        self.assertIn(r"bad\x00\udfff", diagnostic)
        self.assertNotIn("\x00", diagnostic)
        self.assertLessEqual(len(diagnostic.encode("utf-8")), 2048)
        self.assertTrue(runner.registered.is_set())


if __name__ == "__main__":
    unittest.main()
