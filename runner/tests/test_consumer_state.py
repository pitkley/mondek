# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Shared state semantics and bounded, execution-only SDK access."""

import json
import time
import unittest
import urllib.error
from pathlib import Path
from unittest.mock import patch
from uuid import uuid4

from mondek_runner import (
    App,
    CheckContext,
    Environment,
    StateConflict,
    StateEntry,
    StateError,
    StateWriteIndeterminate,
    check,
    ok,
)
from mondek_runner.consumer_state import _StateClient, value_bytes


class ConsumerStateTests(unittest.TestCase):
    def client(self, **kwargs):
        return _StateClient(
            "http://controller",
            {"source_id": "source"},
            deadline=time.monotonic() + 10,
            **kwargs,
        )

    def receipt(self, value=None):
        return {
            "version": 1,
            "status": "stored",
            "entry": {
                "value": value,
                "version": str(uuid4()),
                "updated_at": "2026-11-16T00:00:00.000000Z",
                "expires_at": None,
            },
        }

    def test_shared_accounting_vectors(self):
        path = Path(__file__).resolve().parents[2] / "contracts/v1/consumer-state.json"
        for case in json.loads(path.read_text())["values"]:
            self.assertEqual(value_bytes(case["value"]), case["bytes"], case)

    def test_execution_context_injection_is_typed_and_local_access_unavailable(self):
        @check(id="peers", expected_keys=("peers",))
        def peers(arbitrary_name: CheckContext):
            return ok("peers", "Measured")

        app = App(source_id="peers", environment=Environment("test"), checks=[peers])
        app.metadata("a" * 64)
        arguments = app.arguments("peers", {}, instantiate=False)
        with self.assertRaises(StateError):
            arguments["arbitrary_name"].state.get("peers")
        fake = CheckContext(self.client())
        self.assertIs(app.arguments("peers", {}, context=fake)["arbitrary_name"], fake)

    def test_missing_null_cas_and_ttl_are_distinct_and_integral_floats_normalized(self):
        client = self.client()
        with patch(
            "mondek_runner.consumer_state.post_json",
            return_value={"version": 1, "status": "missing", "entry": None},
        ):
            self.assertIsNone(client.get("peers"))
        with patch(
            "mondek_runner.consumer_state.post_json", return_value=self.receipt()
        ) as post:
            self.assertIsInstance(client.put("peers", None), StateEntry)
            self.assertIsNone(client.put("peers", None).value)
            client.compare_and_set("peers", "missing", {"huge": 1e23}, ttl_seconds=1)
            self.assertEqual(post.call_args.args[1]["value"], {"huge": int(1e23)})
            self.assertEqual(post.call_args.args[1]["expected_version"], "missing")
            self.assertEqual(post.call_args.args[1]["ttl_seconds"], 1)
            client.put("peers", [])
            self.assertNotIn("ttl_seconds", post.call_args.args[1])
        with patch(
            "mondek_runner.consumer_state.post_json",
            return_value={"version": 1, "status": "conflict"},
        ):
            with self.assertRaises(StateConflict):
                client.compare_and_set("peers", "missing", [])

    def test_shared_call_budget_deadline_and_validation_happen_before_transport(self):
        client = self.client()
        local = client.for_check()
        with patch(
            "mondek_runner.consumer_state.post_json", return_value=self.receipt()
        ) as post:
            for _ in range(32):
                client.put("x", 1)
                local.put("x", 2)
            with self.assertRaises(StateError):
                local.put("x", 3)
            self.assertEqual(post.call_count, 64)
            self.assertEqual(post.call_args.args[1]["scope"], "check")
        client = _StateClient("http://controller", deadline=time.monotonic() - 1)
        with patch("mondek_runner.consumer_state.post_json") as post:
            with self.assertRaises(StateError):
                client.put("x", 1)
            post.assert_not_called()
        for value in [float("inf"), {"bad": "\0"}, {2: "bad"}, [1] * 65536]:
            with patch("mondek_runner.consumer_state.post_json") as post:
                with self.assertRaises(StateError):
                    self.client().put("x", value)
                post.assert_not_called()

    def test_allowlisted_controller_rejection_is_definite_and_safe(self):
        from mondek_runner.connection_diagnostics import (
            ControllerHTTPError,
            http_details,
        )

        details = http_details(
            409,
            {},
            b'{"error":{"code":"state_quota_exceeded","message":"private response"}}',
        )
        self.assertEqual(details["controller_code"], "state_quota_exceeded")
        failure = ControllerHTTPError("http://controller", 409, details)
        with patch("mondek_runner.consumer_state.post_json", side_effect=failure):
            with self.assertRaises(StateError) as error:
                self.client().put("key", 1)
            self.assertNotIsInstance(error.exception, StateWriteIndeterminate)
            self.assertNotIn("private", str(error.exception))

    def test_mutation_failures_are_indeterminate_without_retry(
        self,
    ):
        for failure in [
            TimeoutError(),
            OSError(),
            urllib.error.HTTPError("url", 408, "timeout", {}, None),
        ]:
            with patch(
                "mondek_runner.consumer_state.post_json", side_effect=failure
            ) as post:
                with self.assertRaises(StateWriteIndeterminate):
                    self.client().put("x", 1)
                self.assertEqual(post.call_count, 1)
                with self.assertRaises(StateError) as error:
                    self.client().get("x")
                self.assertNotIsInstance(error.exception, StateWriteIndeterminate)
        with patch(
            "mondek_runner.consumer_state.post_json",
            return_value={"version": 1, "status": "stored", "entry": {}},
        ):
            with self.assertRaises(StateWriteIndeterminate):
                self.client().put("x", 1)


if __name__ == "__main__":
    unittest.main()
