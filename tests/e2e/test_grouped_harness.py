# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Guard the real grouped harness against false success without starting services."""

from __future__ import annotations

import contextlib
import copy
import io
import tempfile
import unittest
from datetime import UTC, datetime
from pathlib import Path
from unittest.mock import Mock, patch

from grouped import (
    CONDITION,
    VOLUME,
    GroupedAcceptance,
    after_boundary,
    assert_preserved_pending_delivery,
    fact_matches,
)

BOUNDARY = datetime(2009, 9, 16, 8, tzinfo=UTC)
AFTER = "2009-09-16T08:00:01.000000Z"
BEFORE = "2009-09-16T07:59:59.000000Z"


def measured_row() -> dict:
    return {
        "id": "volume-stream",
        "result_key": "capacity",
        "desired_generation": 2,
        "active_generation": 2,
        "current": {
            "knowledge": "fresh",
            "health": "WARN",
            "observation_id": "new-report",
            "confirmed_observation_id": "new-report",
            "confirmed_generation": 2,
            "evaluated_at": AFTER,
            "confirmed_evaluated_at": AFTER,
            "source_at": AFTER,
            "received_at": "2009-09-16T08:00:10.000000Z",
        },
    }


def occurrence() -> dict:
    return {
        "id": "shared-warning",
        "incident_id": None,
        "condition_incident_id": "group",
        "status": "delivered",
        "payload": {
            "occurrence_id": "shared-warning",
            "condition_incident_id": "group",
            "requested_fact": {"kind": "severity", "key": "WARN"},
            "source_at": BEFORE,
        },
    }


def pending_delivery() -> dict:
    return {
        "occurrence": occurrence()
        | {
            "status": "pending",
            "condition_fact_id": "warning-lifetime",
            "covered_warn_fact_id": None,
            "kind": "firing",
            "attention_revision": 1,
            "destination": "http://target:8080/webhook",
            "inserted_at": BEFORE,
            "attempt_count": 0,
            "gates": ["acknowledgement"],
            "gate_revision": 4,
        },
        "job": {
            "id": 17,
            "attempt": 0,
            "max_attempts": 3,
            "state": "scheduled",
            "args": {
                "occurrence_id": "shared-warning",
                "mondek_hold_revision": 4,
            },
        },
    }


