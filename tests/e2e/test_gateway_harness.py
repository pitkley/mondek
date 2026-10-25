# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Prevent pre-restart diagnostics from satisfying reconnect assertions."""

import json
import unittest
from unittest.mock import Mock

from gateway import GatewayAcceptance


class GatewayHarnessTests(unittest.TestCase):
    def test_current_session_excludes_prior_failure_and_ignores_plain_log_lines(self):
        proof = object.__new__(GatewayAcceptance)
        previous = [
            {"event": "runner_started", "session_id": "old"},
            {"event": "controller_unavailable", "channel": "control"},
        ]
        current = [
            {"event": "runner_started", "session_id": "new"},
            {"event": "controller_unavailable", "channel": "inventory"},
        ]
        proof.compose = Mock(
            return_value="plain log line\n"
            + "\n".join(json.dumps(event) for event in previous + current)
        )
        self.assertEqual(proof.events("observer-b"), previous + current)
        self.assertEqual(proof.events("observer-b", current_session=True), current)
        proof.compose.return_value = json.dumps(previous[1])
        self.assertEqual(proof.events("observer-b", current_session=True), [])
