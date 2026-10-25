# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Coverage acceptance assertions are service-free; the acceptance uses runners."""

from __future__ import annotations

import copy
import io
import tempfile
import unittest
from contextlib import redirect_stdout
from datetime import UTC, datetime
from pathlib import Path
from unittest.mock import Mock, patch

from coverage import (
    CoverageAcceptance,
    PUBLISHER_AUTHORITY,
    SOURCE,
    fresh_after_restart,
    fresh_desired,
    matches_scope,
    publisher_authority,
)

BOUNDARY = datetime(2009, 9, 17, 9, tzinfo=UTC)
AFTER = "2009-09-17T09:00:01.000000Z"


def scope() -> dict:
    return {
        "id": "scope",
        "source_id": SOURCE,
        "source_key": "root-disk-node-b",
        "result_key": "capacity",
        "environment": "production",
        "target": {"kind": "host", "key": "node:node-b", "label": "Node B"},
        "counts": {"declaring": 3, "selected": 0, "fresh": 0},
    }


def result() -> dict:
    return {
        "source_id": SOURCE,
        "source_key": "root-disk-node-b",
        "desired_generation": "desired",
        "active_generation": "desired",
        "current": {
            "knowledge": "fresh",
            "health": "CRIT",
            "observation_id": "report",
            "confirmed_observation_id": "report",
            "confirmed_generation": "desired",
            "session_id": "session",
            "source_at": AFTER,
            "evaluated_at": AFTER,
            "confirmed_evaluated_at": AFTER,
        },
    }


