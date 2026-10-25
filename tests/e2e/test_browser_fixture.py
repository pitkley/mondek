# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Scale browser fixtures require complete real measurements within their bound."""

import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from urllib.error import URLError

spec = importlib.util.spec_from_file_location(
    "browser_harness", Path(__file__).parents[1] / "browser/run.py"
)
assert spec is not None and spec.loader is not None
browser = importlib.util.module_from_spec(spec)
spec.loader.exec_module(browser)


def response(expected, fresh):
    return io.StringIO(
        json.dumps(
            {"counts": {"coverage": {"expected_count": expected, "fresh": fresh}}}
        )
    )


class BrowserFixtureTests(unittest.TestCase):
    def setUp(self):
        self.clock = 0
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.output = Path(self.directory.name)

    def sleep(self, seconds):
        self.clock += seconds

    def evidence(self):
        return json.loads((self.output / "scale-fixture-readiness.json").read_text())

    def test_waits_for_complete_declared_and_fresh_fixture(self):
        with (
            patch.object(browser.time, "monotonic", lambda: self.clock),
            patch.object(browser.time, "sleep", self.sleep),
            patch.object(
                browser.urllib.request,
                "urlopen",
                side_effect=[response(500, 499), response(500, 500)],
            ),
        ):
            browser.wait_for_scale_fixture("127.0.0.1:4000", 500, self.output)
        self.assertEqual(self.clock, 5)
        self.assertTrue(self.evidence()["passed"])
        self.assertEqual(len(self.evidence()["samples"]), 2)

    def test_wrong_declaration_count_fails_at_bound_and_retains_evidence(self):
        with (
            patch.object(browser.time, "monotonic", lambda: self.clock),
            patch.object(browser.time, "sleep", self.sleep),
            patch.object(
                browser.urllib.request,
                "urlopen",
                side_effect=lambda *args, **kwargs: response(501, 500),
            ),
        ):
            with self.assertRaisesRegex(TimeoutError, "500 fresh results in 240s"):
                browser.wait_for_scale_fixture("127.0.0.1:4000", 500, self.output)
        self.assertEqual(self.clock, 240)
        self.assertFalse(self.evidence()["passed"])
        self.assertEqual(self.evidence()["samples"][-1]["expected_count"], 501)

    def test_transient_transport_failure_does_not_admit_partial_fixture(self):
        with (
            patch.object(browser.time, "monotonic", lambda: self.clock),
            patch.object(browser.time, "sleep", self.sleep),
            patch.object(
                browser.urllib.request,
                "urlopen",
                side_effect=[URLError("starting"), response(511, 511)],
            ),
        ):
            browser.wait_for_scale_fixture("127.0.0.1:4000", 511, self.output)
        self.assertTrue(self.evidence()["passed"])
        self.assertEqual(self.evidence()["seconds"], 5)
        self.assertIn("starting", self.evidence()["last_error"])

    def test_late_fresh_response_cannot_extend_the_fixture_deadline(self):
        def late_response(*args, **kwargs):
            self.clock = 241
            return response(500, 500)

        with (
            patch.object(browser.time, "monotonic", lambda: self.clock),
            patch.object(browser.time, "sleep", self.sleep),
            patch.object(browser.urllib.request, "urlopen", side_effect=late_response),
        ):
            with self.assertRaises(TimeoutError):
                browser.wait_for_scale_fixture("127.0.0.1:4000", 500, self.output)
        self.assertFalse(self.evidence()["passed"])
