# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Starter-harness evidence and cleanup regressions; no services are started."""

from __future__ import annotations

import contextlib
import copy
import io
import os
import sys
import tempfile
import unittest
from datetime import UTC, datetime
from pathlib import Path
from unittest.mock import Mock, patch

from consumers import FILE_SCRIPT, PROMETHEUS_TARGET, ConsumerAcceptance


class ConsumerHarnessTests(unittest.TestCase):
    def test_batch_fault_proof_keeps_every_original_sample_after_the_boundary(self):
        boundary = datetime(2009, 9, 16, 8, tzinfo=UTC)
        early = {"source_at": "2009-09-16T07:59:59Z"}
        late = {"source_at": "2009-09-16T08:00:01Z"}
        batch = {"checks": [{"results": [early]}, {"results": [late]}]}
        self.assertFalse(ConsumerAcceptance.batch_collected_after(batch, boundary))
        for value in (None, "2009-09-16T08:00:00Z"):
            early["source_at"] = value
            self.assertFalse(ConsumerAcceptance.batch_collected_after(batch, boundary))
        early["source_at"] = "2009-09-16T08:00:00.001Z"
        self.assertTrue(ConsumerAcceptance.batch_collected_after(batch, boundary))
        self.assertFalse(
            ConsumerAcceptance.batch_collected_after({"checks": []}, boundary)
        )

    def test_failed_construction_requires_fresh_new_session_with_the_same_accepted_contract(
        self,
    ):
        proof = object.__new__(ConsumerAcceptance)
        boundary = datetime(2009, 9, 16, 8, tzinfo=UTC)
        previous = {
            "id": "same-stream",
            "assignment_id": "same-check",
            "runner_id": "same-runner",
            "source_revision": "same-source",
            "current": {"session_id": "old-session", "generation": 7},
        }
        row = copy.deepcopy(previous)
        row["current"].update(
            session_id="new-session", confirmed_session_id="new-session"
        )
        proof.cohort = Mock(return_value={PROMETHEUS_TARGET: row})
        runner = {
            "id": "same-runner",
            "session_id": "new-session",
            "status": {
                "diagnostic": "consumer discovery failed; previous coverage retained"
            },
        }
        proof.request = Mock(return_value={"items": [runner]})
        proof.overview = Mock(return_value={"coverage": {"expected_count": 4}})
        self.assertEqual(
            proof.restarted_prometheus(previous, boundary, True)["runner"], runner
        )
        proof.cohort.assert_called_once_with(after_time=boundary)
        for field in ("session_id", "confirmed_session_id"):
            with self.subTest(field=field):
                row["current"][field] = "old-session"
                self.assertFalse(proof.restarted_prometheus(previous, boundary, True))
                row["current"][field] = "new-session"
        runner["status"]["diagnostic"] = None
        self.assertFalse(proof.restarted_prometheus(previous, boundary, True))
        self.assertTrue(proof.restarted_prometheus(previous, boundary, False))
        row["source_revision"] = "unreviewed-source"
        with self.assertRaisesRegex(AssertionError, "source_revision"):
            proof.restarted_prometheus(previous, boundary, False)

    def test_peer_progress_requires_execution_after_mutation_not_late_arrival(self):
        proof = object.__new__(ConsumerAcceptance)
        boundary = datetime(2009, 9, 16, 8, tzinfo=UTC)
        row = {
            "target": {"key": "peer"},
            "current": {
                "observation_id": "new",
                "confirmed_observation_id": "new",
                "knowledge": "fresh",
                "health": "OK",
                "received_at": "2009-09-16T08:00:10.000000Z",
                "evaluated_at": "2009-09-16T07:59:59.000000Z",
                "confirmed_evaluated_at": "2009-09-16T07:59:59.000000Z",
            },
        }
        proof.streams = Mock(return_value={"items": [row]})
        self.assertFalse(proof.cohort(("peer",), {"peer": "old"}, boundary))
        row["current"]["evaluated_at"] = "2009-09-16T08:00:01.000000Z"
        self.assertFalse(proof.cohort(("peer",), {"peer": "old"}, boundary))
        row["current"]["confirmed_evaluated_at"] = "2009-09-16T08:00:01.000000Z"
        self.assertEqual(
            proof.cohort(("peer",), {"peer": "old"}, boundary), {"peer": row}
        )
        for value in (
            None,
            "malformed",
            "2009-09-16T08:00:01",
            "2009-09-16T08:00:00.000000Z",
        ):
            with self.subTest(value=value):
                row["current"]["evaluated_at"] = value
                self.assertFalse(proof.cohort(("peer",), {"peer": "old"}, boundary))

    def test_owned_file_recreation_restores_fixture_user_and_group(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "ordinary-export.csv"
            script = FILE_SCRIPT.replace(
                "Path('/node/ordinary-export.csv')", f"Path({str(path)!r})"
            )
            with (
                patch.object(sys, "argv", ["fixture-mutation", "missing"]),
                contextlib.redirect_stdout(io.StringIO()),
            ):
                exec(compile(script, "<owned-file-mutation>", "exec"), {})
            self.assertFalse(path.exists())
            with (
                patch.object(sys, "argv", ["fixture-mutation", "healthy"]),
                patch.object(os, "chown") as owner,
                contextlib.redirect_stdout(io.StringIO()),
            ):
                exec(compile(script, "<owned-file-mutation>", "exec"), {})
            owner.assert_called_once_with(path, 65532, 65532)
            self.assertEqual(path.read_text(), "id,value\n1,42\n")
            self.assertEqual(path.stat().st_mode & 0o777, 0o644)

    def test_unknown_requires_latest_matching_raw_result(self):
        proof = object.__new__(ConsumerAcceptance)
        row = {
            "id": "file-stream",
            "result_key": "file",
            "current": {
                "health": "OK",
                "observation_id": "new",
                "confirmed_observation_id": "old",
            },
        }
        old = {
            "id": "old",
            "payload": {
                "results": [
                    {"key": "file", "health": "OK", "source_at": "earlier"},
                ]
            },
        }
        new = {
            "id": "new",
            "payload": {
                "results": [
                    {"key": "other", "health": "OK", "source_at": "recent"},
                    {"key": "file", "health": "UNKNOWN", "source_at": None},
                ]
            },
        }
        proof.detail = Mock(return_value={"evidence": [old, new]})
        self.assertEqual(proof.unknown_evidence(row), new)
        # An UNKNOWN sibling or older observation cannot satisfy this assertion.
        for field, value in (("health", "OK"), ("source_at", "invented-time")):
            with self.subTest(field=field):
                result = new["payload"]["results"][1]
                prior = result[field]
                result[field] = value
                with self.assertRaises(AssertionError):
                    proof.unknown_evidence(row)
                result[field] = prior

    def test_new_unavailable_execution_is_distinct_from_retained_health(self):
        proof = object.__new__(ConsumerAcceptance)
        previous = {"current": {"observation_id": "old"}}
        row = {
            "current": {
                "observation_id": "new",
                "health": "OK",
                "knowledge": "unavailable",
                "reported_health": "UNKNOWN",
                "reported_source_at": None,
                "execution_summary": "Cannot read PID file",
            }
        }
        proof.stream = Mock(return_value=row)
        self.assertEqual(proof.unknown("process", previous, "PID file"), row)
        for field, value in (
            ("observation_id", "old"),
            ("knowledge", "fresh"),
            ("reported_health", "OK"),
            ("reported_source_at", "new-time"),
        ):
            with self.subTest(field=field):
                prior = row["current"][field]
                row["current"][field] = value
                self.assertFalse(proof.unknown("process", previous, "PID file"))
                row["current"][field] = prior

    def test_artifact_log_teardown_and_scenario_failures_still_clean_owned_project(
        self,
    ):
        for fault in ("write", "logs", "down", "scenario"):
            with self.subTest(fault=fault), tempfile.TemporaryDirectory() as directory:
                proof = object.__new__(ConsumerAcceptance)
                proof.project = "owned-starter-cleanup-test"
                proof.base = "http://unused.invalid"
                proof.output = Path(directory)
                proof.steps = []
                proof.active_scenario = None
                proof.overview = Mock(return_value={})
                proof.snapshot = Mock(return_value={})
                proof.streams = Mock(return_value={})
                proof.records = Mock(return_value=[])
                failure = RuntimeError("injected " + fault)
                proof.run_step = Mock(
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
                    if fault == "write" and path.name == "consumer-results.json":
                        raise failure
                    return original_write(path, *args, **kwargs)

                with (
                    patch.object(Path, "write_text", write),
                    contextlib.redirect_stdout(io.StringIO()),
                    self.assertRaisesRegex(RuntimeError, "injected " + fault),
                ):
                    proof.run()

                self.assertEqual(
                    calls,
                    [
                        (
                            "logs",
                            (
                                "--profile",
                                "starters",
                                "logs",
                                "--no-color",
                                "--tail",
                                "250",
                            ),
                        ),
                        (
                            "down",
                            (
                                "--profile",
                                "starters",
                                "down",
                                "--volumes",
                                "--remove-orphans",
                            ),
                        ),
                        ("close", ()),
                    ],
                )
                proof.log.close.assert_called_once_with()


if __name__ == "__main__":
    unittest.main()
