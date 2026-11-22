# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from mondek_runner import (
    App,
    Binding,
    ConditionRef,
    CorrelationHint,
    Environment,
    Output,
    TargetRef,
    check,
)
from mondek_runner.bundle import (
    canonical_check_metadata,
    create_snapshot,
    load_snapshot,
    manifest_digest,
    verify_snapshot,
)

REVISION = "a" * 64


@check(id="probe", expected_keys=("health",))
def probe():
    raise AssertionError("metadata must not execute a check")


class CorrelationHintTests(unittest.TestCase):
    def test_wire_contract(self):
        path = (
            Path(__file__).resolve().parents[2] / "contracts/v1/correlation-hints.json"
        )
        for vector in json.loads(path.read_text())["vectors"]:
            with self.subTest(name=vector["name"]):
                output = {"key": "health", **vector["output"]}
                checks = [{"definition_revision": REVISION, "outputs": [output]}]
                if vector["valid"]:
                    actual = canonical_check_metadata(checks, REVISION)[0]["outputs"][0]
                    expected = (
                        output if output.get("correlation_hints") else {"key": "health"}
                    )
                    self.assertEqual(actual, expected)
                else:
                    with self.assertRaises(ValueError):
                        canonical_check_metadata(checks, REVISION)

    def test_declaration_binds_identity_and_order(self):
        def metadata(output):
            return App(
                source_id="example",
                environment=Environment("local"),
                checks=[Binding(probe, outputs=(output,))],
            ).metadata(REVISION)[0]

        hints = (
            CorrelationHint("db", TargetRef("db-monitor", "database", "primary"), 90),
            CorrelationHint("wan", ConditionRef("network", "uplink"), 120),
        )
        before = metadata(Output("health"))
        self.assertEqual(before, metadata(Output("health", correlation_hints=())))
        after = metadata(Output("health", correlation_hints=hints))
        self.assertNotEqual(before["definition_revision"], after["definition_revision"])
        self.assertEqual(
            after["outputs"][0]["correlation_hints"], [hint.to_dict() for hint in hints]
        )
        with self.assertRaises(ValueError):
            Output("health", correlation_hints=(hints[0], hints[0]))

    def test_signed_snapshot_validates_hint_window_before_import(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            module = "consumer_correlation_hints_fixture"
            (root / f"{module}.py").write_text("""
from mondek_runner import (App, Binding, ConditionRef, CorrelationHint,
                           Environment, Output, check)

@check(id="probe", expected_keys=("health",))
def probe():
    raise AssertionError("must not execute")

app = App(source_id="example", environment=Environment("local"), checks=[
    Binding(probe, outputs=(Output("health", correlation_hints=(
        CorrelationHint("wan", ConditionRef("network", "uplink"), 120),)),))])
""")
            bundles = root / "bundles"
            with (
                patch.object(sys, "path", [str(root), *sys.path]),
                patch.object(sys, "dont_write_bytecode", True),
            ):
                try:
                    inventory = create_snapshot(f"{module}:app", bundles)
                    revision = inventory["source_revision"]
                    self.assertEqual(
                        load_snapshot(bundles, revision, check_key="probe")[1],
                        inventory,
                    )
                    file = bundles / revision / "manifest.json"
                    manifest = json.loads(file.read_bytes())
                    hint = manifest["inventory"]["checks"][0]["outputs"][0][
                        "correlation_hints"
                    ][0]
                    hint["window_seconds"] = 120.0
                    data = json.dumps(manifest).encode()
                    file.write_bytes(data)
                    file.with_suffix(".mac").write_bytes(manifest_digest(bundles, data))
                    with self.assertRaisesRegex(ValueError, "window_seconds"):
                        verify_snapshot(bundles, revision)
                finally:
                    sys.modules.pop(module, None)
