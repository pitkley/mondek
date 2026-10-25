# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Fault-inject the real harness finalizers without starting services."""

from __future__ import annotations

import contextlib
import io
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

import capacity
from acceptance import Acceptance
from parity import ParityAcceptance
from gateway import GatewayAcceptance
from soak import Soak


class CleanupTests(unittest.TestCase):
    def test_write_log_teardown_and_scenario_failures_still_finish_cleanup(self):
        for harness in ("acceptance", "parity", "capacity", "soak", "gateway"):
            for fault in ("write", "logs", "down", "scenario"):
                with (
                    self.subTest(harness=harness, fault=fault),
                    tempfile.TemporaryDirectory() as directory,
                ):
                    proof = object.__new__(
                        Acceptance
                        if harness == "acceptance"
                        else GatewayAcceptance
                        if harness == "gateway"
                        else Soak
                        if harness == "soak"
                        else ParityAcceptance
                    )
                    proof.project = "owned-cleanup-test"
                    proof.base = "http://unused.invalid"
                    proof.output = Path(directory)
                    proof.env = {}
                    proof.steps = []
                    proof.cycles = []
                    proof.duration = 0
                    proof.overview = Mock(return_value={})
                    proof.snapshot = Mock(return_value={})
                    proof.records = Mock(return_value=[])
                    failure = RuntimeError("injected " + fault)
                    proof.run_step = Mock(
                        side_effect=failure if fault == "scenario" else None
                    )
                    proof.clean_start = Mock(
                        side_effect=failure if fault == "scenario" else None
                    )
                    calls = []

                    def compose(*args):
                        action = "down" if "down" in args else "logs"
                        calls.append((action, args))
                        if action == fault:
                            raise failure

                    proof.compose = compose
                    proof.log = Mock()
                    proof.log.close.side_effect = lambda: calls.append(("close", ()))
                    original_write = Path.write_text

                    def write(path, *args, **kwargs):
                        if fault == "write" and path.name.endswith("results.json"):
                            raise failure
                        return original_write(path, *args, **kwargs)

                    with (
                        patch.object(Path, "write_text", write),
                        patch.object(capacity, "ParityAcceptance", return_value=proof),
                        contextlib.redirect_stdout(io.StringIO()),
                        self.assertRaisesRegex(RuntimeError, "injected " + fault),
                    ):
                        if harness == "capacity":
                            capacity.run(10)
                        else:
                            proof.run()

                    expected_prefix = (
                        ()
                        if harness in {"acceptance", "soak", "gateway"}
                        else ("--profile", "capacity")
                    )
                    self.assertEqual(
                        calls,
                        [
                            (
                                "logs",
                                expected_prefix
                                + (
                                    "logs",
                                    "--no-color",
                                    "--tail",
                                    "200" if harness == "gateway" else "250",
                                ),
                            ),
                            (
                                "down",
                                expected_prefix
                                + ("down", "--volumes", "--remove-orphans"),
                            ),
                            ("close", ()),
                        ],
                    )
                    proof.log.close.assert_called_once_with()


if __name__ == "__main__":
    unittest.main()
