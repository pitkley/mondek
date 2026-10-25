# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Browsing groups preserve resource identity and excluded declarations."""

import copy
import json
import unittest
from dataclasses import replace
from pathlib import Path

from mondek_runner import (
    App,
    Binding,
    CheckGroup,
    Environment,
    Output,
    Placement,
    RunnerContext,
    Target,
    check,
    ok,
)
from mondek_runner.authoring import validate_check_group
from mondek_runner.bundle import validate_output_scopes


@check(id="health", expected_keys=("a", "b"))
def health():
    return [ok("a", "Measured"), ok("b", "Measured")]


@check(id="local", expected_keys=("health",), placement=Placement(requires=("disk",)))
def local():
    raise AssertionError("discovery never executes checks")


class CheckGroupTests(unittest.TestCase):
    def test_optional_default_override_and_identity_preservation(self):
        outputs = (
            Output("a", target=Target("one", "One")),
            Output("b", target=Target("two", "Two")),
        )
        binding = Binding(health, outputs=outputs)

        def metadata(binding):
            return App(
                source_id="consumer",
                environment=Environment("production"),
                checks=[binding],
            ).metadata("a" * 64)[0]

        before = metadata(binding)
        self.assertTrue(all("group" not in output for output in before["outputs"]))
        grouped = metadata(
            replace(
                binding,
                group=CheckGroup("host", "Host"),
                outputs=(
                    outputs[0],
                    replace(outputs[1], group=CheckGroup("misc", "Miscellaneous")),
                ),
            )
        )
        self.assertEqual(
            [output["group"]["key"] for output in grouped["outputs"]], ["host", "misc"]
        )
        for original, modified in zip(
            before["outputs"], grouped["outputs"], strict=True
        ):
            self.assertEqual(
                original,
                {key: value for key, value in modified.items() if key != "group"},
            )
        self.assertEqual(before["key"], grouped["key"])
        self.assertNotEqual(
            before["definition_revision"], grouped["definition_revision"]
        )

    def test_excluded_unresolved_and_resolved_coverage_keep_groups(self):
        for environment in (None, Environment("remote")):
            app = App(
                source_id="consumer",
                runner=RunnerContext("shared"),
                checks=[
                    Binding(
                        local,
                        environment=environment,
                        group=CheckGroup("storage", "Storage"),
                    )
                ],
            )
            self.assertEqual(app.metadata("a" * 64), [])
            candidate = app.coverage_metadata([])["candidates"][0]
            self.assertFalse(candidate["selected"])
            self.assertEqual(candidate["scope_resolved"], environment is not None)
            self.assertEqual(
                candidate["outputs"][0]["group"], {"key": "storage", "label": "Storage"}
            )

    def test_wire_contract_and_hostile_metadata(self):
        cases = json.loads(
            (Path(__file__).parents[2] / "contracts/v1/check-groups.json").read_text()
        )
        for case in cases:
            with self.subTest(case["name"]):
                output = {"key": "a", "target": None, **case["output"]}
                if case["valid"]:
                    validate_output_scopes([{"outputs": [output]}])
                else:
                    with self.assertRaises((ValueError, UnicodeError)):
                        validate_output_scopes([{"outputs": [output]}])
                    with self.assertRaises((ValueError, UnicodeError)):
                        validate_check_group(output["group"])

    def test_custom_metadata_cannot_hide_invalid_group_in_coverage(self):
        app = App(
            source_id="consumer", environment=Environment("production"), checks=[health]
        )
        metadata = copy.deepcopy(app.metadata("a" * 64))
        metadata[0]["outputs"][0]["group"] = None
        with self.assertRaisesRegex(ValueError, "group"):
            app.coverage_metadata(metadata)

    def test_decorator_output_overrides_default_in_selected_coverage(self):
        @check(id="decorated", outputs=(Output("a", group=CheckGroup("own", "Own")),))
        def decorated():
            return ok("a", "Measured")

        app = App(
            source_id="consumer",
            environment=Environment("production"),
            checks=[Binding(decorated, group=CheckGroup("default", "Default"))],
        )
        metadata = app.metadata("a" * 64)
        candidate = app.coverage_metadata(metadata)["candidates"][0]
        self.assertTrue(candidate["selected"])
        self.assertEqual(candidate["outputs"], metadata[0]["outputs"])
        self.assertEqual(candidate["outputs"][0]["group"]["key"], "own")

    def test_typed_declarations_reject_untyped_values(self):
        with self.assertRaises(ValueError):
            Output("a", group={"key": "host", "label": "Host"})
        with self.assertRaises(ValueError):
            Binding(health, group="host")


if __name__ == "__main__":
    unittest.main()
