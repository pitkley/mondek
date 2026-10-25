# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Signed registration keeps selected workers independent and bounded."""

from __future__ import annotations

import importlib
import json
import sys
import tempfile
import unittest
import uuid
from pathlib import Path
from unittest.mock import patch

from mondek_runner import App, Binding, authoring, bundle

SOURCE = """from mondek_runner import App, Environment, Placement, check, ok
calls = []
blocked = {"excluded"}
raising = set()
def policy(context):
    calls.append(context.check_id)
    if context.check_id in raising:
        raise ValueError("policy failure for " + context.check_id)
    return "not assigned here" if context.check_id in blocked else None

def make(key):
    @check(id=key, expected_keys=("health",), placement=Placement(policy=policy))
    def sample(environment: Environment):
        return ok("health", environment.id)
    return sample

main, peer, excluded = (make(key) for key in ("main", "peer", "excluded"))
app = App(source_id="registration-probe", environment=Environment("node"),
          checks=[main, peer, excluded])
"""


class SnapshotRegistrationTests(unittest.TestCase):
    def setUp(self):
        self.addCleanup(setattr, sys, "path", list(sys.path))
        self.addCleanup(setattr, sys, "dont_write_bytecode", sys.dont_write_bytecode)
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        self.module_name = "registration_" + uuid.uuid4().hex
        package = self.directory / "site" / self.module_name
        package.mkdir(parents=True)
        self.source = package / "__init__.py"
        self.source.write_text(SOURCE)
        sys.path.insert(0, str(package.parent))
        self.addCleanup(sys.modules.pop, self.module_name, None)
        self.bundles = self.directory / "bundles"

    def snapshot(self):
        self.inventory = bundle.create_snapshot(self.module_name + ":app", self.bundles)
        self.revision = self.inventory["source_revision"]
        self.root = self.bundles / self.revision
        self.module = importlib.import_module(self.module_name)
        self.module.calls.clear()

    def load(self, key="main"):
        return bundle.load_snapshot(self.bundles, self.revision, check_key=key)

    def manifest(self):
        return json.loads((self.root / "manifest.json").read_bytes())

    def replace_signed_manifest(self, manifest):
        # Emulate a real earlier authenticated format or a deliberately malformed
        # producer. Ordinary mutations have no signing authority (tested below).
        encoded = authoring.canonical(manifest)
        (self.root / "manifest.json").write_bytes(encoded)
        (self.root / "manifest.mac").write_bytes(
            bundle.manifest_digest(self.bundles, encoded)
        )

    def test_complete_registration_includes_excluded_checks_but_not_public_inventory(
        self,
    ):
        self.snapshot()
        self.assertEqual(
            self.manifest()["registered_check_keys"], ["excluded", "main", "peer"]
        )
        self.assertEqual(
            [item["key"] for item in self.inventory["checks"]], ["main", "peer"]
        )
        self.assertNotIn("registered_check_keys", self.inventory)
        self.load()
        self.assertEqual(self.module.calls, ["main"])

    def test_unrelated_dynamic_policy_does_not_poison_a_selected_check(self):
        self.snapshot()
        self.module.raising.add("peer")
        self.load()
        self.assertEqual(self.module.calls, ["main"])
        with self.assertRaisesRegex(ValueError, "policy failure for peer"):
            self.load("peer")
        with self.assertRaisesRegex(ValueError, "policy failure for peer"):
            self.load(None)

    def test_selected_eligibility_is_rechecked_and_excluded_checks_cannot_be_admitted(
        self,
    ):
        self.snapshot()
        self.module.blocked.add("main")
        with self.assertRaisesRegex(ValueError, "excluded from this runner context"):
            self.load()
        # Becoming eligible does not add a check to the accepted inventory.
        self.module.blocked.remove("excluded")
        with self.assertRaisesRegex(ValueError, "not present in the prepared consumer"):
            self.load("excluded")

    def test_complete_registration_rejects_unrelated_addition_or_removal(self):
        self.snapshot()
        app = self.module.app
        original_restore = app.restore_private_settings
        original_bindings = app.bindings.copy()
        for mutation in ("add", "remove"):
            with self.subTest(mutation=mutation):
                app.bindings = original_bindings.copy()

                def restore_then_mutate(settings, mutation=mutation):
                    original_restore(settings)
                    if mutation == "add":
                        app.add(Binding(self.module.peer, key="unexpected"))
                    else:
                        app.bindings.pop("excluded")

                with patch.object(app, "restore_private_settings", restore_then_mutate):
                    with self.assertRaisesRegex(ValueError, "complete snapshot"):
                        self.load()

    def test_missing_registration_is_rejected_before_import(
        self,
    ):
        self.snapshot()
        manifest = self.manifest()
        manifest.pop("registered_check_keys")
        self.replace_signed_manifest(manifest)
        with patch.object(bundle, "load_app") as importing:
            with self.assertRaisesRegex(ValueError, "requires complete registration"):
                self.load()
            importing.assert_not_called()

    def test_full_and_custom_metadata_loads_still_validate_unrelated_eligibility(self):
        self.snapshot()
        self.module.blocked.add("peer")
        with self.assertRaisesRegex(ValueError, "complete snapshot"):
            self.load(None)

        class CustomApp(App):
            def metadata(self, revision):
                return super().metadata(revision)

        self.module.app.__class__ = CustomApp
        with self.assertRaisesRegex(ValueError, "complete snapshot"):
            self.load()
        self.module.blocked.remove("peer")
        # An arbitrary metadata override changes excluded coverage to unresolved.
        # That new public contract requires its own authenticated snapshot.
        with self.assertRaisesRegex(ValueError, "coverage differs"):
            self.load()
        with patch.object(
            bundle, "package_root", return_value=(self.module_name, self.source.parent)
        ):
            self.snapshot()
        self.assertIn(f"{self.module_name}/__init__.py", self.manifest()["files"])
        self.load()
        self.module.blocked.add("peer")
        with self.assertRaisesRegex(ValueError, "complete snapshot"):
            self.load()

    def test_registration_tampering_is_rejected_before_import_or_dependency_checks(
        self,
    ):
        self.snapshot()
        original = self.manifest()
        for action in ("remove", "strip", "add"):
            manifest = dict(original)
            if action == "strip":
                manifest.pop("registered_check_keys")
            else:
                manifest["registered_check_keys"] = (
                    ["main", "peer"]
                    if action == "remove"
                    else ["excluded", "main", "peer", "added"]
                )
            (self.root / "manifest.json").write_bytes(authoring.canonical(manifest))
            with (
                self.subTest(action=action),
                patch.object(bundle, "load_app") as importing,
                patch.object(bundle, "dependencies") as dependencies,
                self.assertRaisesRegex(ValueError, "manifest authentication failed"),
            ):
                self.load()
            importing.assert_not_called()
            dependencies.assert_not_called()

    def test_malformed_signed_registration_is_not_treated_as_a_legacy_manifest(self):
        self.snapshot()
        original = self.manifest()
        for keys in (
            None,
            {},
            "main",
            ["main", "peer", "excluded", "excluded"],
            [1],
            [],
        ):
            with self.subTest(keys=keys):
                self.replace_signed_manifest(
                    {**original, "registered_check_keys": keys}
                )
                with self.assertRaisesRegex(ValueError, "complete snapshot"):
                    self.load()

    def test_source_and_dependency_integrity_still_precede_import(self):
        self.snapshot()
        with (
            patch.object(bundle, "dependencies", return_value={}),
            patch.object(bundle, "load_app") as importing,
        ):
            with self.assertRaisesRegex(ValueError, "dependencies changed"):
                self.load()
            importing.assert_not_called()
        path = self.root / self.module_name / "__init__.py"
        path.write_text(path.read_text() + "\n# changed after snapshot\n")
        with patch.object(bundle, "load_app") as importing:
            with self.assertRaisesRegex(ValueError, "consumer source changed"):
                self.load()
            importing.assert_not_called()

    def test_selected_worker_reflects_only_its_check_in_a_large_catalogue(self):
        self.source.write_text(
            SOURCE.replace(
                "checks=[main, peer, excluded]",
                "checks=[main, peer, excluded] + "
                '[make("other-" + str(n)) for n in range(497)]',
            )
        )
        self.snapshot()
        with patch.object(
            authoring, "get_type_hints", wraps=authoring.get_type_hints
        ) as hints:
            self.load()
        self.assertEqual(hints.call_count, 2)
        self.assertEqual(self.module.calls, ["main"])
        self.assertEqual(len(self.manifest()["registered_check_keys"]), 500)


if __name__ == "__main__":
    unittest.main()
