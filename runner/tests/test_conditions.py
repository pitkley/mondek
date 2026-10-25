# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Explicit condition identities and bounded material-impact declarations."""

from __future__ import annotations

import copy
import importlib
import os
import sys
import tempfile
import unittest
import uuid
from dataclasses import FrozenInstanceError, replace
from hashlib import sha256
from pathlib import Path
from unittest.mock import patch

from mondek_runner import (
    App,
    Binding,
    Condition,
    Environment,
    Impact,
    Output,
    Result,
    ResultBuilder,
    Target,
    build_result,
    check,
    crit,
    ok,
    unknown,
    warn,
)
from mondek_runner.authoring import canonical
from mondek_runner.bundle import create_snapshot, load_snapshot, snapshot
from mondek_runner.runtime import _validate_result_impacts, execute
from mondek_runner.state import State

SOURCE_AT = "2009-01-02T03:04:05.123456Z"
REVISION = "a" * 64


@check(id="probe", name="Probe", expected_keys=("health",))
def probe():
    return ok("health", "Measured", source_at=SOURCE_AT)


class ConditionMetadataTests(unittest.TestCase):
    def test_absent_condition_preserves_legacy_metadata_and_definition_fingerprint(
        self,
    ):
        app = App(
            source_id="consumer",
            environment=Environment("production"),
            checks=[
                Binding(
                    probe, outputs=(Output("health", "Health", Target("db", "DB")),)
                )
            ],
        )
        legacy = {
            "key": "probe",
            "label": "Probe",
            "environment": "production",
            "environment_label": "production",
            "params_owner": "source",
            "parameter_schema": {"fields": {}, "comparisons": []},
            "params": {},
            "outputs": [
                {
                    "key": "health",
                    "label": "Health",
                    "target": {"key": "db", "label": "DB", "kind": "host"},
                }
            ],
            "interval_seconds": 30,
            "timeout_seconds": 5,
            "freshness_seconds": 90,
        }
        expected = {
            **legacy,
            "definition_revision": sha256(canonical([REVISION, legacy])).hexdigest(),
        }
        self.assertEqual(app.metadata(REVISION), [expected])

    def test_shared_condition_keeps_targets_and_assignment_environments_separate(self):
        shared = Condition("database-availability", "Database available")
        app = App(
            source_id="my-monitoring",
            environment=Environment("production"),
            checks=[
                Binding(
                    probe,
                    key="local",
                    outputs=(
                        Output(
                            "health",
                            target=Target("node-a", "Node A"),
                            condition=shared,
                        ),
                    ),
                ),
                Binding(
                    probe,
                    key="remote",
                    environment=Environment("staging"),
                    outputs=(
                        Output(
                            "health",
                            target=Target("database", "Database", "service"),
                            condition=shared,
                        ),
                    ),
                ),
            ],
        )
        metadata = app.metadata(REVISION)
        conditions = [item["outputs"][0]["condition"] for item in metadata]
        self.assertEqual(
            conditions,
            [
                {
                    "namespace": "my-monitoring",
                    "key": "database-availability",
                    "label": "Database available",
                }
            ]
            * 2,
        )
        self.assertEqual(
            {item["environment"] for item in metadata}, {"production", "staging"}
        )
        self.assertNotEqual(
            metadata[0]["outputs"][0]["target"], metadata[1]["outputs"][0]["target"]
        )
        self.assertIsNone(shared.namespace)
        self.assertEqual(
            shared.to_dict("another-consumer")["namespace"], "another-consumer"
        )
        self.assertEqual(
            Condition("db", "DB", "shared.operations").to_dict("consumer")["namespace"],
            "shared.operations",
        )
        with self.assertRaises(TypeError):
            Condition("db", "DB", environment="production")
        with self.assertRaises(FrozenInstanceError):
            shared.namespace = "changed"

    def test_condition_identity_and_label_bounds_are_strict(self):
        self.assertEqual(Condition("k" * 128, "é" * 100, "n" * 128).label, "é" * 100)
        for field, values in (
            ("key", ("", "space key", "é", "k" * 129, 1, None)),
            ("namespace", ("", "space name", "n" * 129, 1)),
            (
                "label",
                (
                    "",
                    " ",
                    "bad\nlabel",
                    "bad\x00label",
                    "bad\x7flabel",
                    "é" * 101,
                    "\ud800",
                    1,
                ),
            ),
        ):
            for value in values:
                with (
                    self.subTest(field=field, value=repr(value)),
                    self.assertRaises(ValueError),
                ):
                    Condition(
                        **(
                            {"key": "db", "label": "Database", "namespace": "shared"}
                            | {field: value}
                        )
                    )
        with self.assertRaisesRegex(ValueError, "Condition declaration"):
            Output("health", condition={"key": "db", "label": "Database"})

    def test_condition_changes_fence_both_complete_and_selected_accepted_snapshots(
        self,
    ):
        source = """from mondek_runner import (
    App, Condition, Environment, Output, check, ok,
)
@check(id="probe", outputs=(Output("health", condition=Condition("db", "Database")),))
def probe():
    return ok("health", "Measured")
app = App(source_id="condition-test", environment=Environment("production"),
          checks=[probe])
"""
        with tempfile.TemporaryDirectory() as temporary:
            name = "condition_" + uuid.uuid4().hex
            package = Path(temporary) / "site" / name
            package.mkdir(parents=True)
            (package / "__init__.py").write_text(source)
            directory = Path(temporary) / "bundles"
            with (
                patch.object(sys, "path", [str(package.parent), *sys.path]),
                patch.object(sys, "dont_write_bytecode", True),
            ):
                try:
                    first = create_snapshot(name + ":app", directory)
                    app = importlib.import_module(name).app
                    original = app.bindings["probe"]
                    for condition in (
                        None,
                        Condition("other", "Database"),
                        Condition("db", "New name"),
                        Condition("db", "Database", "shared"),
                    ):
                        app.bindings["probe"] = replace(
                            original, outputs=(Output("health", condition=condition),)
                        )
                        for selected in (None, "probe"):
                            with (
                                self.subTest(condition=condition, selected=selected),
                                self.assertRaisesRegex(ValueError, "revision"),
                            ):
                                load_snapshot(
                                    directory,
                                    first["source_revision"],
                                    check_key=selected,
                                )
                        changed = create_snapshot(name + ":app", directory)
                        self.assertNotEqual(
                            changed["source_revision"], first["source_revision"]
                        )
                        self.assertNotEqual(
                            changed["checks"][0]["definition_revision"],
                            first["checks"][0]["definition_revision"],
                        )
                finally:
                    sys.modules.pop(name, None)


