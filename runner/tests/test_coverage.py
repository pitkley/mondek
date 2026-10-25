# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Complete declarations remain visible independently of execution placement."""

from __future__ import annotations

import copy
import importlib
import json
import sys
import tempfile
import unittest
import uuid
from dataclasses import replace
from hashlib import sha256
from pathlib import Path
from unittest.mock import patch

from mondek_runner import (
    App,
    Binding,
    Capability,
    Datasource,
    Environment,
    Output,
    Parameter,
    Placement,
    RunnerContext,
    Target,
    authoring,
    bundle,
    check,
)
from mondek_runner.state import State

PRODUCTION = Environment("production", "Production", {"secret": "private-region"})
STAGING = Environment("staging", "Staging")


class LocalFiles(Datasource):
    placement = Placement(requires=("local-files",), locality="runner-target")

    def __init__(self):
        raise AssertionError("discovery must not construct a datasource")


class LogSearch(Datasource):
    placement = Placement(requires=("logs",))

    def __init__(self, token):
        raise AssertionError("discovery must not construct a datasource")


@check(id="disk", expected_keys=("capacity",))
def disk(files: LocalFiles):
    raise AssertionError("discovery must not execute a check")


@check(
    id="logs",
    expected_keys=("errors",),
    environments=(STAGING, PRODUCTION),
    params={"limit": 10},
    parameters={"limit": Parameter("integer", "Maximum errors", minimum=0)},
    parameter_contract="error-count.v1",
)
def logs(source: LogSearch, params):
    raise AssertionError("discovery must not execute a check")


