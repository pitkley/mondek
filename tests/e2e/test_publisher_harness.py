# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Service-free checks for the real publisher lifecycle proof boundaries."""

from __future__ import annotations

import copy
import io
import tempfile
import unittest
from contextlib import redirect_stdout
from datetime import UTC, datetime
from pathlib import Path
from unittest.mock import Mock

from publishers import (
    PublisherAcceptance,
    assert_administrative_closure,
    assert_new_membership,
    failed_restore_refresh,
)

BOUNDARY = datetime(2009, 9, 17, 10, tzinfo=UTC)


def result() -> dict:
    return {
        "runner_id": "runner-a",
        "source_id": "source",
        "id": "result-new",
        "assignment_id": "assignment-new",
        "desired_generation": 2,
        "active_generation": 2,
        "current": {
            "observation_id": "report-new",
            "confirmed_observation_id": "report-new",
            "confirmed_generation": 2,
            "knowledge": "fresh",
            "health": "CRIT",
            "source_at": "2009-09-17T10:00:01Z",
            "evaluated_at": "2009-09-17T10:00:02Z",
            "confirmed_evaluated_at": "2009-09-17T10:00:02Z",
        },
    }


class PublisherHarnessTests(unittest.TestCase):
    def test_restore_failure_requires_an_actual_attempt_for_this_floor_after_restore(
        self,
    ):
        refresh = {
            "after_revision": 3,
            "lifecycle_revision": 5,
            "state": "failed",
            "attempted_at": "2009-09-17T10:00:01Z",
        }
        self.assertTrue(
            failed_restore_refresh({"inventory_refresh": refresh}, 3, 5, BOUNDARY)
        )
        for changed in (
            {"after_revision": 2},
            {"lifecycle_revision": 3},
            {"state": "pending"},
            {"attempted_at": None},
            {"attempted_at": "2009-09-17T10:00:00Z"},
        ):
            with self.subTest(changed=changed):
                self.assertFalse(
                    failed_restore_refresh(
                        {"inventory_refresh": refresh | changed}, 3, 5, BOUNDARY
                    )
                )
        self.assertFalse(
            failed_restore_refresh(
                {"diagnostic": "old discovery error"}, 3, 5, BOUNDARY
            )
        )

    def test_new_membership_requires_all_new_owned_identities_and_post_restore_age(
        self,
    ):
        after = result()
        before = copy.deepcopy(after)
        before.update(id="result-old", assignment_id="assignment-old")
        before["current"]["observation_id"] = "report-old"
        assert_new_membership(before, after, BOUNDARY)
        for changes in (
            {"id": before["id"]},
            {"assignment_id": before["assignment_id"]},
            {"runner_id": "successor"},
            {"source_id": "other"},
            {"active_generation": 1},
        ):
            with self.subTest(changes=changes), self.assertRaises(AssertionError):
                assert_new_membership(before, after | changes, BOUNDARY)
        for changes in (
            {"observation_id": "report-old", "confirmed_observation_id": "report-old"},
            {"knowledge": "stale"},
            {"confirmed_generation": 1},
            {"source_at": "2009-09-17T09:59:59Z"},
            {"evaluated_at": "2009-09-17T10:00:00Z"},
        ):
            altered = copy.deepcopy(after)
            altered["current"].update(changes)
            with self.subTest(changes=changes), self.assertRaises(AssertionError):
                assert_new_membership(before, altered, BOUNDARY)

    def test_administrative_closure_cannot_be_called_measured_recovery(self):
        closed = {
            "status": "closed",
            "closure_reason": "publisher_retired",
            "closing_observation_id": None,
        }
        assert_administrative_closure(closed)
        assert_administrative_closure(
            closed | {"closure_reason": "publisher_replaced"}, "publisher_replaced"
        )
        with self.assertRaises(AssertionError):
            assert_administrative_closure(closed, "publisher_replaced")
        for change in (
            {"status": "open"},
            {"closure_reason": "measured_recovery"},
            {"closing_observation_id": "successor-evidence"},
        ):
            with self.subTest(change=change), self.assertRaises(AssertionError):
                assert_administrative_closure(closed | change)

    def test_lifecycle_apply_uses_original_review_without_silently_refreshing_it(self):
        proof = object.__new__(PublisherAcceptance)
        proof.request = Mock(return_value={"receipt": "saved"})
        reviewed = {
            "proposal": {
                "publisher_id": 3,
                "action": "retire",
                "reason": "Exact reviewed reason",
            },
            "review_token": "original",
        }
        self.assertEqual(proof.apply(reviewed), {"receipt": "saved"})
        proof.request.assert_called_once_with(
            "/api/v1/publishers/apply", reviewed, code=200
        )

    def test_independent_result_lookup_rejects_duplicate_and_other_source_membership(
        self,
    ):
        proof = object.__new__(PublisherAcceptance)
        proof.identities = {"service-a": "installation-a"}
        valid = result() | {
            "source_id": "elasticsearch-monitoring",
            "environment": "production",
        }
        proof.streams = Mock(return_value={"items": [valid, result()]})
        self.assertIs(proof.result("service-a"), valid)
        proof.streams.assert_called_once_with(runner_id="installation-a")
        proof.streams.return_value = {"items": [valid, copy.deepcopy(valid)]}
        with self.assertRaisesRegex(AssertionError, "merged or duplicated"):
            proof.result("service-a")

    def test_failure_always_collects_logs_then_destroys_only_owned_project(self):
        with tempfile.TemporaryDirectory() as directory:
            proof = object.__new__(PublisherAcceptance)
            proof.project = "owned-publishers"
            proof.base = "http://unused.invalid"
            proof.output = Path(directory)
            proof.steps = []
            proof.run_step = Mock(side_effect=RuntimeError("scenario failed"))
            proof.snapshot = Mock(return_value={})
            proof.records = Mock(return_value=[])
            proof.compose = Mock()
            proof.log = Mock()
            with (
                redirect_stdout(io.StringIO()),
                self.assertRaisesRegex(RuntimeError, "scenario failed"),
            ):
                proof.run()
            self.assertEqual(
                [call.args for call in proof.compose.call_args_list],
                [
                    ("logs", "--no-color", "--tail", "250"),
                    ("down", "--volumes", "--remove-orphans"),
                ],
            )
            proof.log.close.assert_called_once_with()


if __name__ == "__main__":
    unittest.main()