class ImpactResultTests(unittest.TestCase):
    def test_old_positional_results_keep_exact_wire_shape(self):
        result = Result("health", "WARN", "Measured", 3, SOURCE_AT, "Details")
        self.assertEqual(
            result.to_dict(),
            {
                "key": "health",
                "health": "WARN",
                "summary": "Measured",
                "value": 3,
                "source_at": SOURCE_AT,
                "details": "Details",
            },
        )
        self.assertEqual(result.impacts, ())
        self.assertNotIn("impacts", ok("health", "Measured").to_dict())

    def test_helpers_and_appended_positional_field_emit_immutable_explicit_impacts(
        self,
    ):
        impact = Impact("exports-unavailable", "Export consumers cannot refresh")
        for helper in (warn, crit, unknown):
            result = helper(
                "health", "Measured", source_at=SOURCE_AT, impacts=(impact,)
            )
            self.assertEqual(
                result.to_dict()["impacts"],
                [{"key": impact.key, "label": impact.label}],
            )
            self.assertEqual(result.source_at, SOURCE_AT)
            self.assertIsInstance(result.to_dict()["impacts"], list)
            with self.assertRaises(FrozenInstanceError):
                result.impacts = ()
        positional = Result(
            "health", "CRIT", "Measured", None, SOURCE_AT, None, (impact,)
        )
        self.assertEqual(positional.impacts, (impact,))
        with self.assertRaises(FrozenInstanceError):
            impact.label = "Changed"
        with self.assertRaisesRegex(ValueError, "OK results"):
            Result("health", "OK", "Healthy", impacts=(impact,))

    def test_impact_identity_text_and_tuple_bounds_reject_malformed_claims(self):
        exact = Impact("k" * 128, "é" * 100)
        self.assertEqual(crit("health", "Failed", impacts=(exact,)).impacts, (exact,))
        for key in ("", "bad key", "é", "x" * 129, 1):
            with self.subTest(key=key), self.assertRaises(ValueError):
                Impact(key, "Impact")
        for label in ("", " ", "bad\ntext", "\x00", "\x7f", "é" * 101, "\ud800", 1):
            with self.subTest(label=repr(label)), self.assertRaises(ValueError):
                Impact("key", label)
        impact = Impact("key", "Impact")
        for malformed in (
            [impact],
            {"key": "Impact"},
            None,
            ("key",),
            ({"key": "key", "label": "Impact"},),
            (impact, impact),
            (impact, Impact("key", "Different")),
            tuple(Impact(f"key-{n}", "Impact") for n in range(17)),
        ):
            with self.subTest(malformed=repr(malformed)), self.assertRaises(ValueError):
                crit("health", "Failed", impacts=malformed)
        sixteen = tuple(Impact(f"key-{n}", "Impact") for n in range(16))
        self.assertEqual(len(crit("health", "Failed", impacts=sixteen).impacts), 16)

    def test_builder_only_emits_base_impacts_on_failure_and_merges_findings_explicitly(
        self,
    ):
        base, extra = (
            Impact("availability", "Unavailable"),
            Impact("freshness", "Delayed"),
        )
        builder = build_result(
            "health",
            ok_summary="Good",
            fail_summary="Bad",
            impacts=(base,),
            source_at=SOURCE_AT,
        )
        healthy = builder.ok(
            "availability freshness: prose alone has no meaning"
        ).finalize()
        self.assertEqual(healthy.impacts, ())
        self.assertNotIn("impacts", healthy.to_dict())
        first = builder.warn("Slow", impacts=(extra, base)).finalize()
        second = builder.crit("Failed", impacts=(extra,)).finalize()
        self.assertEqual(first.impacts, (base, extra))
        self.assertEqual(second.impacts, (base, extra))
        self.assertEqual(first.health, "WARN")
        self.assertEqual(second.health, "CRIT")
        self.assertEqual(first.source_at, second.source_at)
        self.assertEqual(healthy.impacts, ())
        no_inference = ResultBuilder(
            "health", ok_summary="Good", fail_summary="Bad"
        ).warn("availability freshness")
        self.assertEqual(no_inference.finalize().impacts, ())
        declared_unknown = ResultBuilder(
            "health", ok_summary="Good", fail_summary="Bad"
        ).unknown("Unable to determine", impacts=(base,))
        self.assertEqual(declared_unknown.finalize().impacts, (base,))

    def test_bad_finding_impacts_poison_the_builder_even_if_consumer_catches_error(
        self,
    ):
        cases = (
            ((), "OK", (Impact("bad", "Bad"),), "OK findings"),
            (
                (Impact("same", "Original"),),
                "WARN",
                (Impact("same", "Changed"),),
                "conflicting labels",
            ),
            (
                tuple(Impact(f"key-{n}", "Impact") for n in range(16)),
                "CRIT",
                (Impact("new", "New"),),
                "16 impacts",
            ),
            ((), "UNKNOWN", (Impact("same", "Impact"),) * 2, "distinct"),
            ((), "CRIT", ({"key": "bad", "label": "Bad"},), "Impact values"),
        )
        for initial, health, impacts, message in cases:
            with self.subTest(message=message):
                builder = build_result(
                    "health", ok_summary="Good", fail_summary="Bad", impacts=initial
                )
                builder.ok("Initial finding")
                with self.assertRaisesRegex(ValueError, message):
                    builder.add(health, "Must not disappear", impacts=impacts)
                with self.assertRaisesRegex(ValueError, message):
                    builder.finalize()
                with self.assertRaisesRegex(ValueError, message):
                    builder.ok("Still invalid")

    def test_serialized_impacts_are_validated_without_rewriting_evidence(self):
        values = [
            {"health": "OK"},
            {"health": "OK", "impacts": []},
            {
                "health": "UNKNOWN",
                "impacts": [{"key": "explicit", "label": "Possible impact"}],
            },
            crit(
                "health",
                "Failed",
                impacts=tuple(Impact(f"key-{n}", "Impact") for n in range(16)),
                source_at=SOURCE_AT,
            ).to_dict(),
        ]
        for value in values:
            original = copy.deepcopy(value)
            _validate_result_impacts(value)
            self.assertEqual(value, original)
        valid = {"key": "effect", "label": "Impact"}
        for impacts in (
            None,
            {},
            "effect",
            [None],
            [{"key": "effect"}],
            [valid | {"environment": "other"}],
            [valid, valid],
            [{"key": "bad key", "label": "Impact"}],
            [{"key": "effect", "label": "\ud800"}],
            [{"key": f"effect-{n}", "label": "Impact"} for n in range(17)],
        ):
            with self.subTest(impacts=repr(impacts)), self.assertRaises(ValueError):
                _validate_result_impacts({"health": "CRIT", "impacts": impacts})
        with self.assertRaisesRegex(ValueError, "OK results"):
            _validate_result_impacts({"health": "OK", "impacts": [valid]})

    def test_spooled_impacts_and_original_evidence_survive_restart_without_rewriting(
        self,
    ):
        assignment = {
            "id": "filesystem",
            "kind": "filesystem",
            "generation": 1,
            "params": {"path": "/", "warn_percent": 80, "crit_percent": 90},
            "interval_seconds": 3,
            "timeout_seconds": 2,
            "freshness_seconds": 12,
            "expected_keys": ["capacity"],
        }
        with tempfile.TemporaryDirectory() as temporary:
            state = State(temporary)
            try:
                state.adopt(assignment, 0)
                report = state.allocate(assignment, 3, SOURCE_AT)
                report.update(
                    results=[
                        crit(
                            "capacity",
                            "Full",
                            source_at=SOURCE_AT,
                            impacts=(Impact("writes-blocked", "Writes blocked"),),
                        ).to_dict()
                    ],
                    evaluated_at=SOURCE_AT,
                    complete=True,
                    diagnostic=None,
                )
                state.complete(report)
                original = state.batch()
            finally:
                state.close()
            restarted = State(temporary)
            try:
                self.assertEqual(restarted.batch(), original)
                self.assertEqual(restarted.batch(), original)
            finally:
                restarted.close()


