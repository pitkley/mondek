# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0

import json
import tempfile
import unittest

from mondek_runner.connection_diagnostics import (
    ConnectionEvents,
    ControllerHTTPError,
    failure_details,
    http_details,
)
from mondek_runner.runtime import Runner
from mondek_runner.state import State


class ConnectionDiagnosticTests(unittest.TestCase):
    def test_failure_rate_limit_ignores_changing_ray_and_reports_recovery(self):
        now = [0.0]
        events = []
        stream = ConnectionEvents(clock=lambda: now[0], emit=events.append)
        for index in range(500):
            stream.failed(
                "inventory",
                ControllerHTTPError(
                    "https://secret.invalid", 403, {"cf_ray": f"{index:016x}-TXL"}
                ),
            )
        self.assertEqual(len(events), 1)
        now[0] = 299
        stream.failed("inventory", ControllerHTTPError("", 403, {}))
        self.assertEqual(len(events), 1)
        now[0] = 300
        stream.failed("inventory", ControllerHTTPError("", 403, {}))
        self.assertEqual(events[-1]["attempts"], 502)
        stream.succeeded("inventory")
        stream.succeeded("inventory")
        self.assertEqual(len(events), 3)
        self.assertEqual(events[-1]["failed_attempts"], 502)
        self.assertEqual(events[-1]["unavailable_seconds"], 300)
        self.assertTrue(events[-1]["recovered"])
        self.assertNotIn("secret.invalid", json.dumps(events))

    def test_changed_failures_are_throttled_and_channels_are_independent(self):
        now = [0.0]
        events = []
        stream = ConnectionEvents(clock=lambda: now[0], emit=events.append)
        stream.failed("control", ValueError("secret body"))
        now[0] = 29
        stream.failed("control", TimeoutError("secret token"))
        self.assertEqual(len(events), 1)
        now[0] = 30
        stream.failed("control", TimeoutError("secret token"))
        stream.failed("observations", ValueError("secret"))
        self.assertEqual(len(events), 3)
        stream.succeeded("control")
        stream.failed("control", ValueError("secret"))
        self.assertEqual(len(events), 5)
        self.assertNotIn("secret", json.dumps(events))

    def test_public_evidence_is_bounded_and_allowlisted(self):
        evidence = http_details(
            403,
            {"CF-Ray": "a3d1999bcdd8d963-TXL", "Authorization": "secret"},
            b"secret error code: 1010",
        )
        self.assertEqual(evidence["cf_error_code"], 1010)
        error = ControllerHTTPError(
            "https://user:secret@host", 403, {**evidence, "secret": "secret"}
        )
        self.assertIn("Browser Integrity", failure_details(error)["message"])
        self.assertNotIn("secret", json.dumps(failure_details(error)))
        self.assertEqual(
            http_details(403, {"CF-Ray": "secret"}, b"x" * 16384 + b"error code: 1010"),
            {"http_status": 403},
        )

    def test_recovery_clears_only_its_own_current_diagnostic(self):
        with tempfile.TemporaryDirectory() as root:
            state = State(root)
            try:
                runner = Runner(
                    state, "http://localhost", consumer="demo_checks.app:app"
                )
                runner.connection_events = ConnectionEvents(emit=lambda _: None)
                state.diagnostic("control failure")
                runner.connection_failed("control", ValueError(), "control failure")
                runner.connection_ready("observations")
                self.assertEqual(state.get("diagnostic"), "control failure")
                state.diagnostic("unrelated local preparation failure")
                runner.connection_ready("control")
                self.assertEqual(
                    state.get("diagnostic"), "unrelated local preparation failure"
                )
                state.diagnostic("upload failure")
                runner.connection_failed("observations", ValueError(), "upload failure")
                runner.connection_ready("observations")
                self.assertIsNone(state.get("diagnostic"))
            finally:
                state.close()