class CoverageHarnessTests(unittest.TestCase):
    def setUp(self):
        self.proof = object.__new__(CoverageAcceptance)
        self.proof.identities = {"node-b": "installation-b"}

    def test_exact_scope_does_not_merge_source_environment_or_check_identity(self):
        original = scope()
        self.assertTrue(
            matches_scope(original, "production", "node:node-b", "root-disk-node-b")
        )
        for field, value in (
            ("source_id", "different-source"),
            ("environment", "staging"),
            ("source_key", "local-collection"),
            ("result_key", "collection"),
            ("target", {"key": "node:node-a"}),
            ("target", original["target"] | {"kind": "volume"}),
        ):
            with self.subTest(field=field):
                self.assertFalse(
                    matches_scope(
                        original | {field: value},
                        "production",
                        "node:node-b",
                        "root-disk-node-b",
                    )
                )
        self.assertTrue(
            matches_scope(
                original | {"target": original["target"] | {"label": "Renamed"}},
                "production",
                "node:node-b",
                "root-disk-node-b",
            )
        )

    def test_fresh_critical_is_covered_but_old_authority_and_retained_health_are_not(
        self,
    ):
        original = result()
        self.assertTrue(fresh_desired(original, "CRIT", BOUNDARY))
        for field, value in (
            ("knowledge", "stale"),
            ("knowledge", "unavailable"),
            ("health", "OK"),
            ("observation_id", "unknown-report"),
            ("confirmed_generation", "prior"),
            ("source_at", "2009-09-17T08:59:59.000000Z"),
            ("evaluated_at", None),
            ("confirmed_evaluated_at", "2009-09-17T09:00:00.000000Z"),
        ):
            altered = copy.deepcopy(original)
            altered["current"][field] = value
            with self.subTest(field=field, value=value):
                self.assertFalse(fresh_desired(altered, "CRIT", BOUNDARY))
        self.assertFalse(
            fresh_desired(original | {"active_generation": "prior"}, "CRIT")
        )
        self.assertFalse(
            fresh_desired(original | {"desired_generation": "future"}, "CRIT")
        )

    def test_catalogue_authority_preservation_ignores_contact_only(self):
        before = dict.fromkeys(PUBLISHER_AUTHORITY, "value") | {
            "last_seen_at": "earlier",
            "received_at": "earlier",
        }
        after = before | {"last_seen_at": "later", "received_at": "later"}
        self.assertEqual(publisher_authority(before), publisher_authority(after))
        for field in PUBLISHER_AUTHORITY:
            with self.subTest(field=field):
                self.assertNotEqual(
                    publisher_authority(before),
                    publisher_authority(after | {field: "changed"}),
                )

    def test_restart_proof_rejects_retained_fresh_health_and_old_session_execution(
        self,
    ):
        previous = result()
        previous["current"]["health"] = "OK"
        fresh = copy.deepcopy(previous)
        fresh["current"].update(
            session_id="restarted-session",
            observation_id="new-report",
            confirmed_observation_id="new-report",
        )
        self.assertTrue(
            fresh_after_restart(fresh, previous, BOUNDARY, "restarted-session")
        )
        self.assertFalse(
            fresh_after_restart(previous, previous, BOUNDARY, "restarted-session")
        )
        for changes in (
            {"session_id": "session"},
            {"observation_id": "report", "confirmed_observation_id": "report"},
            {"source_at": "2009-09-17T08:59:59.000000Z"},
            {"evaluated_at": "2009-09-17T08:59:59.000000Z"},
            {"confirmed_evaluated_at": "2009-09-17T08:59:59.000000Z"},
            {"knowledge": "unavailable"},
        ):
            altered = copy.deepcopy(fresh)
            altered["current"].update(changes)
            with self.subTest(changes=changes):
                self.assertFalse(
                    fresh_after_restart(
                        altered, previous, BOUNDARY, "restarted-session"
                    )
                )
        self.assertFalse(fresh_after_restart(fresh, previous, BOUNDARY, "session"))
        self.assertFalse(fresh_after_restart(fresh, previous, BOUNDARY, ""))

    def test_counted_requires_exact_installation_wide_counts(self):
        row = scope()
        self.proof.scope = Mock(return_value=row)
        self.assertIs(
            self.proof.counted(
                "production", "node:node-b", declaring=3, selected=0, fresh=0
            ),
            row,
        )
        self.assertFalse(self.proof.counted("production", "node:node-b", declaring=1))
        self.assertFalse(self.proof.counted("production", "node:node-b", fresh=1))

    def test_duplicate_scope_or_publisher_cannot_be_hidden_by_first_match(self):
        self.proof.coverage_list = Mock(return_value={"items": [scope(), scope()]})
        with self.assertRaisesRegex(AssertionError, "duplicate coverage"):
            self.proof.scope("production", "node:node-b", "root-disk-node-b")
        self.proof.publishers = Mock(
            return_value=[
                {"runner_context": {"id": "node-b"}},
                {"runner_context": {"id": "node-b"}},
            ]
        )
        with self.assertRaisesRegex(AssertionError, "duplicate publishers"):
            self.proof.publisher("node-b")

    def test_independent_result_lookup_retains_runner_and_environment_filters(self):
        row = result()
        self.proof.streams = Mock(return_value={"items": [row]})
        self.assertIs(
            self.proof.result("node-b", "production", "root-disk-node-b"), row
        )
        self.proof.streams.assert_called_once_with(
            runner_id="installation-b", environment="production"
        )
        self.proof.streams.return_value = {"items": [row, copy.deepcopy(row)]}
        with self.assertRaisesRegex(AssertionError, "retain observer"):
            self.proof.result("node-b", "production", "root-disk-node-b")

    def test_each_run_failure_still_cleans_only_the_owned_compose_project(self):
        for stage in ("scenario", "write", "logs", "down"):
            with self.subTest(stage=stage), tempfile.TemporaryDirectory() as directory:
                proof = object.__new__(CoverageAcceptance)
                proof.project = "owned-coverage"
                proof.base = "http://unused.invalid"
                proof.output = Path(directory)
                proof.steps = []
                proof.snapshot = Mock(return_value={})
                proof.records = Mock(return_value=[])
                failure = RuntimeError("injected " + stage)
                proof.run_step = Mock(
                    side_effect=failure if stage == "scenario" else None
                )
                calls = []

                def compose(*args):
                    operation = "down" if "down" in args else "logs"
                    calls.append(args)
                    if operation == stage:
                        raise failure

                proof.compose = compose
                proof.log = Mock()
                original_write = Path.write_text

                def write(path, *args, **kwargs):
                    if stage == "write" and path.name == "results.json":
                        raise failure
                    return original_write(path, *args, **kwargs)

                with (
                    patch.object(Path, "write_text", write),
                    redirect_stdout(io.StringIO()),
                    self.assertRaisesRegex(RuntimeError, "injected " + stage),
                ):
                    proof.run()
                self.assertEqual(
                    calls,
                    [
                        ("logs", "--no-color", "--tail", "250"),
                        ("down", "--volumes", "--remove-orphans"),
                    ],
                )
                proof.log.close.assert_called_once_with()


if __name__ == "__main__":
    unittest.main()
