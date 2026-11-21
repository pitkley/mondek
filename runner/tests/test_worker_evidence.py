# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Exercise encoded evidence limits through a snapshotted consumer and real pipes."""

import asyncio
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from mondek_runner.bundle import snapshot
from mondek_runner.local import assignment
from mondek_runner.runtime import execute

SOURCE_AT = "2026-11-21T00:00:00.000000Z"
MARKER = "[Detail evidence omitted]"
SOURCE = r"""import os
from mondek_runner import (
    App, Environment, Impact, bounded_details, check, crit, ok, warn,
)

SOURCE_AT = "2026-11-21T00:00:00.000000Z"
FIELDS = ("ready", "unacked", "consumers", "broker", "publisher")

@check(id="queues", expected_keys=FIELDS)
def queues():
    os.write(2, b"d" * 4096)
    rows = [
        (f'customer-{i % 31:02}/"vhost\\{i % 12:02}"/重試💥-{i:04}\t' + "\x01" * 24,
         1400 + i, 9100 + i, i % 70, i % 3)
        for i in range(600)
    ]
    changes = bounded_details(
        f"{key}: ready {prior} → {now}" for key, prior, now, _, _ in rows
    )
    yield crit("ready", "600 queues growing", value=len(rows), source_at=SOURCE_AT,
               impacts=(Impact("delays", "Delivery delays"),), details=changes)
    yield warn("unacked", "Unacknowledged deliveries", source_at=SOURCE_AT,
               details=bounded_details(f"{key}: {unacked} unacknowledged"
                                       for key, _, _, unacked, _ in rows))
    stalled = [key for key, _, _, _, consumers in rows if not consumers]
    yield crit("consumers", "200 queues without consumers", value=len(stalled),
               details=bounded_details(f"{key}: no consumers" for key in stalled),
               source_at=SOURCE_AT)
    yield ok("broker", "Broker responding", source_at=SOURCE_AT, details="")
    yield ok("publisher", "Publisher responsive", source_at=SOURCE_AT)

@check(id="fault", expected_keys=("first", "last"))
def fault():
    yield ok("first", "Recorded before fault", source_at=SOURCE_AT,
             details="Short evidence")
    mode = os.environ["EVIDENCE_FAULT"]
    if mode == "crash":
        os._exit(17)
    if mode == "error":
        raise ValueError("caught fault")
    os.write(2, b"x" * int(mode))
    yield ok("last", "After diagnostics", source_at=SOURCE_AT)

@check(id="skewed", expected_keys=FIELDS)
def skewed():
    for index, key in enumerate(FIELDS):
        details = "x" * 16384 if index == 0 else ""
        yield ok(key, "Observed", source_at=SOURCE_AT, details=details)

@check(id="fixed", expected_keys=tuple(f"group-{i}" for i in range(16)))
def fixed():
    for i in range(16):
        yield crit(f"group-{i}", "\x01" * 2048, value=i, source_at=SOURCE_AT)

app = App(source_id="test-queues", environment=Environment("test"),
          checks=[queues, fault, fixed, skewed])
"""


class WorkerEvidenceTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        root = Path(self.enterContext(tempfile.TemporaryDirectory()))
        package = root / "site" / "queue_fixture"
        package.mkdir(parents=True)
        (package / "__init__.py").write_text(SOURCE)
        self.bundles = root / "bundles"
        self.enterContext(
            patch.dict(
                os.environ,
                {
                    "PYTHONPATH": str(package.parent)
                    + os.pathsep
                    + os.environ.get("PYTHONPATH", ""),
                },
            )
        )
        inventory = await snapshot("queue_fixture:app", self.bundles)
        self.config = {
            entry["key"]: assignment(entry, inventory, None)
            for entry in inventory["checks"]
        }

    async def test_degraded_queue_facts_and_wire_budget(self):
        config = self.config["queues"]
        worker = await asyncio.create_subprocess_exec(
            sys.executable,
            "-m",
            "mondek_runner.worker",
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            env={**os.environ, "MONDEK_BUNDLE_DIR": str(self.bundles)},
        )
        stdout, stderr = await asyncio.wait_for(
            worker.communicate(json.dumps(config).encode()), timeout=10
        )
        self.assertEqual(worker.returncode, 0)
        self.assertEqual(stderr, b"d" * 4096)
        self.assertLessEqual(len(stdout) + len(stderr), 65536)
        self.assertTrue(stdout.endswith(b"\n"))
        self.assertEqual(
            json.loads(stdout.splitlines()[-1]), {"complete": True, "diagnostic": None}
        )

        report = await execute(config, bundle_dir=self.bundles)
        self.assertTrue(report["complete"], report["diagnostic"])
        self.assertIsNone(report["diagnostic"])
        rows = report["results"]
        self.assertEqual(
            [(r["key"], r["health"], r["summary"], r["value"]) for r in rows],
            [
                ("ready", "CRIT", "600 queues growing", 600),
                ("unacked", "WARN", "Unacknowledged deliveries", None),
                ("consumers", "CRIT", "200 queues without consumers", 200),
                ("broker", "OK", "Broker responding", None),
                ("publisher", "OK", "Publisher responsive", None),
            ],
        )
        self.assertEqual({r["source_at"] for r in rows}, {SOURCE_AT})
        self.assertEqual(
            rows[0]["impacts"], [{"key": "delays", "label": "Delivery delays"}]
        )
        for row in rows[:3]:
            self.assertIn('customer-00/"vhost\\00"/重試💥-0000\t\x01', row["details"])
            self.assertIn(MARKER, row["details"])
            self.assertLessEqual(len(row["details"].encode()), 16384)
        self.assertEqual(rows[3]["details"], "")
        self.assertNotIn("details", rows[4])

    async def test_skewed_details_stay_exact_when_they_all_fit(self):
        report = await execute(self.config["skewed"], bundle_dir=self.bundles)
        self.assertTrue(report["complete"], report["diagnostic"])
        self.assertEqual(
            [r["details"] for r in report["results"]], ["x" * 16384] + [""] * 4
        )

    async def test_raw_stderr_boundary_and_streaming_faults(self):
        for mode, diagnostic in (
            ("4096", None),
            ("4097", "output exceeded"),
            ("crash", "crashed"),
            ("error", "caught fault"),
        ):
            with self.subTest(mode=mode), patch.dict(os.environ, EVIDENCE_FAULT=mode):
                report = await execute(self.config["fault"], bundle_dir=self.bundles)
                self.assertTrue(report["results"], report["diagnostic"])
                first = report["results"][0]
                self.assertEqual(
                    (
                        first["key"],
                        first["health"],
                        first["summary"],
                        first["source_at"],
                    ),
                    ("first", "OK", "Recorded before fault", SOURCE_AT),
                )
                if diagnostic is None:
                    self.assertTrue(report["complete"], report["diagnostic"])
                    self.assertEqual(
                        [r["key"] for r in report["results"]], ["first", "last"]
                    )
                else:
                    self.assertFalse(report["complete"])
                    self.assertIn(diagnostic, report["diagnostic"])
                if mode in ("4096", "error"):
                    self.assertEqual(first["details"], "Short evidence")
                elif mode == "crash":
                    self.assertEqual(first["details"], MARKER)

    async def test_fixed_data_overflow_retains_complete_facts(self):
        report = await execute(self.config["fixed"], bundle_dir=self.bundles)
        self.assertFalse(report["complete"])
        self.assertIn("fixed result data", report["diagnostic"])
        self.assertGreater(len(report["results"]), 0)
        self.assertLess(len(report["results"]), 16)
        for i, row in enumerate(report["results"]):
            self.assertEqual(
                row,
                {
                    "key": f"group-{i}",
                    "health": "CRIT",
                    "value": i,
                    "source_at": SOURCE_AT,
                    "summary": "\x01" * 2048,
                },
            )

    async def test_malformed_and_unterminated_records_never_establish_coverage(self):
        config = self.config["fault"]
        records = [
            {
                "result": {
                    "key": key,
                    "health": "OK",
                    "summary": "Observed",
                    "value": None,
                    "source_at": SOURCE_AT,
                }
            }
            for key in config["expected_keys"]
        ]
        terminal = {"complete": True, "diagnostic": None}
        spawn = asyncio.create_subprocess_exec
        cases = [
            ("unterminated result", records, "", records[:1]),
            ("unterminated terminal", [*records, terminal], "", records),
            ("unknown record", [*records, {"bogus": True}, terminal], "\n", records),
            ("duplicate result", [*records, records[0], terminal], "\n", records),
            ("after terminal", [*records, terminal, terminal], "\n", records),
            (
                "mixed envelope",
                [{**records[0], "complete": True}, *records[1:], terminal],
                "\n",
                [],
            ),
            (
                "unknown terminal fields",
                [*records, {**terminal, "bogus": 1}],
                "\n",
                records,
            ),
            (
                "conflicting terminal",
                [*records, {**terminal, "diagnostic": "error"}],
                "\n",
                records,
            ),
            (
                "missing facts",
                [
                    records[0],
                    {"result": {"key": "last", "summary": "invalid"}},
                    terminal,
                ],
                "\n",
                records[:1],
            ),
        ]
        for label, messages, ending, retained in cases:
            with self.subTest(label=label):
                output = "\n".join(json.dumps(m) for m in messages) + ending

                async def raw_worker(*args, output=output, **kwargs):
                    return await spawn(
                        sys.executable,
                        "-c",
                        f"import sys; sys.stdin.read(); sys.stdout.write({output!r})",
                        **kwargs,
                    )

                with patch(
                    "mondek_runner.runtime.asyncio.create_subprocess_exec", raw_worker
                ):
                    report = await execute(config, bundle_dir=self.bundles)
                self.assertFalse(report["complete"])
                self.assertEqual(report["results"], [m["result"] for m in retained])
