# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Differential checks for rebinding validated full-consumer metadata."""

from __future__ import annotations

import copy
import unittest
from dataclasses import dataclass, make_dataclass
from unittest.mock import patch

from mondek_runner import (
    App,
    Binding,
    Environment,
    Output,
    Parameter,
    Result,
    Target,
    authoring,
    check,
)
from mondek_runner.bundle import metadata_at_revision
from mondek_runner.runtime import _validate_result_impacts


class BundleMetadataTests(unittest.TestCase):
    def test_output_subclass_scopes_cannot_vanish_from_declarations(self):
        for field in ("environment", "environment_label"):
            for value in (None, "production"):
                base = make_dataclass(
                    "ScopedOutput",
                    [(field, str | None, value)],
                    bases=(Output,),
                    frozen=True,
                )

                class InheritedOutput(base):
                    pass

                for origin in ("decorator", "binding"):
                    with self.subTest(field=field, value=value, origin=origin):
                        outputs = (InheritedOutput("health"),)

                        @check(
                            id="probe",
                            expected_keys=("health",) if origin == "binding" else (),
                            outputs=outputs if origin == "decorator" else (),
                        )
                        def probe():
                            raise AssertionError("metadata does not execute checks")

                        app = App(
                            source_id="scope-test",
                            environment=Environment("staging"),
                            checks=[
                                Binding(
                                    probe,
                                    outputs=outputs if origin == "binding" else (),
                                )
                            ],
                        )
                        with self.assertRaisesRegex(
                            ValueError, "one monitored environment per invocation"
                        ):
                            app.metadata("a" * 64)

    def test_result_dataclass_and_supervisor_reject_explicit_scope_overrides(self):
        @dataclass(frozen=True)
        class ScopedResult(Result):
            environment: str | None = None

        with self.assertRaisesRegex(
            ValueError, "one monitored environment per invocation"
        ):
            ScopedResult("health", "OK", "Scope is not implicit").to_dict()
        for field in ("environment", "environment_label"):
            for value in (None, "production"):
                with (
                    self.subTest(field=field, value=value),
                    self.assertRaisesRegex(
                        ValueError, "one monitored environment per invocation"
                    ),
                ):
                    _validate_result_impacts(
                        {"key": "health", "health": "OK", field: value}
                    )
        _validate_result_impacts(
            {"key": "health", "health": "OK", "consumer_extension": True}
        )

    def test_selected_metadata_matches_full_catalog_with_one_signature_validation(self):
        @check(id="probe", expected_keys=("health",))
        def probe():
            raise AssertionError("metadata does not execute checks")

        app = App(
            source_id="many-checks",
            environment=Environment("node"),
            checks=[Binding(probe, key=f"probe-{index}") for index in range(512)],
        )
        full = app.metadata("a" * 64)
        with patch.object(
            authoring, "get_type_hints", wraps=authoring.get_type_hints
        ) as hints:
            selected = app._metadata_for_check("a" * 64, "probe-400")
            self.assertEqual(selected, [full[400]])
            self.assertEqual(hints.call_count, 1)

    def test_rebinding_matches_complete_validation_for_all_registered_metadata(self):
        @check(
            id="capacity",
            name="Capacity check",
            expected_keys=("capacity", "readiness"),
            params={"warning": 80, "critical": 90, "path": "/samples"},
            parameters={
                "warning": Parameter("integer", "Warning at", "% used", 0, 100),
                "critical": Parameter("integer", "Critical at", "% used", 0, 100),
                "path": Parameter("string", "Path", choices=("/samples",)),
            },
            parameter_contract="capacity.v1",
            comparisons=(("warning", "lt", "critical"),),
            interval_seconds=3.5,
            timeout_seconds=0.5,
            freshness_seconds=15,
        )
        def capacity(params):
            raise AssertionError("metadata discovery must not execute a check")

        @check(id="readonly", expected_keys=("value",), params={"large": 10**200})
        def readonly(params):
            raise AssertionError("metadata discovery must not execute a check")

        app = App(
            source_id="revision-test",
            environment=Environment("node-a", "Production"),
            checks=[
                Binding(capacity),
                Binding(
                    capacity,
                    key="separate-binding",
                    name="Another capacity",
                    params={"warning": 50, "critical": 70, "path": "/samples"},
                    environment=Environment("node-b", "Production"),
                    outputs=(
                        Output(
                            "capacity",
                            "Used space",
                            Target("volume", "Volume", "filesystem"),
                        ),
                        Output(
                            "readiness",
                            "Ready",
                            Target("service", "Service", "service"),
                        ),
                    ),
                ),
                readonly,
            ],
        )
        first = app.metadata("a" * 64)
        original = copy.deepcopy(first)
        for revision in ("b" * 64, "0" * 64, "a" * 64):
            with self.subTest(revision=revision):
                # Independent full App validation retains the previous algorithm.
                expected = app.metadata(revision)
                actual = metadata_at_revision(first, revision)
                self.assertEqual(actual, expected)
                self.assertEqual(first, original)
                actual[0]["parameter_schema"]["fields"]["warning"]["label"] = "Changed"
                self.assertEqual(first, original)
        self.assertNotIn("adopt_assignment_id", first[0])
        self.assertNotIn("parameter_contract", first[2])

    def test_rebinding_preserves_a_full_512_check_inventory(self):
        @check(id="probe", expected_keys=("health",))
        def probe():
            raise AssertionError("metadata discovery must not execute a check")

        app = App(
            source_id="large-revision-test",
            environment=Environment("node"),
            checks=[Binding(probe, key=f"probe-{index}") for index in range(512)],
        )
        self.assertEqual(
            metadata_at_revision(app.metadata("a" * 64), "b" * 64),
            app.metadata("b" * 64),
        )


if __name__ == "__main__":
    unittest.main()
