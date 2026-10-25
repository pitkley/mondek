# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Deterministic acceptance-harness assertions; these do not replace real E2E."""

import copy
import unittest

from acceptance import reconcile_spool_samples


def report(sequence: int) -> dict:
    return {
        "id": f"report-{sequence}",
        "sequence": sequence,
        "evaluated_at": f"2009-09-15T08:00:{sequence:02d}+00:00",
        "results": [{"source_at": f"2009-09-15T08:00:{sequence:02d}+00:00"}],
    }


def sample(
    reports: list[dict], dropped: int = 0, phase: str = "starting_controller"
) -> dict:
    return {
        "phase": phase,
        "status": {"dropped": dropped, "loss_at": "2009-09-15T08:00:20+00:00"},
        "reports": reports,
    }


def evidence(reports: list[dict]) -> list[dict]:
    return [
        {
            "id": item["id"],
            "payload": copy.deepcopy(item),
            "received_at": "2009-09-15T08:01:00+00:00",
        }
        for item in reports
    ]


class ReconnectWitnessTests(unittest.TestCase):
    def test_initial_cohort_can_all_be_evicted_while_a_later_outage_cohort_is_preserved(
        self,
    ):
        initial = [report(sequence) for sequence in range(1, 9)]
        later = [report(sequence) for sequence in range(9, 17)]
        samples = [sample(initial), sample(later, 8), sample([], 8, "draining")]
        result = reconcile_spool_samples(samples, evidence(later))
        self.assertEqual(result["preserved_buffered_reports"], 8)
        self.assertEqual(
            set(result["sampled_ids_accounted_for_by_loss"]), {r["id"] for r in initial}
        )
        self.assertEqual(
            set(result["admitted_ids_sampled_before_controller_ready"]),
            {r["id"] for r in later},
        )

    def test_unexplained_disappearance_fails_even_when_some_reports_were_preserved(
        self,
    ):
        reports = [report(1), report(2)]
        with self.assertRaisesRegex(AssertionError, "without reported loss"):
            reconcile_spool_samples(
                [sample(reports), sample([], 0, "draining")], evidence(reports[1:])
            )

    def test_changed_payload_or_original_timestamp_fails(self):
        original = report(1)
        changed = evidence([original])
        changed[0]["payload"]["evaluated_at"] = "2009-09-15T08:00:59+00:00"
        with self.assertRaisesRegex(
            AssertionError, "changed original buffered evidence"
        ):
            reconcile_spool_samples(
                [sample([original]), sample([], 0, "draining")], changed
            )

    def test_current_fresh_reports_cannot_replace_proof_of_outage_buffer_preservation(
        self,
    ):
        initial, fresh = report(1), report(2)
        samples = [
            sample([initial]),
            sample([fresh], 1, "reconnecting"),
            sample([], 1, "draining"),
        ]
        with self.assertRaisesRegex(AssertionError, "before controller readiness"):
            reconcile_spool_samples(samples, evidence([fresh]))

    def test_final_unuploaded_sample_is_pending_and_not_invented_loss(self):
        original, pending = report(1), report(2)
        result = reconcile_spool_samples(
            [sample([original]), sample([pending], 0, "draining")], evidence([original])
        )
        self.assertEqual(result["still_spooled_ids"], [pending["id"]])
        self.assertEqual(result["sampled_ids_accounted_for_by_loss"], [])

    def test_an_earlier_loss_counter_cannot_explain_a_later_missing_report(self):
        original, later = report(1), report(30)
        samples = [
            sample([original]),
            sample([later], 1, "draining"),
            sample([], 1, "draining"),
        ]
        with self.assertRaisesRegex(AssertionError, "newer than the reported loss"):
            reconcile_spool_samples(samples, evidence([original]))


if __name__ == "__main__":
    unittest.main()
