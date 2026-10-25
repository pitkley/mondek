# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Old source construction survives failed or changed deployment settings."""

from __future__ import annotations

import json
import os
import sys
import tempfile
import unittest
import uuid
from pathlib import Path
from unittest.mock import patch

from mondek_runner import App, Environment, bundle, check
from mondek_runner.runtime import execute

SOURCE = """import os
from mondek_runner import App, Environment, check, ok
original = os.environ["TEST_REQUIRED_INPUT"]
if original == "broken":
    raise ValueError("invalid construction settings")
@check(id="main", expected_keys=("health",), timeout_seconds=2)
def main(environment: Environment):
    return ok("health", ":".join((environment.metadata["original"],
        os.environ.get("TEST_REQUIRED_INPUT", "absent"),
        os.environ["TEST_RUNTIME_INPUT"])))
@check(id="optional", expected_keys=("health",), timeout_seconds=2)
def optional(): return ok("health", "optional present")
app = App(source_id="construction-probe",
    environment=Environment("node", metadata={"original": original}),
    checks=[main, optional] if os.environ.get("TEST_OPTIONAL_INPUT") else [main],
    construction_environment={name: os.environ.get(name) for name in (
        "TEST_REQUIRED_INPUT", "TEST_OPTIONAL_INPUT")})
"""


def assignment(inventory):
    entry = inventory["checks"][0]
    return {
        **entry,
        "id": str(uuid.uuid4()),
        "kind": "python",
        "generation": 1,
        "source_key": entry["key"],
        "source_id": inventory["source_id"],
        "source_revision": inventory["source_revision"],
        "expected_keys": [item["key"] for item in entry["outputs"]],
    }


class DeclarationTests(unittest.TestCase):
    def app(self, **kwargs):
        return App(source_id="test", environment=Environment("node"), **kwargs)

    def test_declaration_is_private_copied_and_checked_during_restore(self):
        self.assertNotIn("construction_environment", self.app().private_settings())
        values = {"PRIVATE_SETTING": "secret-value", "OPTIONAL_SETTING": None}
        app = self.app(construction_environment=values)
        values["PRIVATE_SETTING"] = "changed"
        private = app.private_settings()
        self.assertEqual(
            private["construction_environment"]["PRIVATE_SETTING"], "secret-value"
        )
        self.assertIsNone(private["construction_environment"]["OPTIONAL_SETTING"])
        self.assertNotIn("secret-value", json.dumps(app.metadata("a" * 64)))
        app.restore_private_settings(private)
        private["construction_environment"]["PRIVATE_SETTING"] = "changed"
        with self.assertRaisesRegex(ValueError, "differs from prepared declaration"):
            app.restore_private_settings(private)
        with self.assertRaisesRegex(ValueError, "differs from prepared declaration"):
            self.app(construction_environment={}).restore_private_settings(
                self.app().private_settings()
            )

    def test_names_values_and_total_size_are_bounded_without_disclosing_values(self):
        for invalid in (
            [],
            {"": "secret-value"},
            {"BAD=NAME": "secret-value"},
            {"a" * 129: "secret-value"},
            {"INPUT": 1},
            {"INPUT": "secret-value\0"},
            {f"KEY_{index}": None for index in range(65)},
            {"INPUT": "secret-value" * 6000},
            {"ONE": "x" * 33000, "TWO": "y" * 33000},
        ):
            with (
                self.subTest(kind=type(invalid)),
                self.assertRaises(ValueError) as raised,
            ):
                self.app(construction_environment=invalid)
            self.assertNotIn("secret-value", str(raised.exception))


class SnapshotConstructionTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        original_path = list(sys.path)
        original_bytecode = sys.dont_write_bytecode
        self.addCleanup(setattr, sys, "path", original_path)
        self.addCleanup(setattr, sys, "dont_write_bytecode", original_bytecode)
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        package = root / "site" / "construction_probe"
        package.mkdir(parents=True)
        (package / "__init__.py").write_text(SOURCE)
        self.bundles = root / "bundles"
        self.environment = patch.dict(
            os.environ,
            {
                "PYTHONPATH": str(package.parent)
                + os.pathsep
                + os.environ.get("PYTHONPATH", ""),
                "TEST_REQUIRED_INPUT": "original-private",
                "TEST_RUNTIME_INPUT": "runtime-new",
            },
        )
        self.environment.start()
        self.addCleanup(self.environment.stop)
        os.environ.pop("TEST_OPTIONAL_INPUT", None)

    async def test_manifest_authenticates_selected_and_unrelated_entries_before_import(
        self,
    ):
        os.environ["TEST_OPTIONAL_INPUT"] = "present"
        inventory = await bundle.snapshot("construction_probe:app", self.bundles)
        root = self.bundles / inventory["source_revision"]
        path = root / "manifest.json"
        original = path.read_bytes()
        self.assertEqual((root / "manifest.mac").stat().st_mode & 0o777, 0o600)
        for index in (0, 1):
            manifest = json.loads(original)
            manifest["inventory"]["checks"][index]["label"] = "tampered"
            path.write_text(json.dumps(manifest))
            with (
                patch.object(bundle, "load_app") as importing,
                patch.object(bundle, "dependencies") as dependencies,
            ):
                with self.assertRaisesRegex(
                    ValueError, "manifest authentication failed"
                ):
                    bundle.load_snapshot(
                        self.bundles, inventory["source_revision"], check_key="main"
                    )
                importing.assert_not_called()
                dependencies.assert_not_called()
        path.write_bytes(original)
        manifest = json.loads(original)
        manifest.pop("snapshot_format")
        manifest["entrypoint"] = "must_not_import:app"
        path.write_text(json.dumps(manifest))
        (root / "manifest.mac").unlink()
        with patch.object(bundle, "load_app") as importing:
            with self.assertRaisesRegex(
                ValueError, "unsupported consumer snapshot format"
            ):
                bundle.load_snapshot(
                    self.bundles, inventory["source_revision"], check_key="main"
                )
            importing.assert_not_called()

    async def test_failed_current_construction_and_new_membership_preserve_old_worker(
        self,
    ):
        first = await bundle.snapshot("construction_probe:app", self.bundles)
        config = assignment(first)
        self.assertNotIn("original-private", json.dumps(first))
        private = self.bundles / first["source_revision"] / "private.json"
        self.assertEqual(private.stat().st_mode & 0o777, 0o600)
        os.environ.update(TEST_REQUIRED_INPUT="broken", TEST_OPTIONAL_INPUT="added")
        with self.assertRaisesRegex(ValueError, "invalid construction settings"):
            await bundle.snapshot("construction_probe:app", self.bundles)
        prepared = await execute(config, prepare=True, bundle_dir=self.bundles)
        self.assertTrue(prepared["prepared"], prepared)
        outcome = await execute(config, bundle_dir=self.bundles)
        self.assertTrue(outcome["complete"], outcome)
        self.assertEqual(
            outcome["results"][0]["summary"], "original-private:broken:runtime-new"
        )
        # Even declared values are construction-only; execution sees current env.
        self.assertEqual(os.environ["TEST_REQUIRED_INPUT"], "broken")
        os.environ["TEST_REQUIRED_INPUT"] = "next-private"
        second = await bundle.snapshot("construction_probe:app", self.bundles)
        self.assertNotEqual(first["source_revision"], second["source_revision"])
        self.assertEqual(len(second["checks"]), 2)
        os.environ.pop("TEST_REQUIRED_INPUT")
        os.environ.pop("TEST_OPTIONAL_INPUT")
        result = await execute(assignment(second), bundle_dir=self.bundles)
        self.assertTrue(result["complete"], result)
        self.assertEqual(
            result["results"][0]["summary"], "next-private:absent:runtime-new"
        )

    async def test_authentication_before_import_and_environment_restoration(self):
        inventory = await bundle.snapshot("construction_probe:app", self.bundles)
        revision = inventory["source_revision"]
        private_path = self.bundles / revision / "private.json"
        original = private_path.read_bytes()
        private_path.write_bytes(original + b" ")
        with patch.object(bundle, "load_app") as importing:
            with self.assertRaisesRegex(ValueError, "private settings changed"):
                bundle.load_snapshot(self.bundles, revision)
            importing.assert_not_called()
        private_path.write_bytes(original)
        os.environ["TEST_REQUIRED_INPUT"] = "new"
        os.environ["TEST_OPTIONAL_INPUT"] = "added"

        def failing_import(_entrypoint):
            self.assertEqual(os.environ["TEST_REQUIRED_INPUT"], "original-private")
            self.assertNotIn("TEST_OPTIONAL_INPUT", os.environ)
            raise ValueError("import failure")

        with patch.object(bundle, "load_app", side_effect=failing_import):
            with self.assertRaisesRegex(ValueError, "import failure"):
                bundle.load_snapshot(self.bundles, revision)
        self.assertEqual(os.environ["TEST_REQUIRED_INPUT"], "new")
        self.assertEqual(os.environ["TEST_OPTIONAL_INPUT"], "added")

        @check(id="main", expected_keys=("health",))
        def unused():
            raise AssertionError("construction test must not execute a check")

        app = App(
            source_id="construction-probe",
            environment=Environment("node"),
            checks=[unused],
            construction_environment={
                "TEST_REQUIRED_INPUT": "original-private",
                "TEST_OPTIONAL_INPUT": None,
            },
        )
        # Successful construction and validation also remain inside the overlay.
        with (
            patch.object(bundle, "load_app", return_value=app),
            patch.object(app, "restore_private_settings"),
            patch.object(bundle, "validated_snapshot") as validated,
        ):
            validated.side_effect = lambda *args: (dict(os.environ), {})
            effective, _ = bundle.load_snapshot(self.bundles, revision)
            self.assertEqual(effective["TEST_REQUIRED_INPUT"], "original-private")
            self.assertNotIn("TEST_OPTIONAL_INPUT", effective)
        self.assertEqual(os.environ["TEST_REQUIRED_INPUT"], "new")
        self.assertEqual(os.environ["TEST_OPTIONAL_INPUT"], "added")