class GroupedHarnessTests(unittest.TestCase):
    def setUp(self):
        self.proof = object.__new__(GroupedAcceptance)
        self.proof.group_ids = []

    def test_fresh_measurement_requires_execution_confirmation_and_source_after_change(
        self,
    ):
        row = measured_row()
        self.proof.stream = Mock(return_value=row)
        self.assertEqual(self.proof.measured(VOLUME, "WARN", BOUNDARY), row)
        for key in ("evaluated_at", "confirmed_evaluated_at", "source_at"):
            for value in (
                BEFORE,
                None,
                "malformed",
                "2009-09-16T08:00:01",
                BOUNDARY.isoformat(),
            ):
                with self.subTest(key=key, value=value):
                    row["current"][key] = value
                    self.assertFalse(self.proof.measured(VOLUME, "WARN", BOUNDARY))
            row["current"][key] = AFTER
        for key, value in (
            ("knowledge", "stale"),
            ("health", "OK"),
            ("confirmed_observation_id", "retained-report"),
            ("confirmed_generation", 1),
        ):
            with self.subTest(key=key):
                original = row["current"][key]
                row["current"][key] = value
                self.assertFalse(self.proof.measured(VOLUME, "WARN", BOUNDARY))
                row["current"][key] = original
        row["active_generation"] = 1
        self.assertFalse(self.proof.measured(VOLUME, "WARN", BOUNDARY))

    def test_original_source_age_and_matching_latest_result_are_required_for_stale_proof(
        self,
    ):
        row = measured_row()
        row["current"].update(knowledge="stale", confirmed_observation_id="old-report")
        self.proof.stream = Mock(return_value=row)
        latest_result = {
            "key": "capacity",
            "health": "OK",
            "source_at": "2009-09-16T07:59:30.000000Z",
        }
        self.proof.detail = Mock(
            return_value={
                "evidence": [
                    {
                        "id": "old-report",
                        "payload": {"results": [{"key": "capacity", "health": "WARN"}]},
                    },
                    {
                        "id": "new-report",
                        "payload": {
                            "results": [
                                {
                                    "key": "unrelated",
                                    "health": "UNKNOWN",
                                    "source_at": None,
                                },
                                latest_result,
                            ]
                        },
                    },
                ]
            }
        )
        self.assertEqual(self.proof.uncertain(VOLUME, "OK", "stale", BOUNDARY), row)
        self.assertFalse(self.proof.uncertain(VOLUME, "UNKNOWN", "stale", BOUNDARY))
        latest_result["source_at"] = AFTER
        with self.assertRaises(AssertionError):
            self.proof.uncertain(VOLUME, "OK", "stale", BOUNDARY)
        latest_result["source_at"] = None
        with self.assertRaisesRegex(AssertionError, "source time"):
            self.proof.uncertain(VOLUME, "OK", "stale", BOUNDARY)

    def test_aggregate_listing_and_detail_must_agree_without_using_snapshot(self):
        item = CONDITION | {
            "id": "group",
            "incident_kind": "condition",
            "environment": "production",
        }
        listing = {"total": 1, "items": [item]}
        detail = {"incident": {"id": "group", "health": "WARN"}, "counts": {"open": 2}}
        self.proof.incident_list = Mock(return_value=listing)
        self.proof.group = Mock(return_value=detail)
        self.proof.snapshot = Mock(
            side_effect=AssertionError("debug snapshot cannot replace operator listing")
        )
        self.assertEqual(self.proof.one_group(2, "WARN"), detail)
        self.assertEqual(self.proof.group_ids, ["group"])
        self.assertFalse(self.proof.one_group(1, "WARN"))
        listing["total"] = 0
        self.assertFalse(self.proof.one_group(2, "WARN"))
        listing["total"] = 2
        with self.assertRaisesRegex(AssertionError, "duplicate incidents"):
            self.proof.one_group(2, "WARN")
        listing["total"] = 1
        item["environment"] = "staging"
        with self.assertRaises(AssertionError):
            self.proof.one_group(2, "WARN")

    def test_receipt_filter_never_uses_another_group_or_standalone_incident(self):
        wanted = {"id": 1, "payload": occurrence()["payload"]}
        self.proof.records = Mock(
            return_value=[
                wanted,
                {
                    "id": 2,
                    "payload": wanted["payload"] | {"condition_incident_id": "other"},
                },
                {
                    "id": 3,
                    "payload": {
                        "incident_id": "group",
                        "occurrence_id": "shared-warning",
                    },
                },
                {
                    "id": 4,
                    "payload": wanted["payload"] | {"occurrence_id": "other-fact"},
                },
            ]
        )
        self.assertEqual(self.proof.receipt_rows("group", "shared-warning"), [wanted])
        self.assertEqual(
            [row["id"] for row in self.proof.receipt_rows("group")], [1, 4]
        )

    def test_delivery_requires_accepted_state_and_exact_original_occurrence_payload(
        self,
    ):
        original = occurrence()
        received = {"payload": copy.deepcopy(original["payload"])}
        self.proof.occurrence = Mock(return_value=original)
        self.proof.receipt_rows = Mock(return_value=[received])
        self.assertEqual(self.proof.delivered("group", "severity", "WARN"), original)
        original["status"] = "retrying"
        self.assertFalse(self.proof.delivered("group", "severity", "WARN"))
        original["status"] = "delivered"
        received["payload"]["source_at"] = AFTER
        with self.assertRaises(AssertionError):
            self.proof.delivered("group", "severity", "WARN")
        self.proof.receipt_rows.return_value = []
        self.assertFalse(self.proof.delivered("group", "severity", "WARN"))

    def test_continuous_fact_duplicate_cannot_hide_behind_one_delivered_row(self):
        original = occurrence()
        self.assertTrue(fact_matches(original, "severity", "WARN"))
        self.assertFalse(fact_matches(original, "impact", "WARN"))
        self.assertFalse(
            fact_matches({"payload": {"kind": "resolved"}}, "severity", "WARN")
        )
        self.proof.group = Mock(
            return_value={"occurrences": [original, original | {"id": "duplicate"}]}
        )
        with self.assertRaisesRegex(AssertionError, "one occurrence"):
            self.proof.occurrence("group", "severity", "WARN")

    def test_restart_witness_rejects_replaced_payload_fact_job_or_consumed_budget(self):
        original = pending_delivery()
        assert_preserved_pending_delivery(original, copy.deepcopy(original))
        for field, replacement in (
            ("id", "replacement-occurrence"),
            ("condition_incident_id", "replacement-group"),
            ("condition_fact_id", "replacement-lifetime"),
            ("covered_warn_fact_id", "unrelated-lifetime"),
            ("kind", "resolved"),
            ("attention_revision", 2),
            ("payload", original["occurrence"]["payload"] | {"source_at": AFTER}),
            ("destination", "http://localhost:8080/other"),
            ("inserted_at", AFTER),
            ("status", "delivered"),
            ("attempt_count", 1),
            ("gates", ["maintenance"]),
        ):
            current = copy.deepcopy(original)
            current["occurrence"][field] = replacement
            with self.subTest(field=field), self.assertRaises(AssertionError):
                assert_preserved_pending_delivery(original, current)

        for field, replacement in (
            ("id", 18),
            ("attempt", 1),
            ("max_attempts", 4),
            ("state", "executing"),
            ("args", {"occurrence_id": "replacement-occurrence"}),
        ):
            current = copy.deepcopy(original)
            current["job"][field] = replacement
            with self.subTest(field=field), self.assertRaises(AssertionError):
                assert_preserved_pending_delivery(original, current)

    def test_pending_proof_waits_for_the_current_ack_gate_on_one_original_job(self):
        witness = pending_delivery()
        self.proof.occurrence = Mock(return_value=witness["occurrence"])
        self.proof.snapshot = Mock(return_value={"jobs": [witness["job"]]})
        self.assertEqual(self.proof.pending_warning("group"), witness)
        witness["job"]["args"]["mondek_hold_revision"] = 3
        self.assertFalse(self.proof.pending_warning("group"))
        witness["job"]["args"]["mondek_hold_revision"] = 4
        witness["job"]["state"] = "available"
        self.assertFalse(self.proof.pending_warning("group"))
        witness["job"]["state"] = "scheduled"
        self.proof.snapshot.return_value["jobs"].append(witness["job"] | {"id": 18})
        with self.assertRaisesRegex(AssertionError, "exactly one original job"):
            self.proof.pending_warning("group")
        self.proof.snapshot.return_value["jobs"].pop()
        witness["occurrence"]["attempt_count"] = 1
        with self.assertRaisesRegex(AssertionError, "reached the receiver"):
            self.proof.pending_warning("group")

    def test_terminal_receipt_requires_delivered_state_and_exact_closing_authority(
        self,
    ):
        terminal = occurrence() | {"kind": "resolved"}
        terminal["payload"].update(
            kind="resolved",
            requested_fact=None,
            observation_id="final-recovery-report",
            closure_reason="source_removed",
            closure_reasons=["source_removed"],
        )
        detail = {
            "incident": {
                "closing_observation_id": "final-recovery-report",
                "closure_reason": "source_removed",
                "closure_reasons": ["source_removed"],
            },
            "occurrences": [terminal],
        }
        receipt = {"payload": copy.deepcopy(terminal["payload"])}
        self.proof.group = Mock(return_value=detail)
        self.proof.receipt_rows = Mock(return_value=[receipt])
        self.assertEqual(self.proof.resolved_delivery("group"), terminal)
        self.proof.receipt_rows.assert_called_with("group", "shared-warning")

        for field, value in (
            ("condition_incident_id", "other-group"),
            ("occurrence_id", "other-occurrence"),
            ("kind", "firing"),
            ("observation_id", "earlier-recovery-report"),
            ("closure_reason", "measured_recovery"),
            ("closure_reasons", []),
        ):
            prior = terminal["payload"][field]
            terminal["payload"][field] = value
            with self.subTest(field=field), self.assertRaises(AssertionError):
                self.proof.resolved_delivery("group")
            terminal["payload"][field] = prior

        terminal["status"] = "retrying"
        self.assertFalse(self.proof.resolved_delivery("group"))
        terminal["status"] = "delivered"
        receipt["payload"]["source_at"] = AFTER
        with self.assertRaisesRegex(AssertionError, "immutable occurrence"):
            self.proof.resolved_delivery("group")
        self.proof.receipt_rows.return_value = []
        self.assertFalse(self.proof.resolved_delivery("group"))
        detail["occurrences"].append(copy.deepcopy(terminal))
        with self.assertRaisesRegex(AssertionError, "one terminal notice"):
            self.proof.resolved_delivery("group")

    def test_offline_witness_requires_three_new_executions_after_transport_cut(self):
        sample = {"reports": [{"id": str(i), "started_at": BEFORE} for i in range(3)]}
        self.proof.node_journal = Mock(return_value=sample)
        self.assertFalse(self.proof.offline_cohort(BOUNDARY))
        for i in range(2):
            sample["reports"][i]["started_at"] = AFTER
        self.assertFalse(self.proof.offline_cohort(BOUNDARY))
        sample["reports"][2]["started_at"] = AFTER
        self.assertEqual(self.proof.offline_cohort(BOUNDARY), sample)
        self.assertFalse(after_boundary("2009-09-16T08:00:00.000000Z", BOUNDARY))

    def test_failure_at_each_cleanup_stage_still_removes_only_owned_project(self):
        for fault in ("write", "logs", "down", "scenario"):
            with self.subTest(fault=fault), tempfile.TemporaryDirectory() as directory:
                proof = object.__new__(GroupedAcceptance)
                proof.project = "owned-grouped-cleanup"
                proof.base = "http://unused.invalid"
                proof.output = Path(directory)
                proof.steps = []
                proof.group_ids = ["a", "b", "c", "d"]
                proof.snapshot = Mock(return_value={})
                proof.records = Mock(return_value=[])
                proof.incident_list = Mock(
                    return_value={
                        "total": 4,
                        "items": [{"id": id_} for id_ in proof.group_ids],
                    }
                )
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
                    if fault == "write" and path.name == "results.json":
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
                        ("logs", ("logs", "--no-color", "--tail", "250")),
                        ("down", ("down", "--volumes", "--remove-orphans")),
                        ("close", ()),
                    ],
                )
                proof.log.close.assert_called_once_with()


if __name__ == "__main__":
    unittest.main()
