# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0

from __future__ import annotations

import itertools
import os
import tempfile
import unittest
import uuid
from dataclasses import FrozenInstanceError
from pathlib import Path
from unittest.mock import patch

from source_fixtures import assignment as fixture_assignment
from source_fixtures import worker_source

from mondek_runner import (
    Result,
    ResultBuilder,
    build_result,
    crit,
    ok,
    unknown,
    warn,
)
from mondek_runner.api import MAX_DETAILS_BYTES, evaluate
from mondek_runner.bundle import snapshot
from mondek_runner.runtime import execute
from mondek_runner.worker import run as run_worker

SOURCE_AT = "2009-01-02T03:04:05.123456Z"


class ResultDetailsTests(unittest.TestCase):
    def test_old_positional_result_and_absent_details_keep_wire_shape(self):
        result = Result("health", "OK", "measured", 3, SOURCE_AT)
        self.assertEqual(
            result.to_dict(),
            {
                "key": "health",
                "health": "OK",
                "summary": "measured",
                "value": 3,
                "source_at": SOURCE_AT,
            },
        )
        self.assertNotIn("details", ok("health", "measured").to_dict())
        self.assertEqual(ok("health", "measured", details="").to_dict()["details"], "")

    def test_helpers_preserve_exact_multiline_details_and_source_time(self):
        details = "Collected: original source time\n<script>plain text</script>\n測定"
        for helper, health in (
            (ok, "OK"),
            (warn, "WARN"),
            (crit, "CRIT"),
            (unknown, "UNKNOWN"),
        ):
            with self.subTest(health=health):
                result = helper(
                    "health", "measured", details=details, source_at=SOURCE_AT, value=3
                )
                self.assertEqual(result.health, health)
                self.assertEqual(result.to_dict()["details"], details)
                self.assertEqual(result.source_at, SOURCE_AT)
                with self.assertRaises(FrozenInstanceError):
                    result.details = "changed"

    def test_details_have_utf8_byte_boundary_and_no_nul_or_nontext(self):
        exact = "é" * (MAX_DETAILS_BYTES // 2)
        self.assertEqual(ok("health", "measured", details=exact).details, exact)
        for invalid in (exact + "x", "bad\x00text", 3, {"context": "value"}, "\ud800"):
            with self.subTest(invalid_type=type(invalid).__name__):
                with self.assertRaises(ValueError):
                    Result("health", "OK", "measured", details=invalid)

    def test_builder_precedence_never_loses_a_worse_finding(self):
        for order in itertools.permutations(("OK", "WARN", "UNKNOWN", "CRIT")):
            builder = build_result("health", ok_summary="Valid", fail_summary="Invalid")
            expected = "OK"
            rank = {"OK": 0, "WARN": 1, "UNKNOWN": 2, "CRIT": 3}
            for health in order:
                builder.add(health, "finding")
                expected = max((expected, health), key=rank.__getitem__)
                self.assertEqual(builder.finalize().health, expected)

    def test_builder_overall_summaries_reject_nul_before_emission(self):
        for field in ("ok_summary", "fail_summary"):
            summaries = {"ok_summary": "Valid", "fail_summary": "Invalid"}
            summaries[field] += "\x00hidden"
            with self.assertRaisesRegex(ValueError, "without NUL"):
                build_result("health", **summaries)

    def test_builder_details_order_and_summary_selection(self):
        builder = ResultBuilder(
            "health", ok_summary="Valid", fail_summary="Invalid", base_details="Context"
        )
        self.assertEqual(builder.finalize().summary, "Valid")
        builder.ok("Connected").warn("Slow", details="Elapsed: 3 seconds")
        self.assertEqual(builder.finalize().summary, "Invalid")
        self.assertEqual(
            builder.finalize().details,
            "Context\n\n[OK] Connected\n\n[WARN] Slow\nElapsed: 3 seconds",
        )

    def test_builder_creation_time_and_immutable_snapshots(self):
        with patch("mondek_runner.api.timestamp", return_value=SOURCE_AT) as clock:
            builder = build_result("health", ok_summary="Valid", fail_summary="Invalid")
            before = builder.finalize()
            builder.crit("Failed")
            after = builder.finalize()
            clock.assert_called_once_with()
        self.assertEqual(before.health, "OK")
        self.assertIsNone(before.details)
        self.assertEqual(after.health, "CRIT")
        self.assertEqual(before.source_at, after.source_at)
        self.assertEqual(after.source_at, SOURCE_AT)
        for source_at in (None, SOURCE_AT):
            original = build_result(
                "health",
                ok_summary="Valid",
                fail_summary="Invalid",
                source_at=source_at,
            )
            self.assertEqual(original.finalize().source_at, source_at)

    def test_builder_finding_bound_poison_prevents_partial_healthy_finalization(self):
        builder = build_result("health", ok_summary="Valid", fail_summary="Invalid")
        for _ in range(128):
            builder.ok("Passed")
        self.assertEqual(builder.finalize().health, "OK")
        with self.assertRaisesRegex(ValueError, "128 findings"):
            builder.crit("Must not disappear")
        with self.assertRaisesRegex(ValueError, "128 findings"):
            builder.finalize()
        with self.assertRaisesRegex(ValueError, "128 findings"):
            builder.ok("Still cannot finalize")

    def test_builder_combined_details_limit_counts_markers_and_separators(self):
        builder = build_result("health", ok_summary="Valid", fail_summary="Invalid")
        builder.ok("a", details="x" * (MAX_DETAILS_BYTES - len("[OK] a\n")))
        self.assertEqual(len(builder.finalize().details.encode()), MAX_DETAILS_BYTES)
        with self.assertRaisesRegex(ValueError, "16384-byte"):
            builder.crit("Too large")
        with self.assertRaisesRegex(ValueError, "16384-byte"):
            builder.finalize()
        base = build_result(
            "health",
            ok_summary="Valid",
            fail_summary="Invalid",
            base_details="x" * (MAX_DETAILS_BYTES - len("\n\n[OK] a")),
        )
        base.ok("a")
        self.assertEqual(len(base.finalize().details.encode()), MAX_DETAILS_BYTES)


class ResultExecutionTests(unittest.IsolatedAsyncioTestCase):
    async def test_returned_and_yielded_builders_sync_and_async(self):
        def builder():
            return build_result(
                "health",
                ok_summary="Valid",
                fail_summary="Invalid",
                source_at=SOURCE_AT,
            ).unknown("No remote response")

        def direct():
            return builder()

        def iterable():
            return [builder(), ok("other", "measured")]

        async def coroutine():
            return builder()

        def generator():
            yield builder()

        async def async_generator():
            yield builder()

        for function in (direct, iterable, coroutine, generator, async_generator):
            with self.subTest(function=function.__name__):
                results = [result async for result in evaluate(function)]
                self.assertTrue(all(isinstance(result, Result) for result in results))
                self.assertEqual(results[0].health, "UNKNOWN")
                self.assertEqual(results[0].details, "[UNKNOWN] No remote response")
                self.assertEqual(results[0].source_at, SOURCE_AT)

    async def test_builder_finalizes_at_emission_before_later_mutation(self):
        builder = build_result("health", ok_summary="Valid", fail_summary="Invalid")

        def generator():
            yield builder
            builder.crit("Later failure")
            yield builder

        results = [result async for result in evaluate(generator)]
        self.assertEqual([result.health for result in results], ["OK", "CRIT"])
        self.assertIsNone(results[0].details)
        self.assertEqual(results[1].details, "[CRIT] Later failure")
        self.assertEqual(results[0].source_at, results[1].source_at)

    async def test_invalid_details_fail_collection_and_preserve_earlier_evidence(self):
        def check_with_invalid_details(*, params):
            yield ok("capacity", "Measured", details="Original", source_at=SOURCE_AT)
            yield crit("capacity", "Too much context", details="x" * 16385)

        check_with_invalid_details.expected_keys = ("capacity",)
        assignment = fixture_assignment()
        messages = []
        with (
            worker_source(check_with_invalid_details),
            patch("mondek_runner.worker.emit", side_effect=messages.append),
        ):
            await run_worker(assignment)
        self.assertEqual(messages[0]["result"]["details"], "Original")
        self.assertEqual(messages[0]["result"]["source_at"], SOURCE_AT)
        self.assertFalse(messages[-1]["complete"])
        self.assertIn("16384-byte", messages[-1]["diagnostic"])

    async def test_real_worker_transports_details_and_keeps_combined_output_cap(self):
        source = """from mondek_runner import (
    App, Environment, build_result, check, ok,
)
@check(id="normal", expected_keys=("health",), timeout_seconds=3)
def normal():
    return build_result("health", ok_summary="Valid", fail_summary="Invalid",
        source_at="2009-01-02T03:04:05.123456Z"
    ).warn("Old backup", details="Started: original")
@check(id="large", expected_keys=tuple(str(i) for i in range(5)), timeout_seconds=3)
def large():
    for i in range(5):
        yield ok(str(i), "Measured", details="x" * 16384,
                 source_at="2009-01-02T03:04:05.123456Z")
app = App(source_id="details-test", environment=Environment("test"),
          checks=[normal, large])
"""
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            package = root / "site" / "details_consumer"
            package.mkdir(parents=True)
            (package / "__init__.py").write_text(source)
            distribution = package.parent / "details_consumer-1.0.dist-info"
            distribution.mkdir()
            (distribution / "METADATA").write_text(
                "Name: details-consumer\nVersion: 1.0\n"
            )
            with patch.dict(
                os.environ,
                {"PYTHONPATH": f"{package.parent}:{os.environ.get('PYTHONPATH', '')}"},
            ):
                inventory = await snapshot("details_consumer:app", root / "bundles")
                outcomes = {}
                for entry in inventory["checks"]:
                    assignment = {
                        **entry,
                        "id": str(uuid.uuid4()),
                        "kind": "python",
                        "generation": 1,
                        "source_key": entry["key"],
                        "source_id": inventory["source_id"],
                        "source_revision": inventory["source_revision"],
                        "expected_keys": [output["key"] for output in entry["outputs"]],
                    }
                    outcomes[entry["key"]] = await execute(
                        assignment, bundle_dir=root / "bundles"
                    )
        self.assertTrue(outcomes["normal"]["complete"], outcomes["normal"])
        result = outcomes["normal"]["results"][0]
        self.assertEqual(result["details"], "[WARN] Old backup\nStarted: original")
        self.assertEqual(result["source_at"], SOURCE_AT)
        self.assertFalse(outcomes["large"]["complete"])
        self.assertIn("64 KiB", outcomes["large"]["diagnostic"])
        self.assertGreater(len(outcomes["large"]["results"]), 0)
        for result in outcomes["large"]["results"]:
            self.assertEqual(result["details"], "x" * MAX_DETAILS_BYTES)
            self.assertEqual(result["source_at"], SOURCE_AT)


if __name__ == "__main__":
    unittest.main()
