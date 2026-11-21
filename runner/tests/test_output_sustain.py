# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from mondek_runner import App, Binding, Environment, Output, Target, check
from mondek_runner.bundle import (
    canonical_check_metadata,
    create_snapshot,
    load_snapshot,
)

REVISION = "a" * 64


@check(id="link", expected_keys=("health",))
def probe():
    raise AssertionError("inventory must not execute a check")


class OutputSustainMetadataTests(unittest.TestCase):
    def test_shared_policy_corpus(self):
        corpus = (
            Path(__file__).resolve().parents[2] / "contracts/v1/output-sustain.json"
        )
        for example in json.loads(corpus.read_text())["policy"]:
            with self.subTest(example=example["name"]):
                raw = example["output"]
                checks = [
                    {
                        "definition_revision": REVISION,
                        "outputs": [{"key": "link", **raw}],
                    }
                ]
                if example["valid"]:
                    output = Output("link", **raw)
                    self.assertEqual(
                        output.sustain_seconds, raw.get("sustain_seconds", 0)
                    )
                    self.assertEqual(
                        canonical_check_metadata(checks, REVISION)[0]["outputs"],
                        [{"key": "link", **example["canonical"]}],
                    )
                else:
                    with self.assertRaisesRegex(ValueError, "sustain_seconds"):
                        Output("link", **raw)
                    with self.assertRaisesRegex(ValueError, "sustain_seconds"):
                        canonical_check_metadata(checks, REVISION)

    def test_zero_keeps_existing_wire_identity(self):
        def metadata(output):
            return App(
                source_id="network",
                environment=Environment("local"),
                checks=[Binding(probe, outputs=(output,))],
            ).metadata(REVISION)

        target = Target("uplink", "Uplink")
        default = metadata(Output("health", target=target))
        zero = metadata(Output("health", target=target, sustain_seconds=0))
        positive = metadata(Output("health", target=target, sustain_seconds=300))

        self.assertEqual(default, zero)
        self.assertNotEqual(
            default[0]["definition_revision"], positive[0]["definition_revision"]
        )
        self.assertEqual(positive[0]["outputs"][0]["sustain_seconds"], 300)

    def test_positive_custom_metadata_executes_against_the_accepted_snapshot(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            module = "custom_sustain_metadata_fixture"
            (root / f"{module}.py").write_text(
                """
from mondek_runner import App, Binding, Environment, Output, Target, check, warn

@check(id="link", expected_keys=("health",))
def probe():
    return warn("health", "Link slow")

class Consumer(App):
    def metadata(self, revision):
        checks = super().metadata(revision)
        checks[0]["outputs"][0]["sustain_seconds"] = 5
        return checks

app = Consumer(source_id="network", environment=Environment("local"), checks=[
    Binding(probe, outputs=(Output("health", target=Target("uplink", "Uplink")),)),
])
"""
            )

            entrypoint = f"{module}:app"
            bundles = root / "bundles"
            with (
                patch.object(sys, "path", [str(root), *sys.path]),
                patch.object(sys, "dont_write_bytecode", True),
            ):
                try:
                    accepted = create_snapshot(entrypoint, bundles)
                    _app, inventory = load_snapshot(
                        bundles, accepted["source_revision"], check_key="link"
                    )
                finally:
                    sys.modules.pop(module, None)

            self.assertEqual(inventory, accepted)
            self.assertEqual(accepted["checks"][0]["outputs"][0]["sustain_seconds"], 5)
