# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0

from __future__ import annotations

import asyncio
import copy
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import AsyncMock, patch

from mondek_runner.local import include_result_evidence, run_selected

SOURCE = """from mondek_runner import App, Environment, check, crit, ok

@check(id="z-critical", expected_keys=("health",), timeout_seconds=3)
def critical():
    return crit("health", "A measured failure is still complete collection")

@check(id="a-group", expected_keys=("first", "second"), timeout_seconds=3)
def group():
    yield ok("first", "First independent result")
    yield ok("second", "Second independent result")

@check(id="m-partial", expected_keys=("first", "missing"), timeout_seconds=3)
def partial():
    yield ok("first", "Retain this partial measurement")

app = App(source_id="local-tests", environment=Environment("local"),
          checks=[critical, partial, group])
"""


def inventory(count: int) -> dict:
    return {
        "source_id": "test",
        "source_revision": "a" * 64,
        "checks": [
            {
                "key": f"group-{i:03}",
                "label": f"Group {i}",
                "outputs": [{"key": "health"}],
                "params": {},
            }
            for i in reversed(range(count))
        ],
    }


class LocalCommandTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        package = self.root / "local_consumer"
        package.mkdir()
        self.source = package / "__init__.py"
        self.source.write_text(SOURCE)

    def tearDown(self):
        self.temp.cleanup()

    def cli(self, *arguments):
        return subprocess.run(
            [
                sys.executable,
                "-m",
                "mondek_runner",
                *arguments,
                "--consumer",
                "local_consumer:app",
                "--state-dir",
                str(self.root / "must-not-exist"),
            ],
            env={
                **os.environ,
                "PYTHONPATH": str(self.root)
                + os.pathsep
                + os.environ.get("PYTHONPATH", ""),
                "MONDEK_CONTROLLER_URL": "http://127.0.0.1:1",
            },
            text=True,
            capture_output=True,
            timeout=20,
        )

    def test_whole_consumer_distinguishes_health_from_incomplete_collection(self):
        process = self.cli("run", "--all", "--concurrency", "2")
        self.assertEqual(process.returncode, 1, process.stderr)
        result = json.loads(process.stdout)
        self.assertEqual(
            [item["key"] for item in result["checks"]],
            ["a-group", "m-partial", "z-critical"],
        )
        self.assertEqual(result["summary"]["complete_checks"], 2)
        self.assertEqual(result["summary"]["incomplete_checks"], 1)
        self.assertEqual(
            result["summary"]["measured_health"],
            {"OK": 3, "WARN": 0, "CRIT": 1, "UNKNOWN": 0},
        )
        self.assertEqual(result["checks"][1]["collection"], "incomplete")
        self.assertEqual(result["checks"][1]["diagnostic"], "missing expected output")
        self.assertEqual(result["checks"][2]["collection"], "complete")
        self.assertNotIn("result_evidence", result)
        self.assertNotIn("results", result["checks"][0])
        self.assertFalse((self.root / "must-not-exist").exists())

    def test_batch_results_keep_partial_evidence_and_completion_exit_semantics(self):
        process = self.cli("run", "--all", "--results")
        self.assertEqual(process.returncode, 1, process.stderr)
        outcome = json.loads(process.stdout)
        self.assertEqual(outcome["result_evidence"]["included_results"], 4)
        self.assertEqual(outcome["result_evidence"]["omitted_results"], 0)
        partial = outcome["checks"][1]
        self.assertEqual(partial["collection"], "incomplete")
        self.assertEqual(
            partial["results"][0]["summary"], "Retain this partial measurement"
        )
        self.assertEqual(partial["received_results"], 1)
        self.assertEqual(partial["expected_results"], 2)
        self.assertEqual(partial["omitted_results"], 0)
        self.assertIsNotNone(partial["results"][0]["source_at"])
        selected = self.cli(
            "run", "--check", "a-group", "--check", "z-critical", "--results"
        )
        self.assertEqual(selected.returncode, 0, selected.stderr)
        measured = json.loads(selected.stdout)
        self.assertEqual(measured["checks"][1]["results"][0]["health"], "CRIT")
        self.assertFalse((self.root / "must-not-exist").exists())

    def test_selects_code_groups_and_preserves_single_check_outcome(self):
        selected = self.cli(
            "run", "--check", "z-critical", "--check", "a-group", "--concurrency", "1"
        )
        self.assertEqual(selected.returncode, 0, selected.stderr)
        result = json.loads(selected.stdout)
        self.assertTrue(result["complete"])
        self.assertEqual(result["checks"][0]["received_results"], 2)
        single = self.cli("run", "--check", "z-critical")
        self.assertEqual(single.returncode, 0, single.stderr)
        outcome = json.loads(single.stdout)
        self.assertNotIn("checks", outcome)
        self.assertTrue(outcome["complete"])
        self.assertEqual(outcome["results"][0]["health"], "CRIT")
        with_flag = self.cli("run", "--check", "z-critical", "--results")
        self.assertEqual(with_flag.returncode, 0, with_flag.stderr)
        self.assertEqual(set(json.loads(with_flag.stdout)), set(outcome))

    def test_options_and_whole_inventory_validate_before_execution(self):
        for arguments, message in (
            (("run", "--all", "--concurrency", "17"), "between 1 and 16"),
            (("run", "--all", "--check", "a-group"), "not allowed"),
            (("run", "--check", "first"), "unregistered check keys: first"),
            (("run", "--all", "--params", "{}"), "--params requires one"),
            (("validate", "--all"), "require run"),
            (("validate", "--results"), "require run"),
            (("--results",), "require run"),
        ):
            with self.subTest(arguments=arguments):
                process = self.cli(*arguments)
                self.assertNotEqual(process.returncode, 0)
                self.assertIn(message, process.stderr)
                self.assertEqual(process.stdout, "")
        self.source.write_text(SOURCE + '\nraise ValueError("broken inventory")\n')
        process = self.cli("run", "--check", "a-group")
        self.assertEqual(process.returncode, 1)
        self.assertIn("broken inventory", process.stderr)
        self.assertEqual(process.stdout, "")
        self.assertFalse((self.root / "must-not-exist").exists())

    def test_single_check_keeps_complete_parameter_override(self):
        self.source.write_text("""
from mondek_runner import App, Environment, Parameter, check, ok
@check(id="threshold", expected_keys=("health",), timeout_seconds=3,
       params={"limit": 1},
       parameters={"limit": Parameter("integer", "Limit", minimum=0)})
def threshold(params):
    return ok("health", "Executed with chosen parameters", value=params["limit"])
app = App(source_id="local-tests", environment=Environment("local"), checks=[threshold])
""")
        process = self.cli("run", "--check", "threshold", "--params", '{"limit": 7}')
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertEqual(json.loads(process.stdout)["results"][0]["value"], 7)

    def test_timeout_and_output_failure_keep_other_groups_running(self):
        self.source.write_text(
            SOURCE
            + """
import time
@check(id="timeout", expected_keys=("health",), timeout_seconds=0.3)
def timeout():
    time.sleep(30)
@check(id="output-limit", expected_keys=("health",), timeout_seconds=3)
def noisy():
    print("x" * 100000)
    return ok("health", "Too much captured output")
app.add(timeout)
app.add(noisy)
"""
        )
        process = self.cli("run", "--all", "--concurrency", "2")
        self.assertEqual(process.returncode, 1, process.stderr)
        result = json.loads(process.stdout)
        checks = {item["key"]: item for item in result["checks"]}
        self.assertIn("timed out", checks["timeout"]["diagnostic"])
        self.assertIn("64 KiB", checks["output-limit"]["diagnostic"])
        self.assertEqual(checks["a-group"]["collection"], "complete")
        self.assertEqual(checks["z-critical"]["collection"], "complete")


