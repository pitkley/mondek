# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Shared wire-text examples and partial evidence across authored failures."""

import asyncio
import json
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

from source_fixtures import assignment, worker_source

from mondek_runner import Result, build_result, check, ok
from mondek_runner._text import diagnostic_text
from mondek_runner.runtime import execute
from mondek_runner.worker import run


class TextContractTests(unittest.TestCase):
    def test_shared_summary_corpus(self):
        path = Path(__file__).resolve().parents[2] / "contracts/v1/result-text.json"
        for case in json.loads(path.read_text()):
            value = (
                bytes(case["utf8_bytes"]).decode("utf-8", errors="surrogatepass")
                if "utf8_bytes" in case
                else case["value"]
            )
            if isinstance(value, str):
                value *= case.get("repeat", 1)
            constructors = (
                lambda value=value: Result("capacity", "OK", value),
                lambda value=value: build_result(
                    "capacity", ok_summary=value, fail_summary="Failed"
                ),
                lambda value=value: build_result(
                    "capacity", ok_summary="OK", fail_summary=value
                ),
                lambda value=value: build_result(
                    "capacity", ok_summary="OK", fail_summary="Failed"
                ).ok(value),
            )
            for constructor in constructors:
                with self.subTest(case=case["name"]):
                    if case["valid"]:
                        constructor()
                    else:
                        with self.assertRaises(ValueError):
                            constructor()

    def test_diagnostics_escape_invalid_text_before_byte_bounding(self):
        self.assertEqual(diagnostic_text("bad\x00\ud800"), r"bad\x00\ud800")
        for text in ("é" * 2048, "\x00" * 2048, "\udfff" * 2048):
            result = diagnostic_text(text)
            self.assertLessEqual(len(result.encode("utf-8")), 2048)
            self.assertNotIn("\x00", result)

    def test_valid_sibling_survives_invalid_summary_and_exception(self):
        for mode in ("summary", "exception"):
            earlier = ok(
                "capacity",
                "Original measurement",
                source_at="2009-01-02T03:04:05.123456Z",
            )

            @check(expected_keys=("capacity",))
            def failing(*, params, earlier=earlier, mode=mode):
                yield earlier
                if mode == "summary":
                    yield ok("other", "bad\x00summary")
                else:
                    raise ValueError("bad\x00\ud800diagnostic")

            messages = []
            with (
                worker_source(failing),
                patch("mondek_runner.worker.emit", side_effect=messages.append),
            ):
                asyncio.run(run(assignment()))
            self.assertEqual(messages[0], {"result": earlier.to_dict()})
            self.assertFalse(messages[-1]["complete"])
            self.assertNotIn("\x00", messages[-1]["diagnostic"])
            messages[-1]["diagnostic"].encode("utf-8")
            if mode == "exception":
                self.assertIn(r"bad\x00\ud800diagnostic", messages[-1]["diagnostic"])


class WorkerTextBoundaryTests(unittest.IsolatedAsyncioTestCase):
    async def test_malformed_worker_text_preserves_prior_original_result(self):
        valid = ok(
            "capacity", "Original", source_at="2009-01-02T03:04:05.123456Z"
        ).to_dict()
        start_process = asyncio.create_subprocess_exec
        for field in ("summary", "details"):
            invalid = {**valid, "key": "other", field: "bad\x00text"}
            output = (
                "\n".join(
                    json.dumps(item)
                    for item in (
                        {"result": valid},
                        {"result": invalid},
                        {"complete": True},
                    )
                )
                + "\n"
            )

            async def raw_worker(*args, output=output, **kwargs):
                return await start_process(
                    sys.executable,
                    "-c",
                    "import sys; sys.stdin.read(); sys.stdout.write("
                    + repr(output)
                    + ")",
                    **kwargs,
                )

            with patch(
                "mondek_runner.runtime.asyncio.create_subprocess_exec",
                side_effect=raw_worker,
            ):
                result = await execute(assignment())
            self.assertEqual(result["results"], [valid])
            self.assertFalse(result["complete"])
            self.assertIn("malformed output", result["diagnostic"])
            self.assertNotIn("\x00", result["diagnostic"])