class ImpactWorkerTests(unittest.IsolatedAsyncioTestCase):
    async def test_real_worker_rejects_forged_impacts_and_preserves_prior_evidence(
        self,
    ):
        source = """from mondek_runner import (
    App, Condition, Environment, Impact, Output, Result, check, crit,
)
class Forged(Result):
    def to_dict(self):
        return {"key": "bad", "health": "OK", "summary": "Healthy",
                "impacts": [{"key": "hidden", "label": "Cannot be healthy"}]}
@check(id="normal", timeout_seconds=3,
       outputs=(Output("health", condition=Condition("shared-db", "Database")),))
def normal():
    return crit("health", "Connection failed",
                source_at="2009-01-02T03:04:05.123456Z",
                impacts=(Impact("exports-unavailable", "Exports unavailable"),))
@check(id="invalid", expected_keys=("health", "bad"), timeout_seconds=3)
def invalid():
    yield crit("health", "Original failed measurement",
               source_at="2009-01-02T03:04:05.123456Z",
               impacts=(Impact("writes", "Writes blocked"),))
    yield Forged("bad", "OK", "Healthy")
app = App(source_id="condition-worker", environment=Environment("production"),
          checks=[normal, invalid])
"""
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            package = root / "site" / "condition_consumer"
            package.mkdir(parents=True)
            (package / "__init__.py").write_text(source)
            with patch.dict(
                os.environ,
                {"PYTHONPATH": f"{package.parent}:{os.environ.get('PYTHONPATH', '')}"},
            ):
                inventory = await snapshot("condition_consumer:app", root / "bundles")
                outcomes = {}
                for entry in inventory["checks"]:
                    assignment = {
                        **entry,
                        "id": str(uuid.uuid4()),
                        "kind": "python",
                        "generation": 1,
                        "source_key": entry["key"],
                        "source_id": inventory["source_id"],
                        "source_revision": inventory["source_revision"],
                        "expected_keys": [output["key"] for output in entry["outputs"]],
                    }
                    outcomes[entry["key"]] = await execute(
                        assignment, bundle_dir=root / "bundles"
                    )
        self.assertTrue(outcomes["normal"]["complete"], outcomes["normal"])
        measured = outcomes["normal"]["results"][0]
        self.assertEqual(
            measured["impacts"],
            [{"key": "exports-unavailable", "label": "Exports unavailable"}],
        )
        self.assertEqual(measured["source_at"], SOURCE_AT)
        self.assertFalse(outcomes["invalid"]["complete"])
        self.assertIn("OK results cannot", outcomes["invalid"]["diagnostic"])
        self.assertEqual(len(outcomes["invalid"]["results"]), 1)
        prior = outcomes["invalid"]["results"][0]
        self.assertEqual(prior["source_at"], SOURCE_AT)
        self.assertEqual(
            prior["impacts"], [{"key": "writes", "label": "Writes blocked"}]
        )


if __name__ == "__main__":
    unittest.main()
