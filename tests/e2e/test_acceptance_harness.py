# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Deterministic acceptance-harness assertions; these do not replace real E2E."""

import copy
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

import acceptance
from acceptance import Acceptance, reconcile_spool_samples
from gateway import GatewayAcceptance


class PublishedPortsTests(unittest.TestCase):
    def test_dynamic_ports_are_reserved_by_docker_and_resolved_after_startup(self):
        with (
            tempfile.TemporaryDirectory() as directory,
            patch.object(acceptance, "ROOT", Path(directory)),
            patch.object(acceptance, "free_ports") as reserve,
        ):
            proof = Acceptance(dynamic_ports=True)
            self.addCleanup(proof.log.close)
            self.assertEqual(
                [
                    proof.env[key]
                    for key in ("MONDEK_PORT", "MONDEK_FIXTURE_PORT", "PGPORT")
                ],
                ["0", "0", "0"],
            )
            reserve.assert_not_called()
            proof.compose = Mock(side_effect=["127.0.0.1:41001\n", "127.0.0.1:41002\n"])
            proof.resolve_host_ports()
            self.assertEqual(proof.base, "http://127.0.0.1:41001")
            self.assertEqual(proof.fixture, "http://127.0.0.1:41002")
            self.assertEqual(
                [call.args for call in proof.compose.call_args_list],
                [("port", "controller", "4000"), ("port", "target", "8080")],
            )

    def test_invalid_or_missing_mapping_cannot_be_used_as_an_endpoint(self):
        for address in (
            "",
            "0.0.0.0:41001",
            "127.0.0.1:0",
            "127.0.0.1:65536",
            "127.0.0.1:abc",
        ):
            with self.subTest(address=address):
                proof = object.__new__(Acceptance)
                proof.dynamic_ports = True
                proof.base, proof.fixture = "original-controller", "original-fixture"
                proof.compose = Mock(side_effect=["127.0.0.1:41001", address])
                with self.assertRaises(ValueError):
                    proof.resolve_host_ports()
                self.assertEqual(proof.base, "original-controller")
                self.assertEqual(proof.fixture, "original-fixture")

    def test_controller_start_restart_and_recreation_refresh_published_endpoints(self):
        for operation in (
            ("start", "controller"),
            ("restart", "controller"),
            ("up", "--force-recreate", "controller"),
        ):
            with (
                self.subTest(operation=operation),
                tempfile.TemporaryDirectory() as directory,
                patch.object(acceptance, "ROOT", Path(directory)),
                patch.object(
                    acceptance,
                    "run_compose",
                    side_effect=["", "127.0.0.1:42001", "127.0.0.1:42002"],
                ) as compose,
            ):
                proof = Acceptance(dynamic_ports=True)
                try:
                    proof.base = "http://127.0.0.1:41001"
                    proof.fixture = "http://127.0.0.1:41002"
                    proof.compose(*operation)
                    self.assertEqual(proof.base, "http://127.0.0.1:42001")
                    self.assertEqual(proof.fixture, "http://127.0.0.1:42002")
                    self.assertEqual(compose.call_count, 3)
                finally:
                    proof.log.close()

    def test_gateway_uses_dynamic_ports_and_other_harnesses_keep_reserved_ports(self):
        with (
            tempfile.TemporaryDirectory() as directory,
            patch.object(acceptance, "ROOT", Path(directory)),
            patch.object(
                acceptance, "free_ports", return_value=[41001, 41002, 41003]
            ) as reserve,
        ):
            ordinary = Acceptance()
            gateway = GatewayAcceptance()
            self.addCleanup(ordinary.log.close)
            self.addCleanup(gateway.log.close)
            reserve.assert_called_once_with(3)
            self.assertEqual(ordinary.base, "http://127.0.0.1:41001")
            self.assertEqual(gateway.env["MONDEK_PORT"], "0")
            ordinary.compose = Mock()
            ordinary.resolve_host_ports()
            ordinary.compose.assert_not_called()


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