class CoverageMetadataTests(unittest.TestCase):
    def catalogue(self, app):
        return app.coverage_metadata(app.metadata("a" * 64))

    def test_shared_scope_with_no_eligible_observer_is_concrete_and_provider_free(self):
        app = App(source_id="project", runner=RunnerContext("node"), checks=[logs])
        self.assertEqual(app.metadata("a" * 64), [])
        candidates = self.catalogue(app)["candidates"]
        self.assertEqual(
            {c["environment"] for c in candidates}, {"staging", "production"}
        )
        for candidate in candidates:
            self.assertFalse(candidate["selected"])
            self.assertTrue(candidate["scope_resolved"])
            self.assertIsNone(candidate["scope_reason"])
            self.assertIn(
                "lacks declared capabilities: logs", candidate["exclusion_reason"]
            )
            self.assertEqual(
                candidate["outputs"][0]["target"]["key"], candidate["environment"]
            )
            self.assertEqual(candidate["outputs"][0]["target"]["kind"], "environment")
        self.assertNotIn("private-region", json.dumps(candidates))

    def test_explicit_roster_declares_a_never_installed_node(self):
        node_a = Target("node:a", "Node A")
        node_b = Target("node:b", "Node B")
        app = App(
            source_id="project",
            runner=RunnerContext(
                "node-a",
                capabilities=("local-files",),
                target=node_a,
                local_environment=PRODUCTION,
            ),
            checks=[
                Binding(disk, key="disk-a", environment=PRODUCTION, target=node_a),
                Binding(disk, key="disk-b", environment=PRODUCTION, target=node_b),
            ],
        )
        app.register_datasource(LocalFiles)
        selected, excluded = self.catalogue(app)["candidates"]
        self.assertTrue(selected["selected"])
        self.assertEqual(selected["outputs"][0]["target"], node_a.to_dict())
        self.assertFalse(excluded["selected"])
        self.assertTrue(excluded["scope_resolved"])
        self.assertEqual(excluded["environment"], "production")
        self.assertEqual(excluded["outputs"][0]["target"], node_b.to_dict())
        self.assertEqual(
            "Requires execution on target host:node:b; runner target is host:node:a",
            excluded["exclusion_reason"],
        )

    def test_unbound_template_preserves_known_outputs_without_inventing_environment(
        self,
    ):
        known = Target("volume:data", "Data", "volume")
        app = App(
            source_id="project",
            runner=RunnerContext("shared"),
            checks=[
                Binding(
                    disk, outputs=(Output("capacity"), Output("known", target=known))
                )
            ],
        )
        [candidate] = self.catalogue(app)["candidates"]
        self.assertFalse(candidate["selected"])
        self.assertFalse(candidate["scope_resolved"])
        self.assertIsNone(candidate["environment"])
        self.assertIsNone(candidate["environment_label"])
        self.assertIsNone(candidate["outputs"][0]["target"])
        self.assertEqual(candidate["outputs"][1]["target"], known.to_dict())
        self.assertIn("does not declare", candidate["scope_reason"])
        self.assertEqual(app.bindings["disk"].outputs[0].target, None)

    def test_public_definition_is_independent_of_private_access_and_eligibility(self):
        excluded = App(
            source_id="project", runner=RunnerContext("no-access"), checks=[logs]
        )
        selected = App(
            source_id="project",
            runner=RunnerContext(
                "shared",
                capabilities=(Capability("logs", ("staging",)),),
                local_environment=PRODUCTION,
            ),
            checks=[logs],
        )
        selected.register_datasource(LogSearch, token="private-access-token")
        before = self.catalogue(selected)
        other = self.catalogue(excluded)
        self.assertEqual(
            [c["definition_revision"] for c in before["candidates"]],
            [c["definition_revision"] for c in other["candidates"]],
        )
        self.assertEqual(
            before["runner_context"]["capabilities"],
            [{"name": "logs", "environments": ["staging"]}],
        )
        selected.register_datasource(LogSearch, token="another-private-token")
        self.assertEqual(before, self.catalogue(selected))
        for secret in (
            "private-region",
            "private-access-token",
            "another-private-token",
        ):
            self.assertNotIn(secret, json.dumps(before))
        for key, binding in selected.bindings.copy().items():
            selected.bindings[key] = replace(binding, params={"limit": 20})
        after = self.catalogue(selected)
        for first, second in zip(
            before["candidates"], after["candidates"], strict=True
        ):
            self.assertNotEqual(
                first["definition_revision"], second["definition_revision"]
            )
            self.assertEqual(first["key"], second["key"])

    def test_selected_metadata_overrides_are_the_actual_declared_identity(self):
        class CustomApp(App):
            def metadata(self, revision):
                rows = super().metadata(revision)
                for row in rows:
                    row["label"] = "Custom source label"
                    row["outputs"][0]["target"] = Target(
                        "cluster", "Cluster", "service"
                    ).to_dict()
                return rows

        app = CustomApp(
            source_id="project",
            runner=RunnerContext("shared", capabilities=("logs",)),
            checks=[logs],
        )
        app.register_datasource(LogSearch, token="secret")
        selected = app.metadata("a" * 64)
        original = copy.deepcopy(selected)
        candidates = app.coverage_metadata(selected)["candidates"]
        self.assertEqual(candidates[0]["label"], "Custom source label")
        self.assertEqual(candidates[0]["outputs"], selected[0]["outputs"])
        self.assertTrue(candidates[0]["scope_resolved"])
        self.assertEqual(selected, original)
        with self.assertRaisesRegex(ValueError, "coverage placement differs"):
            app.coverage_metadata(selected[:1])

        excluded_app = CustomApp(
            source_id="project", runner=RunnerContext("shared"), checks=[logs]
        )
        for candidate in self.catalogue(excluded_app)["candidates"]:
            self.assertFalse(candidate["selected"])
            self.assertFalse(candidate["scope_resolved"])
            self.assertIn("Custom metadata", candidate["scope_reason"])
            self.assertIn("coverage_metadata", candidate["scope_reason"])

    def test_excluded_metadata_must_obey_the_same_public_definition_bounds(self):
        app = App(
            source_id="project",
            runner=RunnerContext("shared"),
            checks=[
                Binding(disk, outputs=tuple(Output(f"disk-{n}") for n in range(17)))
            ],
        )
        self.assertEqual(app.metadata("a" * 64), [])
        with self.assertRaisesRegex(ValueError, "1–16 unique output"):
            self.catalogue(app)

    def test_empty_catalogue_is_explicit_and_string_grants_are_normalized(self):
        app = App(
            source_id="project",
            runner=RunnerContext("shared", capabilities=("logs",)),
        )
        catalogue = self.catalogue(app)
        self.assertEqual(catalogue["candidates"], [])
        self.assertEqual(
            catalogue["runner_context"]["capabilities"],
            [{"name": "logs", "environments": None}],
        )

    def test_large_placement_explanations_are_bounded_without_dropping_candidates(self):
        @check(
            id="many-grants",
            expected_keys=("health",),
            placement=Placement(requires=tuple(f"grant-{n:03d}" for n in range(512))),
        )
        def probe():
            raise AssertionError("excluded code must not execute")

        app = App(source_id="project", runner=RunnerContext("shared"), checks=[probe])
        [candidate] = self.catalogue(app)["candidates"]
        reason = candidate["exclusion_reason"]
        self.assertLessEqual(len(reason.encode()), 2048)
        self.assertTrue(reason.endswith("..."))
        self.assertTrue(
            reason.startswith("Runner context lacks declared capabilities:")
        )
        self.assertEqual(
            app.placement_summary()["excluded_checks"][0]["reason"], reason
        )
        self.assertEqual(candidate["key"], "many-grants")
        self.assertFalse(candidate["selected"])


