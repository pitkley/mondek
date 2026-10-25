# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Service-free regressions for recurring maintenance acceptance proof boundaries."""

from __future__ import annotations

import copy
import unittest
from unittest.mock import Mock

from maintenance import (
    MaintenanceClient,
    assert_held_notification,
    remaining_attempts,
    series_intervals,
)


def windows() -> list[dict]:
    return [
        {
            "index": index,
            "starts_at": f"2010-01-{day:02}T10:00:00Z",
            "ends_at": f"2010-01-{day:02}T11:00:00Z",
        }
        for index, day in ((1, 3), (2, 10), (3, 17))
    ]


class MaintenanceHarnessTests(unittest.TestCase):
    def test_persisted_dates_compare_complete_utc_instants_not_just_local_clocks(self):
        original = windows()
        equivalent = copy.deepcopy(original)
        equivalent[0]["starts_at"] = "2010-01-03T10:00:00.000000+00:00"
        self.assertEqual(series_intervals(original), series_intervals(equivalent))
        shifted = copy.deepcopy(original)
        shifted[1]["starts_at"] = "2010-01-10T10:00:00.000001Z"
        self.assertNotEqual(series_intervals(original), series_intervals(shifted))
        self.assertNotEqual(series_intervals(original), series_intervals(original[:-1]))
        for changed in (
            {"starts_at": "2010-01-03T10:00:00"},
            {"starts_at": "2010-01-03T10:00:00+01:00"},
            {"ends_at": "2010-01-03T10:00:00Z"},
        ):
            with self.subTest(changed=changed), self.assertRaises(AssertionError):
                series_intervals([original[0] | changed])
        with self.assertRaisesRegex(AssertionError, "Repeated"):
            series_intervals([original[0], original[0]])

    def test_held_work_keeps_identity_payload_attempts_and_remaining_budget(self):
        before = {
            "id": "occurrence",
            "payload": {"kind": "firing"},
            "attempt_count": 2,
            "gates": ["maintenance"],
        }
        job = {"id": 17, "attempt": 3, "max_attempts": 101}
        snoozed = job | {"attempt": 5, "max_attempts": 103}
        assert_held_notification(before, before, job, snoozed)
        self.assertEqual(remaining_attempts(snoozed), 98)
        for changed in (
            {"id": "replacement-occurrence"},
            {"payload": {"kind": "firing", "changed": True}},
            {"attempt_count": 0},
            {"attempt_count": 3},
            {"gates": []},
        ):
            with self.subTest(changed=changed), self.assertRaises(AssertionError):
                assert_held_notification(before, before | changed, job, snoozed)
        for changed in ({"id": 18}, {"attempt": 0}, {"max_attempts": 104}):
            with self.subTest(changed=changed), self.assertRaises(AssertionError):
                assert_held_notification(before, before, job, snoozed | changed)

    def test_series_apply_submits_exact_review_without_recomputing_calendar_dates(self):
        proof = MaintenanceClient()
        proposal = {"reason": "original draft"}
        reviewed = {
            "proposal": {"reason": "canonical draft"},
            "review_token": "original-token",
            "occurrences": windows(),
        }
        saved = {"id": "series", "occurrences": windows()}
        proof.request = Mock(side_effect=[reviewed, saved])
        self.assertEqual(proof.save_series(proposal), (reviewed, saved))
        self.assertEqual(
            proof.request.call_args_list[1].args,
            (
                "/api/v1/maintenance-series/apply",
                {"proposal": reviewed["proposal"], "review_token": "original-token"},
            ),
        )

    def test_cancellation_uses_original_review_and_exact_reason(self):
        proof = MaintenanceClient()
        preview = {"review_token": "reviewed-upcoming-set"}
        saved = {"id": "series", "revision": 8}
        proof.request = Mock(side_effect=[preview, saved])
        self.assertEqual(
            proof.cancel_series_upcoming(
                {"id": "series", "revision": 7}, "Keep active work"
            ),
            (preview, saved),
        )
        self.assertEqual(
            proof.request.call_args_list[0].args,
            (
                "/api/v1/maintenance-series/series/cancel-preview",
                {"revision": 7, "reason": "Keep active work"},
            ),
        )
        self.assertEqual(
            proof.request.call_args_list[1].args,
            (
                "/api/v1/maintenance-series/series/cancel",
                {"review_token": "reviewed-upcoming-set", "reason": "Keep active work"},
            ),
        )


if __name__ == "__main__":
    unittest.main()
