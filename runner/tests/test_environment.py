# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Only current settings affect the runner; empty values remain explicit."""

import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from mondek_runner.environment import get, require


class EnvironmentTests(unittest.TestCase):
    def test_old_names_are_ignored_and_current_empty_values_are_preserved(self):
        self.assertEqual(
            get("MONDEK_CONSUMER", "default", environ={"WATCHPOST_CONSUMER": "old"}),
            "default",
        )
        self.assertEqual(
            get(
                "MONDEK_CONSUMER",
                "default",
                environ={"WATCHPOST_CONSUMER": "old", "MONDEK_CONSUMER": ""},
            ),
            "",
        )
        self.assertEqual(
            get("MONDEK_CONSUMER", environ={"MONDEK_CONSUMER": "current"}), "current"
        )

    def test_required_values_do_not_resolve_an_old_alias(self):
        with patch.dict("os.environ", {"WATCHPOST_CONSUMER": "old"}, clear=True):
            with self.assertRaises(KeyError):
                require("MONDEK_CONSUMER")

    def test_start_without_consumer_rejects_before_creating_runner_state(self):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory, "uncreated-state")
            result = subprocess.run(
                [sys.executable, "-m", "mondek_runner", "--state-dir", str(state)],
                env={**os.environ, "MONDEK_CONSUMER": ""},
                capture_output=True,
                text=True,
                timeout=5,
            )
            self.assertEqual(result.returncode, 2)
            self.assertIn("--consumer module:app is required", result.stderr)
            self.assertFalse(state.exists())
