# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Reject false upgrade/restart passes based on counts or retained measurements."""

from copy import deepcopy
from datetime import UTC, datetime
import unittest
from unittest.mock import Mock

from consumer_state_packaged import (
    Qualification,
    assert_preserved,
    isolated_environment,
)


class PackagedStateProofTests(unittest.TestCase):
    def test_operator_settings_cannot_override_disposable_notification_targets(self):
        environment = {
            "PATH": "/tools",
            "DEVENV_ROOT": "/checkout",
            "DOCKER_HOST": "unix:///engine",
            "MONDEK_SMTP_TO": "external@example.test",
            "MONDEK_NOTIFICATION_ADAPTER": "webhook",
            "MONDEK_CONTROLLER_URL": "https://external.example.test",
            "PGPASSWORD": "operator-secret",
            "SMTP_STATE_DIR": "/operator/records",
            "SMTP_CERT_FILE": "/operator/key",
            "FIXTURE_BIND": "external",
            "PYTHONPATH": "/other/source",
        }
        self.assertEqual(
            isolated_environment(environment),
            {
                "PATH": "/tools",
                "DEVENV_ROOT": "/checkout",
                "DOCKER_HOST": "unix:///engine",
            },
        )

    def test_cleanup_attempts_compose_and_servers_after_independent_failures(self):
        proof = object.__new__(Qualification)
        proof.private = "/owned/private.env"
        proof.stop_runners = Mock(side_effect=OSError("runner stop"))
        proof.compose = Mock(side_effect=[OSError("logs unavailable"), None])
        proof.gateway = Mock()
        proof.gateway.shutdown.side_effect = OSError("shutdown")
        proof.smtp = Mock()
        errors = proof.cleanup()
        self.assertEqual(
            [error["step"] for error in errors], ["runners", "logs", "gateway shutdown"]
        )
        proof.compose.assert_any_call("down", "--volumes", "--remove-orphans")
        proof.gateway.server_close.assert_called_once()
        proof.smtp.shutdown.assert_called_once()
        proof.smtp.server_close.assert_called_once()

    def test_unchanged_counts_do_not_hide_changed_evidence_or_configuration(self):
        before = {
            "observations": [
                {"id": "report", "payload": {"source_at": "original", "value": 10}}
            ],
            "configurations": [{"generation": 2, "params": {"threshold": 7}}],
            "configuration_git_objects": [{"id": "immutable", "payload": "original"}],
        }
        assert_preserved(before, deepcopy(before))
        for table in before:
            changed = deepcopy(before)
            changed[table][0] = {"id": "rewritten"}
            with self.assertRaisesRegex(AssertionError, table):
                assert_preserved(before, changed)
        with self.assertRaises(AssertionError):
            assert_preserved(before, {"observations": before["observations"]})

    def test_pre_restart_fresh_nonce_cannot_prove_post_restart_execution(self):
        proof = object.__new__(Qualification)
        proof.nonce = "nonce"
        rows = [
            {
                "current": {
                    "knowledge": "fresh",
                    "source_at": "2026-11-16T10:00:00+00:00",
                    "summary": "Verified shared nonce nonce",
                }
            }
            for _ in range(2)
        ]
        proof.read = lambda _: {"data": rows}
        self.assertTrue(proof.measurements(2, nonce=True))
        boundary = datetime(2026, 11, 16, 10, 1, tzinfo=UTC)
        self.assertFalse(proof.measurements(2, nonce=True, after=boundary))
        for row in rows:
            row["current"]["source_at"] = "2026-11-16T10:01:01+00:00"
        self.assertTrue(proof.measurements(2, nonce=True, after=boundary))
        rows[0]["current"]["summary"] = "Unrelated measurement"
        self.assertFalse(proof.measurements(2, nonce=True, after=boundary))


if __name__ == "__main__":
    unittest.main()