class LocalPoolTests(unittest.IsolatedAsyncioTestCase):
    async def test_evidence_uses_original_execution_values_in_stable_order(self):
        original = {
            "group-001": [
                {
                    "key": "z",
                    "health": "CRIT",
                    "summary": "One transient failure",
                    "value": 13.5,
                    "source_at": "2009-01-01T01:02:03.123456Z",
                },
                {
                    "key": "a",
                    "health": "UNKNOWN",
                    "summary": "Unknown source age",
                    "value": None,
                    "source_at": None,
                },
            ],
            "group-000": [
                {
                    "key": "health",
                    "health": "OK",
                    "summary": "Original measurement",
                    "value": 7,
                    "source_at": "2009-01-01T01:02:02.123456Z",
                }
            ],
        }

        async def execute(config, **kwargs):
            return {
                "complete": True,
                "results": original[config["source_key"]],
                "diagnostic": None,
            }

        with patch(
            "mondek_runner.local.execute",
            new_callable=AsyncMock,
            side_effect=execute,
        ) as worker:
            outcome = await run_selected(
                inventory(2),
                Path("unused"),
                keys=[],
                all_checks=True,
                concurrency=2,
                include_results=True,
            )
        self.assertEqual(worker.await_count, 2)
        self.assertEqual([row["key"] for row in outcome["checks"]], sorted(original))
        for row in outcome["checks"]:
            self.assertEqual(
                row["results"],
                sorted(original[row["key"]], key=lambda result: result["key"]),
            )
        self.assertTrue(outcome["complete"])
        self.assertEqual(
            outcome["summary"]["measured_health"],
            {"OK": 1, "WARN": 0, "CRIT": 1, "UNKNOWN": 1},
        )

    async def test_512_groups_use_fixed_pool_and_stable_summary(self):
        release = asyncio.Event()
        full = asyncio.Event()
        running = peak = 0
        seen = []

        async def execute(config, **kwargs):
            nonlocal running, peak
            running += 1
            peak = max(peak, running)
            seen.append(config["source_key"])
            if running == 2:
                full.set()
            try:
                await release.wait()
                await asyncio.sleep(0)
                return {"complete": True, "results": [], "diagnostic": None}
            finally:
                running -= 1

        with patch("mondek_runner.local.execute", execute):
            task = asyncio.create_task(
                run_selected(
                    inventory(512),
                    Path("unused"),
                    keys=[],
                    all_checks=True,
                    concurrency=2,
                )
            )
            await asyncio.wait_for(full.wait(), 1)
            self.assertEqual(len(seen), 2)
            release.set()
            result = await task
        self.assertEqual(peak, 2)
        self.assertEqual(len(set(seen)), 512)
        self.assertEqual([row["key"] for row in result["checks"]], sorted(seen))
        self.assertEqual(result["summary"]["checks"], 512)

    async def test_rejects_bounds_and_selection_without_starting_workers(self):
        with patch("mondek_runner.local.execute", new_callable=AsyncMock) as execute:
            for count, keys, concurrency in (
                (513, [], 1),
                (0, [], 1),
                (2, ["missing"], 1),
                (2, ["group-000", "group-000"], 1),
                (2, [], 0),
                (2, [], 17),
            ):
                with self.subTest(count=count, keys=keys, concurrency=concurrency):
                    with self.assertRaises(ValueError):
                        await run_selected(
                            inventory(count),
                            Path("unused"),
                            keys=keys,
                            all_checks=not keys,
                            concurrency=concurrency,
                        )
            execute.assert_not_called()

    async def test_worker_start_failure_is_incomplete_and_other_groups_continue(self):
        async def execute(config, **kwargs):
            if config["source_key"] == "group-000":
                raise OSError("cannot start worker")
            return {"complete": True, "results": [], "diagnostic": None}

        with patch("mondek_runner.local.execute", execute):
            result = await run_selected(
                inventory(2),
                Path("unused"),
                keys=[],
                all_checks=True,
                concurrency=1,
            )
        self.assertFalse(result["complete"])
        self.assertIn("cannot start worker", result["checks"][0]["diagnostic"])
        self.assertEqual(result["checks"][1]["collection"], "complete")


