# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Discovery wire admission, author ergonomics and original partial evidence."""

import asyncio
import copy
import json
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

from source_fixtures import assignment, worker_source

from mondek_runner import (
    Discovery,
    DiscoveryCandidate,
    DiscoveryChoice,
    Parameter,
    build_result,
    check,
    crit,
    ok,
    unknown,
    warn,
)
from mondek_runner.discovery import validate_discovery
from mondek_runner.runtime import execute
from mondek_runner.worker import run


def discovery():
    return Discovery(
        "Review volumes",
        "Edit inventory in source.",
        (
            DiscoveryChoice(
                "monitor",
                "Monitor",
                parameters={
                    "limit": Parameter("integer", "Limit", minimum=1, maximum=100)
                },
                params={"limit": 90},
            ),
            DiscoveryChoice("ignore", "Ignore"),
        ),
        (DiscoveryCandidate("data", "Data", "Mounted at /data"),),
    )


class DiscoveryTests(unittest.TestCase):
    def test_shared_contract(self):
        cases = json.loads(
            (
                Path(__file__).resolve().parents[2] / "contracts/v1/discovery.json"
            ).read_text()
        )
        for case in cases:
            with self.subTest(case=case["name"]):
                if case["valid"]:
                    original = copy.deepcopy(case["value"])
                    validate_discovery(case["value"])
                    self.assertEqual(case["value"], original)
                else:
                    with self.assertRaises(ValueError):
                        validate_discovery(case["value"])

    def test_helpers_builder_and_legacy_serialization(self):
        review = discovery()
        for helper in (ok, warn, crit, unknown):
            result = helper("inventory", "Observed", discovery=review)
            self.assertEqual(result.to_dict()["discovery"], review.to_dict())
            self.assertNotIn("discovery", helper("inventory", "Observed").to_dict())
        result = (
            build_result(
                "inventory", ok_summary="OK", fail_summary="Failed", discovery=review
            )
            .warn("New volume")
            .finalize()
        )
        self.assertEqual(result.discovery, review)
        self.assertEqual(
            ok("x", "OK", source_at=None).to_dict(),
            {
                "key": "x",
                "health": "OK",
                "summary": "OK",
                "value": None,
                "source_at": None,
            },
        )

    def test_bounds_and_mutation_rechecked_at_serialization(self):
        review = discovery()
        for field, value in (
            ("instructions", "é" * 1025),
            ("title", "x\nY"),
            ("omitted", 1_000_001),
            (
                "candidates",
                [DiscoveryCandidate(str(i), "Volume").to_dict() for i in range(101)],
            ),
        ):
            wire = review.to_dict()
            wire[field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                validate_discovery(wire)
        wire = review.to_dict()
        wire["candidates"] = [
            {"key": str(i), "label": "Volume", "details": "é" * 512} for i in range(100)
        ]
        with self.assertRaisesRegex(ValueError, "32768"):
            validate_discovery(wire)
        wire = review.to_dict()
        wire["candidates"] = [
            {"key": str(i), "label": "Volume", "details": "é" * 250} for i in range(40)
        ]
        self.assertLess(len(json.dumps(wire, ensure_ascii=False).encode()), 32768)
        with self.assertRaisesRegex(ValueError, "32768"):
            validate_discovery(wire)
        result = ok("inventory", "Observed", discovery=review)
        review.choices[0].params["limit"] = 101
        with self.assertRaises(ValueError):
            result.to_dict()

    def test_worker_preserves_discovery_before_later_invalid_result(self):
        earlier = ok(
            "capacity",
            "Original",
            source_at="2009-01-02T03:04:05.123456Z",
            discovery=discovery(),
        )

        @check(expected_keys=("capacity",))
        def failing(*, params):
            yield earlier
            yield ok("other", "Invalid", discovery={})

        messages = []
        with (
            worker_source(failing),
            patch("mondek_runner.worker.emit", side_effect=messages.append),
        ):
            asyncio.run(run(assignment()))
        self.assertEqual(messages[0], {"result": earlier.to_dict()})
        self.assertFalse(messages[-1]["complete"])


class DiscoveryWorkerBoundaryTests(unittest.IsolatedAsyncioTestCase):
    async def test_hostile_worker_discovery_preserves_original_sibling(self):
        valid = ok(
            "capacity",
            "Original",
            source_at="2009-01-02T03:04:05.123456Z",
            discovery=discovery(),
        ).to_dict()
        start_process = asyncio.create_subprocess_exec
        for bad in (None, {}, {**discovery().to_dict(), "omitted": True}):
            invalid = {**valid, "key": "other", "discovery": bad}
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