SOURCE = """from mondek_runner import (
    App, Datasource, Environment, Placement, check, ok,
)
class Remote(Datasource):
    def __init__(self, token): self.token = token
@check(id="selected", expected_keys=("health",))
def selected(source: Remote): return ok("health", "measured")
@check(id="excluded", expected_keys=("health",), params={"limit": 10},
       placement=Placement(runner_contexts=("elsewhere",)))
def excluded(params): return ok("health", "not executed")
app = App(source_id="coverage-package", environment=Environment("production"),
          checks=[selected, excluded])
app.register_datasource(Remote, token="private-old-token")
"""


class CoverageSnapshotTests(unittest.TestCase):
    def setUp(self):
        self.addCleanup(setattr, sys, "path", list(sys.path))
        self.addCleanup(setattr, sys, "dont_write_bytecode", sys.dont_write_bytecode)
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        self.module_name = "coverage_" + uuid.uuid4().hex
        self.package = self.directory / "site" / self.module_name
        self.package.mkdir(parents=True)
        self.source = self.package / "__init__.py"
        self.source.write_text(SOURCE)
        sys.path.insert(0, str(self.package.parent))
        self.addCleanup(sys.modules.pop, self.module_name, None)
        self.bundles = self.directory / "bundles"

    def snapshot(self, directory=None):
        # Production discovery imports in a fresh process. Repeated in-process
        # calls would otherwise rediscover the preceding temporary module path.
        with patch.object(
            bundle, "package_root", return_value=(self.module_name, self.package)
        ):
            return bundle.create_snapshot(
                self.module_name + ":app", directory or self.bundles
            )

    def test_code_runtime_and_public_definition_fingerprints_have_separate_authority(
        self,
    ):
        first = self.snapshot()
        module = importlib.import_module(self.module_name)
        module.app.register_datasource(module.Remote, token="private-new-token")
        second = self.snapshot(self.directory / "other-installation")
        self.assertNotEqual(first["source_revision"], second["source_revision"])
        self.assertEqual(first["coverage"], second["coverage"])
        self.assertNotIn("private-old-token", json.dumps(first))
        self.assertNotIn("private-new-token", json.dumps(second))
        with patch.object(bundle, "dependencies", return_value={"changed": "runtime"}):
            third = self.snapshot(self.directory / "other-runtime")
        self.assertEqual(
            first["coverage"]["code_revision"], third["coverage"]["code_revision"]
        )
        self.assertNotEqual(
            first["coverage"]["runtime_revision"], third["coverage"]["runtime_revision"]
        )
        self.source.write_text(SOURCE + "\n# independent code revision\n")
        fourth = self.snapshot(self.directory / "other-code")
        self.assertNotEqual(
            first["coverage"]["code_revision"], fourth["coverage"]["code_revision"]
        )
        self.assertEqual(
            first["coverage"]["runtime_revision"],
            fourth["coverage"]["runtime_revision"],
        )

    def test_custom_metadata_can_omit_optional_environment_label(self):
        self.source.write_text(
            SOURCE.replace(
                'app = App(source_id="coverage-package",',
                "class CustomApp(App):\n"
                "    def metadata(self, revision):\n"
                "        rows = super().metadata(revision)\n"
                "        for row in rows: row.pop('environment_label')\n"
                "        return rows\n"
                'app = CustomApp(source_id="coverage-package",',
            )
        )
        inventory = self.snapshot()
        candidate = next(
            c for c in inventory["coverage"]["candidates"] if c["selected"]
        )
        self.assertEqual(candidate["environment"], "production")
        self.assertIsNone(candidate["environment_label"])
        self.assertTrue(candidate["scope_resolved"])
        self.assertNotIn("environment_label", inventory["checks"][0])
        for selected_key in (None, "selected"):
            _, loaded = bundle.load_snapshot(
                self.bundles, inventory["source_revision"], check_key=selected_key
            )
            self.assertEqual(loaded, inventory)

    def test_custom_metadata_omitted_environment_is_a_resolved_null_namespace(self):
        self.source.write_text(
            SOURCE.replace(
                'app = App(source_id="coverage-package",',
                "class CustomApp(App):\n"
                "    def metadata(self, revision):\n"
                "        rows = super().metadata(revision)\n"
                "        for row in rows:\n"
                "            row.pop('environment')\n"
                "            row.pop('environment_label')\n"
                "        return rows\n"
                'app = CustomApp(source_id="coverage-package",',
            )
        )
        inventory = self.snapshot()
        candidate = next(
            c for c in inventory["coverage"]["candidates"] if c["selected"]
        )
        self.assertIsNone(candidate["environment"])
        self.assertIsNone(candidate["environment_label"])
        self.assertTrue(candidate["scope_resolved"])
        self.assertIsNone(candidate["scope_reason"])
        for selected_key in (None, "selected"):
            app, loaded = bundle.load_snapshot(
                self.bundles, inventory["source_revision"], check_key=selected_key
            )
            self.assertEqual(loaded, inventory)

        descriptors = app.metadata("a" * 64)
        null_catalogue = app.coverage_metadata(descriptors)
        descriptors[0].update(environment=None, environment_label=None)
        self.assertEqual(app.coverage_metadata(descriptors), null_catalogue)
        descriptors[0].update(environment="production", environment_label="Production")
        named = app.coverage_metadata(descriptors)["candidates"][0]
        self.assertNotEqual(named["environment"], candidate["environment"])
        self.assertNotEqual(
            named["definition_revision"], candidate["definition_revision"]
        )

    def test_custom_scope_preserves_existing_inventory_text_bounds(self):
        self.source.write_text(
            SOURCE.replace(
                'app = App(source_id="coverage-package",',
                "class CustomApp(App):\n"
                "    def metadata(self, revision):\n"
                "        rows = super().metadata(revision)\n"
                "        for row in rows:\n"
                "            row['environment'] = 'Production Europe'\n"
                "            row['outputs'][0]['target'] = {\n"
                "                'kind': 'remote service',\n"
                "                'key': 'cluster ' + 'a' * 170,\n"
                "                'label': 'Search cluster'}\n"
                "        return rows\n"
                'app = CustomApp(source_id="coverage-package",',
            )
        )
        inventory = self.snapshot()
        candidate = next(
            c for c in inventory["coverage"]["candidates"] if c["selected"]
        )
        self.assertEqual(candidate["environment"], "Production Europe")
        self.assertEqual(candidate["outputs"], inventory["checks"][0]["outputs"])
        self.assertTrue(candidate["scope_resolved"])
        for selected_key in (None, "selected"):
            app, loaded = bundle.load_snapshot(
                self.bundles, inventory["source_revision"], check_key=selected_key
            )
            self.assertEqual(loaded, inventory)

        for field, invalid in (
            ("kind", "x" * 65),
            ("key", "x" * 201),
            ("label", "a\x7fb"),
        ):
            with self.subTest(field=field):
                descriptors = app.metadata("a" * 64)
                descriptors[0]["outputs"][0]["target"][field] = invalid
                with self.assertRaisesRegex(ValueError, "coverage target"):
                    app.coverage_metadata(descriptors)
        for invalid in ("x" * 129, "a\x00b"):
            with self.subTest(environment=repr(invalid)):
                descriptors = app.metadata("a" * 64)
                descriptors[0]["environment"] = invalid
                with self.assertRaisesRegex(ValueError, "coverage environment"):
                    app.coverage_metadata(descriptors)

    def test_selected_workers_do_not_rebuild_catalogue_but_full_loads_validate_it(self):
        inventory = self.snapshot()
        revision = inventory["source_revision"]
        app = importlib.import_module(self.module_name).app
        app.bindings["excluded"] = replace(
            app.bindings["excluded"], params={"limit": 20}
        )
        with patch.object(
            app, "coverage_metadata", side_effect=AssertionError("catalogue rebuilt")
        ):
            _, loaded = bundle.load_snapshot(
                self.bundles, revision, check_key="selected"
            )
            self.assertEqual(loaded, inventory)
        with self.assertRaisesRegex(ValueError, "coverage differs"):
            bundle.load_snapshot(self.bundles, revision)

    def test_catalogue_tampering_is_rejected_before_import(self):
        inventory = self.snapshot()
        path = self.bundles / inventory["source_revision"] / "manifest.json"
        manifest = json.loads(path.read_bytes())
        manifest["inventory"]["coverage"]["candidates"][1]["selected"] = True
        path.write_bytes(authoring.canonical(manifest))
        with (
            patch.object(bundle, "load_app") as importing,
            self.assertRaisesRegex(ValueError, "manifest authentication failed"),
        ):
            bundle.load_snapshot(
                self.bundles, inventory["source_revision"], check_key="selected"
            )
        importing.assert_not_called()

    def test_earlier_authenticated_snapshots_without_coverage_keep_their_hash_contract(
        self,
    ):
        inventory = self.snapshot()
        root = self.bundles / inventory["source_revision"]
        manifest = json.loads((root / "manifest.json").read_bytes())
        manifest["inventory"].pop("coverage")
        base = sha256(
            authoring.canonical(
                [
                    manifest["entrypoint"],
                    manifest["files"],
                    manifest["runtime"],
                    manifest["private_digest"],
                ]
            )
        ).hexdigest()
        checks = bundle.metadata_at_revision(manifest["inventory"]["checks"], base)
        revision = sha256(
            authoring.canonical([base, inventory["source_id"], checks])
        ).hexdigest()
        manifest["inventory"]["source_revision"] = revision
        manifest["inventory"]["checks"] = bundle.metadata_at_revision(checks, revision)
        encoded = authoring.canonical(manifest)
        (root / "manifest.json").write_bytes(encoded)
        (root / "manifest.mac").write_bytes(
            bundle.manifest_digest(self.bundles, encoded)
        )
        root.rename(self.bundles / revision)
        app = importlib.import_module(self.module_name).app
        with patch.object(
            app, "coverage_metadata", side_effect=AssertionError("legacy catalogue")
        ):
            for selected in (None, "selected"):
                _, loaded = bundle.load_snapshot(
                    self.bundles, revision, check_key=selected
                )
                self.assertNotIn("coverage", loaded)

    def test_excluded_changes_allocate_new_source_and_durable_inventory_revision(
        self,
    ):
        first = self.snapshot()
        module = importlib.import_module(self.module_name)
        module.app.bindings["excluded"] = replace(
            module.app.bindings["excluded"], params={"limit": 20}
        )
        second = self.snapshot()
        self.assertNotEqual(first["source_revision"], second["source_revision"])
        self.assertEqual(
            first["coverage"]["code_revision"], second["coverage"]["code_revision"]
        )
        path = self.directory / "state"
        state = State(path)
        try:
            first_record = state.record_inventory(first)
            self.assertEqual(state.record_inventory(first), first_record)
            second_record = state.record_inventory(second)
            self.assertEqual(
                second_record["inventory_revision"],
                first_record["inventory_revision"] + 1,
            )
        finally:
            state.close()
        state = State(path)
        try:
            self.assertEqual(state.inventory(), second_record)
            self.assertEqual(state.record_inventory(second), second_record)
        finally:
            state.close()

    def test_complete_manifest_limit_rejects_coverage_without_silent_truncation(self):
        with patch.object(bundle, "MAX_INVENTORY", 1000):
            with self.assertRaisesRegex(ValueError, "metadata exceeds"):
                self.snapshot()
        self.assertEqual(list(self.bundles.glob("*/manifest.json")), [])


if __name__ == "__main__":
    unittest.main()