class ResultEvidenceBudgetTests(unittest.TestCase):
    def test_real_budget_reserves_all_512_check_summaries(self):
        result = {
            "key": "health",
            "health": "CRIT",
            "summary": "\0" * 2048,
            "value": None,
            "source_at": None,
        }
        original = {f"group-{index:03}": [result] for index in range(512)}
        outcome = {
            "complete": False,
            "checks": [
                {
                    "key": key,
                    "label": "a" * 200,
                    "collection": "incomplete",
                    "expected_results": 2,
                    "received_results": 1,
                    "measured_health": {"CRIT": 1},
                    "diagnostic": "\0" * 2048,
                }
                for key in original
            ],
        }
        include_result_evidence(outcome, original)
        self.assertLessEqual(len(json.dumps(outcome).encode()) + 1, 8 * 1024 * 1024)
        self.assertEqual(len(outcome["checks"]), 512)
        self.assertGreater(outcome["result_evidence"]["included_results"], 0)
        self.assertGreater(outcome["result_evidence"]["omitted_results"], 0)
        self.assertEqual(
            outcome["result_evidence"]["included_results"]
            + outcome["result_evidence"]["omitted_results"],
            512,
        )
        self.assertTrue(
            all(row["diagnostic"] == "\0" * 2048 for row in outcome["checks"])
        )

    def test_serialized_budget_keeps_whole_entries_and_explicit_omissions(self):
        # Cross 1/2/3-digit omission counters and exercise JSON escaping, not
        # merely Python string length. The summary remains unchanged by omission.
        original = {
            f"group-{index:03}": [
                {
                    "key": f"result-{value:02}",
                    "health": "CRIT",
                    "summary": '☃\n"\\' * 8,
                    "value": 1e30,
                    "source_at": "2009-01-01T01:02:03.123456Z",
                }
                for value in reversed(range(10))
            ]
            for index in range(11)
        }
        base = {
            "complete": True,
            "checks": [
                {"key": key, "received_results": 10, "collection": "complete"}
                for key in sorted(original)
            ],
            "summary": {"measured_health": {"CRIT": 110}},
        }
        empty = copy.deepcopy(base)
        with patch("mondek_runner.local.MAX_RESULTS_OUTPUT_BYTES", 8 * 1024 * 1024):
            include_result_evidence(empty, {key: [] for key in original})
        minimum = len(json.dumps(empty).encode()) + 256
        for limit in (minimum, minimum + 300, minimum + 3000, minimum + 30000):
            with self.subTest(limit=limit):
                outcome = copy.deepcopy(base)
                with patch("mondek_runner.local.MAX_RESULTS_OUTPUT_BYTES", limit):
                    include_result_evidence(outcome, original)
                self.assertLessEqual(
                    len(json.dumps(outcome, allow_nan=False).encode()) + 1, limit
                )
                included = sum(len(row["results"]) for row in outcome["checks"])
                self.assertEqual(
                    outcome["result_evidence"]["included_results"], included
                )
                self.assertEqual(
                    outcome["result_evidence"]["omitted_results"], 110 - included
                )
                self.assertEqual(outcome["summary"], base["summary"])
                self.assertTrue(outcome["complete"])
                for row in outcome["checks"]:
                    self.assertEqual(len(row["results"]) + row["omitted_results"], 10)
                    for result in row["results"]:
                        self.assertIn(result, original[row["key"]])
                again = copy.deepcopy(base)
                with patch("mondek_runner.local.MAX_RESULTS_OUTPUT_BYTES", limit):
                    include_result_evidence(
                        again, dict(reversed(list(original.items())))
                    )
                self.assertEqual(again, outcome)

    def test_oversized_result_does_not_hide_a_later_small_result(self):
        original = {
            "group": [
                {"key": "a", "summary": "x" * 4096},
                {"key": "b", "summary": "Keep me"},
            ]
        }
        outcome = {"checks": [{"key": "group"}]}
        with patch("mondek_runner.local.MAX_RESULTS_OUTPUT_BYTES", 400):
            include_result_evidence(outcome, original)
        self.assertEqual(outcome["checks"][0]["results"], [original["group"][1]])
        self.assertEqual(outcome["checks"][0]["omitted_results"], 1)
        self.assertEqual(outcome["result_evidence"]["omitted_results"], 1)


if __name__ == "__main__":
    unittest.main()
