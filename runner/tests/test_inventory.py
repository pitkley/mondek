# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0

from __future__ import annotations

import asyncio
import json
import os
import tempfile
import threading
import unittest
import uuid
from decimal import Decimal
from hashlib import sha256
from pathlib import Path
from unittest.mock import patch

from mondek_runner.authoring import canonical
from mondek_runner.bundle import (
    PRIVATE_FORMAT_KEY,
    metadata_at_revision,
    settings_digest,
    snapshot,
)
from mondek_runner.runtime import Runner, execute
from mondek_runner.state import State

# Inventory tests exercise immutable source/admission behavior, including cold
# discovery alongside execution. Dedicated supervision tests cover deadlines.
SOURCE = """from mondek_runner import App, Environment, Output, Target, check, ok

@check(id="exports", name="Export files", outputs=(
    Output("a", "First export", Target("one", "First service", "service")),
    Output("b", "Second export", Target("two", "Second service", "service")),
), interval_seconds=0.1,timeout_seconds=2,freshness_seconds=2)
def exports():
    yield ok("a", "real consumer A")
    yield ok("b", "real consumer B")

app = App(source_id="ordinary-package", environment=Environment("node-a"),
          checks=[exports])
"""


def assignment(inventory, generation=1):
    item = inventory["checks"][0]
    return {
        **item,
        "id": str(uuid.uuid4()),
        "kind": "python",
        "generation": generation,
        "source_key": item["key"],
        "source_id": inventory["source_id"],
        "source_revision": inventory["source_revision"],
        "expected_keys": [item["key"] for item in item["outputs"]],
    }


class InventoryTests(unittest.IsolatedAsyncioTestCase):
    async def test_inherited_class_and_static_factories_execute_frozen_selectors(self):
        self.source.write_text("""import os
from pathlib import Path
from typing import Annotated
from mondek_runner import (
    App, Datasource, DatasourceFactory, Environment, FromFactory, check, ok,
)
class Source(Datasource):
    def __init__(self, text):
        self.text = text
class BaseFactory(DatasourceFactory):
    def __init__(self, log):
        with Path(log).open("a") as handle:
            handle.write(type(self).__name__ + "\\n")
class ClassFactory(BaseFactory):
    prefix = "base"
    @classmethod
    def new(cls, name, /, *, suffix):
        return Source(cls.prefix + ":" + name + suffix)
class ChildClassFactory(ClassFactory):
    prefix = "child"
class StaticFactory(BaseFactory):
    @staticmethod
    def new(*, name):
        return Source("static:" + name)
class ChildStaticFactory(StaticFactory):
    pass
@check(id="probe", expected_keys=("health",), timeout_seconds=2)
def probe(
    first: Annotated[Source, FromFactory(ChildClassFactory,
        os.environ["TEST_FACTORY_VALUE"], suffix="/class")],
    second: Annotated[Source, FromFactory(ChildStaticFactory,
        name=os.environ["TEST_FACTORY_VALUE"] + "/static")],
):
    return ok("health", first.text + "|" + second.text)
app = App(source_id="factory-test", environment=Environment("test"), checks=[probe])
app.register_datasource_factory(ChildClassFactory, log=os.environ["TEST_FACTORY_LOG"])
app.register_datasource_factory(ChildStaticFactory, log=os.environ["TEST_FACTORY_LOG"])
""")
        log = self.root / "constructed.log"
        with patch.dict(
            os.environ, {"TEST_FACTORY_LOG": str(log), "TEST_FACTORY_VALUE": "old"}
        ):
            first = await snapshot("ordinary_consumer:app", self.bundles)
            old = assignment(first)
        with patch.dict(
            os.environ, {"TEST_FACTORY_LOG": str(log), "TEST_FACTORY_VALUE": "new"}
        ):
            second = await snapshot("ordinary_consumer:app", self.bundles)
            new = assignment(second, generation=2)
            prepared = await execute(old, prepare=True, bundle_dir=self.bundles)
            self.assertTrue(prepared["prepared"], prepared)
            self.assertFalse(
                log.exists(), "discovery and preparation must not construct"
            )
            old_result = await execute(old, bundle_dir=self.bundles)
            new_result = await execute(new, bundle_dir=self.bundles)
        self.assertNotEqual(first["source_revision"], second["source_revision"])
        self.assertTrue(old_result["complete"], old_result)
        self.assertTrue(new_result["complete"], new_result)
        self.assertEqual(
            old_result["results"][0]["summary"], "child:old/class|static:old/static"
        )
        self.assertEqual(
            new_result["results"][0]["summary"], "child:new/class|static:new/static"
        )
        self.assertEqual(
            log.read_text().splitlines(),
            ["ChildClassFactory", "ChildStaticFactory"] * 2,
        )

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        package = self.root / "site" / "ordinary_consumer"
        package.mkdir(parents=True)
        self.source = package / "__init__.py"
        self.source.write_text(SOURCE)
        distribution = package.parent / "ordinary_consumer-1.0.dist-info"
        distribution.mkdir()
        (distribution / "METADATA").write_text(
            "Name: ordinary-consumer\nVersion: 1.0\n"
        )
        self.bundles = self.root / "bundles"
        self.environment = patch.dict(
            os.environ,
            {
                "PYTHONPATH": str(package.parent)
                + os.pathsep
                + os.environ.get("PYTHONPATH", "")
            },
        )
        self.environment.start()

    def tearDown(self):
        self.environment.stop()
        self.temporary.cleanup()

    async def test_custom_output_scopes_reject_discovery_preserving_snapshot(
        self,
    ):
        original = await snapshot("ordinary_consumer:app", self.bundles)
        state = State(self.root / "state")
        try:
            accepted = state.record_inventory(original)
            for method in ("metadata", "coverage_metadata"):
                for field in ("environment", "environment_label"):
                    for value in (None, "different-environment"):
                        with self.subTest(method=method, field=field, value=value):
                            if method == "metadata":
                                override = f"""class CustomApp(App):
    def metadata(self, revision):
        rows = super().metadata(revision)
        rows[0]["outputs"][0][{field!r}] = {value!r}
        return rows
"""
                            else:
                                override = f"""class CustomApp(App):
    def coverage_metadata(self, checks):
        data = super().coverage_metadata(checks)
        data["candidates"][0]["outputs"][0][{field!r}] = {value!r}
        return data
"""
                            self.source.write_text(
                                SOURCE.replace(
                                    "app = App(", override + "\napp = CustomApp("
                                )
                            )
                            with self.assertRaisesRegex(
                                ValueError,
                                "one monitored environment per invocation; "
                                "use separate environment bindings",
                            ):
                                await snapshot("ordinary_consumer:app", self.bundles)
                            self.assertEqual(state.inventory(), accepted)
            result = await execute(assignment(original), bundle_dir=self.bundles)
            self.assertTrue(result["complete"], result)
            self.assertEqual([row["key"] for row in result["results"]], ["a", "b"])
        finally:
            state.close()

    async def test_custom_result_serializer_cannot_override_scope_even_with_null(self):
        for field in ("environment", "environment_label"):
            for value in (None, "different-environment"):
                with self.subTest(field=field, value=value):
                    self.source.write_text(f"""
from mondek_runner import App, Environment, Result, check
class Extended(Result):
    def to_dict(self):
        data = super().to_dict()
        if self.key == "b":
            data[{field!r}] = {value!r}
        else:
            data["consumer_extension"] = "unchanged"
        return data
@check(id="exports", expected_keys=("a", "b"), timeout_seconds=3)
def exports():
    yield Extended("a", "OK", "Valid first result")
    yield Extended("b", "CRIT", "Unsupported scope")
app = App(source_id="ordinary-package", environment=Environment("node-a"),
          checks=[exports])
""")
                    inventory = await snapshot("ordinary_consumer:app", self.bundles)
                    outcome = await execute(
                        assignment(inventory), bundle_dir=self.bundles
                    )
                    self.assertFalse(outcome["complete"], outcome)
                    self.assertIn(
                        "one monitored environment per invocation; "
                        "use separate environment bindings",
                        outcome["diagnostic"],
                    )
                    self.assertEqual([row["key"] for row in outcome["results"]], ["a"])
                    self.assertEqual(
                        outcome["results"][0]["consumer_extension"], "unchanged"
                    )

    async def test_unrelated_custom_output_metadata_remains_supported(self):
        self.source.write_text(
            SOURCE.replace(
                "app = App(",
                """class CustomApp(App):
    def metadata(self, revision):
        rows = super().metadata(revision)
        rows[0]["outputs"][0]["consumer_extension"] = "unchanged"
        return rows
app = CustomApp(""",
            )
        )
        inventory = await snapshot("ordinary_consumer:app", self.bundles)
        self.assertEqual(
            inventory["checks"][0]["outputs"][0]["consumer_extension"], "unchanged"
        )
        outcome = await execute(assignment(inventory), bundle_dir=self.bundles)
        self.assertTrue(outcome["complete"], outcome)

    async def test_exported_numbers_survive_jsonb_and_keep_exact_worker_authority(self):
        self.source.write_text("""import sys
from mondek_runner import App, Datasource, Environment, Parameter, check, ok

class Settings(Datasource):
    def __init__(self, limit, ordinary):
        assert type(limit) is float and type(ordinary) is float
        assert ordinary == 1.0
        self.limit = limit

def inspect_settings(source, environment, params):
    assert source.limit == 1e23 and type(source.limit) is float
    assert environment.metadata["large"] == 1e23
    assert type(environment.metadata["large"]) is float
    assert params["limit"] == 1e23 and type(params["limit"]) is int
    return ok("value", "Exact prepared numeric configuration", value=0.125)

@check(id="delegated", expected_keys=("value",), params={"limit": 1e23},
       parameters={"limit": Parameter("number", "Limit", minimum=-sys.float_info.max,
                                    maximum=sys.float_info.max, choices=(1e23,))})
def delegated(source: Settings, environment: Environment, params):
    return inspect_settings(source, environment, params)

@check(id="source-owned", expected_keys=("value",), params={"limit": 1e23})
def source_owned(source: Settings, environment: Environment, params):
    return inspect_settings(source, environment, params)

app = App(source_id="numeric-authority", checks=[delegated, source_owned],
          environment=Environment("node", metadata={"large": 1e23}))
app.register_datasource(Settings, limit=1e23, ordinary=1.0)
""")
        inventory = await snapshot("ordinary_consumer:app", self.bundles)
        private = json.loads(
            (self.bundles / inventory["source_revision"] / "private.json").read_text()
        )
        self.assertEqual(private["environment"]["metadata"]["large"], 1e23)
        self.assertIs(type(private["environment"]["metadata"]["large"]), float)

        def expanded(value):
            if isinstance(value, Decimal):
                return (
                    int(value) if value == value.to_integral_value() else float(value)
                )
            if isinstance(value, dict):
                return {key: expanded(item) for key, item in value.items()}
            if isinstance(value, list):
                return [expanded(item) for item in value]
            return value

        for entry in inventory["checks"]:
            with self.subTest(check=entry["key"]):
                self.assertIs(type(entry["params"]["limit"]), int)
                self.assertNotEqual(entry["params"]["limit"], 10**23)
                config = assignment({**inventory, "checks": [entry]})
                # PostgreSQL JSONB expands decimal exponent notation rather than
                # restoring the original float token. Model that expansion here;
                # real database admission/replay has its separate controller test.
                persisted = expanded(
                    json.loads(json.dumps(config), parse_float=Decimal)
                )
                self.assertEqual(persisted, config)
                prepared = await execute(
                    persisted, prepare=True, bundle_dir=self.bundles
                )
                self.assertTrue(prepared["prepared"], prepared)
                measured = await execute(persisted, bundle_dir=self.bundles)
                self.assertTrue(measured["complete"], measured)
                self.assertEqual(measured["results"][0]["value"], 0.125)
                changed = json.loads(json.dumps(persisted))
                changed["params"]["limit"] += 1
                rejected = await execute(changed, prepare=True, bundle_dir=self.bundles)
                self.assertFalse(rejected["prepared"], rejected)

        self.assertIs(
            type(
                inventory["checks"][0]["parameter_schema"]["fields"]["limit"]["maximum"]
            ),
            int,
        )

    async def test_revision_sensitive_metadata_override_retains_full_verification(self):
        self.source.write_text(
            SOURCE.replace(
                "app = App(",
                """class RevisionApp(App):
    def metadata(self, revision):
        entries = super().metadata(revision)
        entries[0]["label"] += " " + revision[:8]
        return entries

app = RevisionApp(""",
            )
        )
        inventory = await snapshot("ordinary_consumer:app", self.bundles)
        config = assignment(inventory)
        prepared = await execute(config, prepare=True, bundle_dir=self.bundles)
        self.assertTrue(prepared["prepared"], prepared)
        outcome = await execute(config, bundle_dir=self.bundles)
        self.assertTrue(outcome["complete"], outcome)

    async def test_discovery_and_workers_validate_the_full_app_once_each(self):
        self.source.write_text(
            SOURCE.replace(
                "app = App(",
                """
class CountedApp(App):
    validations = 0
    def metadata(self, revision):
        self.validations += 1
        assert self.validations == 1, "duplicate full-consumer validation"
        return super().metadata(revision)

app = CountedApp(""",
            )
        )
        inventory = await snapshot("ordinary_consumer:app", self.bundles)
        config = assignment(inventory)
        self.assertTrue(
            (await execute(config, prepare=True, bundle_dir=self.bundles))["prepared"]
        )
        result = await execute(config, bundle_dir=self.bundles)
        self.assertTrue(result["complete"], result)
        self.assertEqual(len(result["results"]), 2)

    async def test_signed_inventory_rejects_tampering_but_scopes_runtime_metadata(self):
        self.source.write_text("""import os
from mondek_runner import App, Environment, check, ok
@check(id="first", expected_keys=("health",), timeout_seconds=2)
def first(): return ok("health", "unchanged")
@check(id="second", name=os.environ["TEST_OTHER_CHECK_LABEL"],
       expected_keys=("health",), timeout_seconds=2)
def second(): return ok("health", "other")
app = App(source_id="ordinary-package", environment=Environment("node"),
          checks=[first, second])
""")
        with patch.dict(os.environ, {"TEST_OTHER_CHECK_LABEL": "Before"}):
            inventory = await snapshot("ordinary_consumer:app", self.bundles)
            config = assignment(inventory)
            self.assertTrue(
                (await execute(config, prepare=True, bundle_dir=self.bundles))[
                    "prepared"
                ]
            )
            # Every saved entry is authenticated, including unrelated checks.
            manifest_path = (
                self.bundles / inventory["source_revision"] / "manifest.json"
            )
            original = manifest_path.read_bytes()
            manifest = json.loads(original)
            manifest["inventory"]["checks"][1]["label"] = "Tampered"
            manifest_path.write_text(json.dumps(manifest))
            rejected = await execute(config, prepare=True, bundle_dir=self.bundles)
            self.assertFalse(rejected["prepared"], rejected)
            self.assertIn("manifest authentication failed", rejected["diagnostic"])
            manifest_path.write_bytes(original)
        with patch.dict(os.environ, {"TEST_OTHER_CHECK_LABEL": "After"}):
            outcome = await execute(config, bundle_dir=self.bundles)
            self.assertTrue(outcome["complete"], outcome)
            second = assignment({**inventory, "checks": inventory["checks"][1:]})
            rejected = await execute(second, prepare=True, bundle_dir=self.bundles)
            self.assertFalse(rejected["prepared"], rejected)
            self.assertIn("selected check differs", rejected["diagnostic"])
        with patch.dict(os.environ, {"TEST_OTHER_CHECK_LABEL": "x" * 201}):
            with self.assertRaisesRegex(ValueError, "200 bytes"):
                await snapshot("ordinary_consumer:app", self.bundles)
            outcome = await execute(config, bundle_dir=self.bundles)
            self.assertTrue(outcome["complete"], outcome)

    async def test_snapshot_requires_authentication_and_rejects_old_formats(
        self,
    ):
        self.source.write_text(
            SOURCE.replace(
                'name="Export files"', 'name=__import__("os").environ["TEST_LABEL"]'
            )
        )
        with patch.dict(os.environ, {"TEST_LABEL": "Original"}):
            inventory = await snapshot("ordinary_consumer:app", self.bundles)
            config = assignment(inventory)
            root = self.bundles / inventory["source_revision"]
            signature = (root / "manifest.mac").read_bytes()
            (root / "manifest.mac").unlink()
            rejected = await execute(config, prepare=True, bundle_dir=self.bundles)
            self.assertFalse(rejected["prepared"], rejected)
            self.assertIn("authentication is missing", rejected["diagnostic"])
            (root / "manifest.mac").write_bytes(b"0" * 64)
            rejected = await execute(config, prepare=True, bundle_dir=self.bundles)
            self.assertFalse(rejected["prepared"], rejected)
            self.assertIn("authentication failed", rejected["diagnostic"])
            (root / "manifest.mac").write_bytes(signature)
            unknown = {**config, "source_key": "not-registered"}
            rejected = await execute(unknown, prepare=True, bundle_dir=self.bundles)
            self.assertFalse(rejected["prepared"], rejected)
            self.assertIn("not present", rejected["diagnostic"])
            # Recreate the old on-disk format without the v2 marker/signature.
            manifest = json.loads((root / "manifest.json").read_bytes())
            manifest.pop("snapshot_format")
            manifest["inventory"].pop("coverage")
            private = json.loads((root / "private.json").read_bytes())
            private.pop(PRIVATE_FORMAT_KEY)
            private_bytes = canonical(private)
            manifest["private_digest"] = settings_digest(self.bundles, private_bytes)
            base = sha256(
                canonical(
                    [
                        manifest["entrypoint"],
                        manifest["files"],
                        manifest["runtime"],
                        manifest["private_digest"],
                    ]
                )
            ).hexdigest()
            checks = metadata_at_revision(manifest["inventory"]["checks"], base)
            revision = sha256(
                canonical([base, manifest["inventory"]["source_id"], checks])
            ).hexdigest()
            manifest["inventory"]["source_revision"] = revision
            manifest["inventory"]["checks"] = metadata_at_revision(checks, revision)
            (root / "manifest.json").write_text(json.dumps(manifest))
            (root / "private.json").write_bytes(private_bytes)
            (root / "manifest.mac").unlink()
            root.rename(self.bundles / revision)
            config = assignment(manifest["inventory"])
            rejected = await execute(config, prepare=True, bundle_dir=self.bundles)
            self.assertFalse(rejected["prepared"], rejected)
            self.assertIn(
                "unsupported consumer snapshot format", rejected["diagnostic"]
            )

    async def test_selected_target_schema_schedule_contract_and_membership_stay_exact(
        self,
    ):
        self.source.write_text("""import os
from mondek_runner import App, Environment, Output, Parameter, Target, check, ok
@check(id="selected", outputs=(Output("health", "Health",
    Target(os.environ.get("TEST_TARGET", "stable-target"), "Target")),),
    params={"limit": 10}, parameters={"limit": Parameter("integer", "Limit",
    maximum=int(os.environ.get("TEST_LIMIT", "20")))},
    parameter_contract=os.environ.get("TEST_CONTRACT", "limit.v1"),
    interval_seconds=int(os.environ.get("TEST_INTERVAL", "30")))
def selected(params): return ok("health", "complete")
@check(id="other", expected_keys=("health",))
def other(): return ok("health", "other")
app = App(source_id=os.environ.get("TEST_SOURCE", "ordinary-package"),
    environment=Environment("node"),
    checks=[selected] if os.environ.get("TEST_REMOVE") else [selected, other])
""")
        inventory = await snapshot("ordinary_consumer:app", self.bundles)
        config = assignment(inventory)
        for name, value in (
            ("TEST_TARGET", "changed-target"),
            ("TEST_LIMIT", "30"),
            ("TEST_CONTRACT", "limit.v2"),
            ("TEST_INTERVAL", "60"),
            ("TEST_SOURCE", "changed-source"),
            ("TEST_REMOVE", "1"),
        ):
            with self.subTest(name=name), patch.dict(os.environ, {name: value}):
                rejected = await execute(config, prepare=True, bundle_dir=self.bundles)
                self.assertFalse(rejected["prepared"], rejected)

    async def test_parameter_contract_is_snapshotted_and_checked_when_supplied(self):
        self.source.write_text("""
from mondek_runner import App, Environment, Parameter, check, ok
@check(id="probe", expected_keys=("health",), params={"limit": 80},
       parameters={"limit": Parameter("integer", "Used capacity", unit="percent")},
       parameter_contract="capacity.used-percent.v1", timeout_seconds=2)
def probe(params): return ok("health", str(params["limit"]))
app = App(source_id="ordinary-package", environment=Environment("node"), checks=[probe])
""")
        first = await snapshot("ordinary_consumer:app", self.bundles)
        old = assignment(first)
        self.source.write_text(
            self.source.read_text().replace("used-percent.v1", "used-percent.v2")
        )
        second = await snapshot("ordinary_consumer:app", self.bundles)
        self.assertNotEqual(first["source_revision"], second["source_revision"])
        self.assertEqual(old["parameter_contract"], "capacity.used-percent.v1")
        self.assertEqual(
            second["checks"][0]["parameter_contract"], "capacity.used-percent.v2"
        )
        self.assertTrue((await execute(old, bundle_dir=self.bundles))["complete"])
        old.pop("parameter_contract")  # Older controllers omit this optional field.
        self.assertTrue((await execute(old, bundle_dir=self.bundles))["complete"])
        wrong = {**assignment(second), "parameter_contract": "capacity.used-percent.v3"}
        rejected = await execute(wrong, prepare=True, bundle_dir=self.bundles)
        self.assertFalse(rejected["prepared"])
        self.assertIn("parameter_contract differs", rejected["diagnostic"])

    async def test_catalog_adoption_receipts_do_not_change_immutable_source_identity(
        self,
    ):
        self.source.write_text("""
from mondek_runner import App, Environment, Parameter, check, ok
from mondek_runner.authoring import DiscoveryCatalog
@check(id="selection", expected_keys=("health",),
       parameters={"interface_exclude": Parameter("string", "Exclude")},
       params={"interface_exclude": "lo"},
       parameter_contract="mondek.linux.discovery.v1")
def selection(params):
    return ok("health", "selection measured")
selection.mondek_discovery = DiscoveryCatalog(lambda params: {}, lambda *args: None,
    capability="linux.resources.v1")
app = App(source_id="ordinary-package", environment=Environment("node"),
          checks=[selection])
""")
        first = await snapshot("ordinary_consumer:app", self.bundles)
        key = first["checks"][0]["key"]
        identity = str(uuid.uuid4())
        second = await snapshot(
            "ordinary_consumer:app",
            self.bundles,
            policy_params={key: {"interface_exclude": "lo"}},
            policy_versions={key: {"assignment_id": identity, "generation": 2}},
        )
        third = await snapshot(
            "ordinary_consumer:app",
            self.bundles,
            policy_params={key: {"interface_exclude": "lo"}},
            policy_versions={key: {"assignment_id": identity, "generation": 3}},
        )
        self.assertEqual(first["source_revision"], second["source_revision"])
        self.assertEqual(second["source_revision"], third["source_revision"])
        self.assertEqual(second["catalog_selections"][key]["generation"], 2)
        self.assertEqual(third["catalog_selections"][key]["generation"], 3)
        executable = json.loads(
            (self.bundles / first["source_revision"] / "manifest.json").read_text()
        )
        self.assertNotIn("catalog_selections", executable["inventory"])

    async def test_private_settings_are_frozen_without_public_secret_material(self):
        self.source.write_text("""import os
from mondek_runner import App, Environment, Datasource, check, ok
class Feed(Datasource):
    def __init__(self, endpoint): self.endpoint = endpoint
@check(id="feed", expected_keys=("health",), timeout_seconds=2)
def feed(data: Feed, environment: Environment):
    return ok("health", data.endpoint + "/" + environment.metadata["region"])
app = App(source_id="ordinary-package", environment=Environment("node", metadata={
    "region": os.environ["TEST_PRIVATE_REGION"]}), checks=[feed])
app.register_datasource(Feed, endpoint=os.environ["TEST_PRIVATE_ENDPOINT"])
""")
        with patch.dict(
            os.environ,
            {
                "TEST_PRIVATE_ENDPOINT": "private-old-endpoint",
                "TEST_PRIVATE_REGION": "old-region",
            },
        ):
            first = await snapshot("ordinary_consumer:app", self.bundles)
            config = assignment(first)
        self.assertNotIn("private-old-endpoint", json.dumps(first))
        private_file = self.bundles / first["source_revision"] / "private.json"
        self.assertEqual(private_file.stat().st_mode & 0o777, 0o600)
        with patch.dict(
            os.environ,
            {
                "TEST_PRIVATE_ENDPOINT": "private-new-endpoint",
                "TEST_PRIVATE_REGION": "new-region",
            },
        ):
            second = await snapshot("ordinary_consumer:app", self.bundles)
            old_result = await execute(config, bundle_dir=self.bundles)
            new_result = await execute(assignment(second), bundle_dir=self.bundles)
        self.assertNotEqual(first["source_revision"], second["source_revision"])
        self.assertEqual(
            old_result["results"][0]["summary"], "private-old-endpoint/old-region"
        )
        self.assertEqual(
            new_result["results"][0]["summary"], "private-new-endpoint/new-region"
        )

    async def test_environment_rename_keeps_identity_and_old_assignment_injection(self):
        self.source.write_text("""import os
from mondek_runner import App, Environment, check, ok
@check(id="probe", expected_keys=("health",), timeout_seconds=2)
def probe(environment: Environment):
    return ok("health", environment.id + "/" + environment.name + "/" +
              environment.metadata["region"])
app = App(source_id="ordinary-package", environment=Environment("node-a",
    os.environ["TEST_ENV_LABEL"], {"region": os.environ["TEST_ENV_REGION"]}),
    checks=[probe])
""")
        with patch.dict(
            os.environ, {"TEST_ENV_LABEL": "Production", "TEST_ENV_REGION": "old"}
        ):
            first = await snapshot("ordinary_consumer:app", self.bundles)
            old = assignment(first, generation=7)
            old.pop("environment_label")
            old["environment"] = "Production"  # Older control response shape.
        with patch.dict(
            os.environ, {"TEST_ENV_LABEL": "Renamed", "TEST_ENV_REGION": "new"}
        ):
            second = await snapshot("ordinary_consumer:app", self.bundles)
            prepared = await execute(old, prepare=True, bundle_dir=self.bundles)
            previous = await execute(old, bundle_dir=self.bundles)
            current = await execute(
                assignment(second, generation=8), bundle_dir=self.bundles
            )
        self.assertTrue(prepared["prepared"], prepared)
        self.assertTrue(previous["complete"], previous)
        self.assertTrue(current["complete"], current)
        self.assertEqual(previous["results"][0]["summary"], "node-a/Production/old")
        self.assertEqual(current["results"][0]["summary"], "node-a/Renamed/new")
        self.assertNotEqual(first["source_revision"], second["source_revision"])
        self.assertEqual(
            first["checks"][0]["environment"], second["checks"][0]["environment"]
        )
        self.assertEqual(first["checks"][0]["outputs"][0]["target"]["key"], "node-a")
        self.assertEqual(second["checks"][0]["outputs"][0]["target"]["key"], "node-a")
        self.assertNotIn("region", json.dumps(second))
        self.assertEqual(old["generation"], 7)

    async def test_rejected_source_identity_does_not_leak_candidate_bundles(self):
        state = State(self.root / "state")
        bundles = state.directory / "bundles"
        state.record_inventory(await snapshot("ordinary_consumer:app", bundles))
        try:
            for index in range(3):
                self.source.write_text(
                    SOURCE.replace("ordinary-package", f"wrong-source-{index}")
                )
                runner = Runner(
                    state, "http://local.invalid", consumer="ordinary_consumer:app"
                )
                runner.stopped.set()
                await runner.discover()
                self.assertIn("source_id changed", runner.inventory_error)
                self.assertEqual(
                    len([path for path in bundles.iterdir() if path.is_dir()]), 1
                )
        finally:
            state.close()

    async def test_valid_large_parameter_schema_fits_bounded_worker_input(self):
        self.source.write_text("""
from mondek_runner import App, Environment, Parameter, check, ok
choices = tuple(str(i).zfill(2) + "x" * 2046 for i in range(32))
@check(id="probe",expected_keys=("health",),params={"choice":choices[0]},
       parameters={"choice":Parameter("string","Choice",choices=choices)},
       timeout_seconds=2)
def probe(params): return ok("health","healthy")
app=App(source_id="ordinary-package",environment=Environment("node"),checks=[probe])
""")
        config = assignment(await snapshot("ordinary_consumer:app", self.bundles))
        self.assertGreater(len(json.dumps(config)), 65536)
        prepared = await execute(config, prepare=True, bundle_dir=self.bundles)
        self.assertTrue(prepared["prepared"], prepared)
        self.assertTrue((await execute(config, bundle_dir=self.bundles))["complete"])

    async def test_external_package_discovery_and_exact_execution_without_builtin_edits(
        self,
    ):
        inventory = await snapshot("ordinary_consumer:app", self.bundles)
        self.assertEqual(len(inventory["checks"]), 1)
        self.assertEqual(
            [output["target"]["key"] for output in inventory["checks"][0]["outputs"]],
            ["one", "two"],
        )
        config = assignment(inventory)
        self.assertTrue(
            (await execute(config, prepare=True, bundle_dir=self.bundles))["prepared"]
        )
        outcome = await execute(config, bundle_dir=self.bundles)
        self.assertTrue(outcome["complete"], outcome)
        self.assertEqual(
            [result["summary"] for result in outcome["results"]],
            ["real consumer A", "real consumer B"],
        )
        self.assertTrue(all(result["source_at"] for result in outcome["results"]))
        self.assertEqual(
            inventory, await snapshot("ordinary_consumer:app", self.bundles)
        )
        wrong = {**config, "definition_revision": "f" * 64}
        self.assertFalse((await execute(wrong, bundle_dir=self.bundles))["complete"])

    async def test_failed_upgrade_preserves_snapshot_and_inventory_on_restart(
        self,
    ):
        inventory = await snapshot("ordinary_consumer:app", self.bundles)
        config = assignment(inventory)
        state = State(self.root / "state")
        accepted = state.record_inventory(inventory)
        self.assertEqual(accepted, state.record_inventory(inventory))
        state.adopt(config, 0)
        state.close()
        self.source.write_text("raise RuntimeError('broken upgrade')\n")
        with self.assertRaisesRegex(ValueError, "broken upgrade"):
            await snapshot("ordinary_consumer:app", self.bundles)
        state = State(self.root / "state")
        try:
            self.assertEqual(state.inventory(), accepted)
            self.assertEqual(state.assignments()[config["id"]], config)
            outcome = await execute(config, bundle_dir=self.bundles)
            self.assertTrue(outcome["complete"], outcome)
            self.source.write_text(SOURCE.replace("real consumer A", "new consumer A"))
            updated = await snapshot("ordinary_consumer:app", self.bundles)
            self.assertNotEqual(
                updated["source_revision"], inventory["source_revision"]
            )
            self.assertEqual(state.record_inventory(updated)["inventory_revision"], 2)
            self.assertEqual(
                (await execute(config, bundle_dir=self.bundles))["results"][0][
                    "summary"
                ],
                "real consumer A",
            )
        finally:
            state.close()

    async def test_partial_execution_and_modified_snapshot_fail_closed(self):
        self.source.write_text(
            SOURCE.replace(
                'yield ok("b", "real consumer B")',
                'raise OSError("second datasource failed")',
            )
        )
        inventory = await snapshot("ordinary_consumer:app", self.bundles)
        config = assignment(inventory)
        outcome = await execute(config, bundle_dir=self.bundles)
        self.assertFalse(outcome["complete"])
        self.assertEqual(len(outcome["results"]), 1)
        self.assertIn("second datasource failed", outcome["diagnostic"])
        stored = (
            self.bundles
            / inventory["source_revision"]
            / "ordinary_consumer"
            / "__init__.py"
        )
        stored.write_text(SOURCE)
        outcome = await execute(config, bundle_dir=self.bundles)
        self.assertFalse(outcome["complete"])
        self.assertEqual(outcome["results"], [])
        self.assertIn("source changed", outcome["diagnostic"])

    async def test_inventory_failure_and_lost_reply_do_not_stop_accepted_execution(
        self,
    ):
        state = State(self.root / "state")
        bundles = state.directory / "bundles"
        inventory = await snapshot("ordinary_consumer:app", bundles)
        config = assignment(inventory)
        state.adopt(config, 0)
        state.record_inventory(inventory)
        sent = []

        def offline(url, payload, timeout):
            if url.endswith("/inventory"):
                sent.append(json.loads(json.dumps(payload)))
            raise OSError("lost inventory reply")

        runner = Runner(
            state,
            "http://local.invalid",
            consumer="ordinary_consumer:app",
            transport=offline,
        )
        task = asyncio.create_task(runner.run())
        try:
            async with asyncio.timeout(8):
                while len(state.batch()) < 3 or len(sent) < 2:
                    await asyncio.sleep(0.05)
            self.assertTrue(
                all(report["complete"] for report in state.batch()), state.batch()
            )
            self.assertEqual(
                sent[0]["inventory_revision"], sent[1]["inventory_revision"]
            )
            self.assertEqual(sent[0]["checks"], sent[1]["checks"])
            self.assertEqual(
                len({report["id"] for report in state.batch()}), len(state.batch())
            )
        finally:
            runner.stopped.set()
            await task
            state.close()

    async def test_rejected_inventory_still_delivers_previous_accepted_evidence(self):
        state = State(self.root / "state")
        inventory = await snapshot("ordinary_consumer:app", state.directory / "bundles")
        config = assignment(inventory)
        state.adopt(config, 0)
        state.record_inventory(inventory)
        delivered = []

        def controller(url, payload, timeout):
            if url.endswith("/inventory"):
                raise ValueError("candidate schema conflicts with saved parameters")
            if url.endswith("/control"):
                return {
                    "version": 1,
                    "assignments_authoritative": True,
                    "assignments": [config],
                    "authorized": {config["id"]: 1},
                }
            delivered.extend(payload["reports"])
            return {
                "version": 1,
                "dispositions": [
                    {"id": report["id"], "disposition": "current"}
                    for report in payload["reports"]
                ],
            }

        runner = Runner(
            state,
            "http://local.invalid",
            consumer="ordinary_consumer:app",
            transport=controller,
        )
        task = asyncio.create_task(runner.run())
        try:
            async with asyncio.timeout(5):
                while len(delivered) < 2:
                    await asyncio.sleep(0.05)
            self.assertTrue(all(report["complete"] for report in delivered), delivered)
            self.assertIn("candidate schema conflicts", runner.status()["diagnostic"])
            self.assertTrue(runner.registered.is_set())
        finally:
            runner.stopped.set()
            await task
            state.close()

    async def test_restore_requires_successful_rediscovery_and_persists_new_revision(
        self,
    ):
        state = State(self.root / "state")
        runner = Runner(state, "http://local.invalid", consumer="ordinary_consumer:app")
        task = asyncio.create_task(runner.discover())
        try:
            await asyncio.wait_for(runner.inventory_ready.wait(), 3)
            original = state.inventory()
            config = assignment(original)
            state.adopt(config, 0)
            runner.active = {config["id"]: config}
            # A newer deployment can be discovered locally while the controller
            # has retired this publication and refuses its inventory POST.
            self.source.write_text(SOURCE + "\n# Pending rejected deployment\n")
            cached = state.record_inventory(
                await snapshot("ordinary_consumer:app", runner.bundle_dir)
            )
            runner.inventory = cached
            self.assertEqual(cached["inventory_revision"], 2)
            self.source.write_text("raise RuntimeError('restore import failed')\n")
            response = {
                "assignments": [],
                "authorized": {},
                "assignments_authoritative": True,
                "inventory_refresh": {
                    original["source_id"]: {
                        "after_revision": 1,
                        "lifecycle_revision": 3,
                    }
                },
            }
            runner.reconcile(response)
            async with asyncio.timeout(3):
                while not runner.inventory_error:
                    await asyncio.sleep(0.01)
            self.assertIn("restore import failed", runner.inventory_error)
            refresh_status = runner.status()["inventory_refresh"]
            self.assertEqual(refresh_status["after_revision"], 1)
            self.assertEqual(refresh_status["lifecycle_revision"], 3)
            self.assertEqual(refresh_status["state"], "failed")
            self.assertIsInstance(refresh_status["attempted_at"], str)
            self.assertEqual(state.inventory(), cached)
            self.assertEqual(state.assignments(), {})
            self.assertEqual(runner.active, {})

            # Restore the same code: no artificial deployment edit is required.
            self.source.write_text(SOURCE)
            async with asyncio.timeout(8):
                while state.inventory()["inventory_revision"] == 2:
                    await asyncio.sleep(0.02)
            restored = state.inventory()
            self.assertEqual(restored["inventory_revision"], 3)
            self.assertEqual(restored["restoration_revision"], 3)
            self.assertEqual(restored["source_revision"], original["source_revision"])
            self.assertEqual(restored["checks"], original["checks"])
            self.assertIsNone(runner.inventory_error)
            runner.reconcile(response)  # Lost/replayed control response cannot churn.
            self.assertFalse(runner.inventory_refresh_needed.is_set())
            self.assertNotIn("inventory_refresh", runner.status())
            self.assertEqual(state.assignments(), {})  # Still needs new admission.
        finally:
            runner.stopped.set()
            task.cancel()
            await asyncio.gather(task, return_exceptions=True)
            state.close()
        reopened = State(self.root / "state")
        try:
            self.assertEqual(reopened.inventory(), restored)
        finally:
            reopened.close()

    async def test_refresh_during_inventory_post_keeps_receipt_bound_to_submission(
        self,
    ):
        state = State(self.root / "state")
        inventory = await snapshot("ordinary_consumer:app", state.directory / "bundles")
        original = state.record_inventory(inventory)
        posted = threading.Event()
        release = threading.Event()
        revisions = []

        def controller(url, payload, timeout):
            if url.endswith("/inventory"):
                revisions.append(payload["inventory_revision"])
                if len(revisions) == 1:
                    posted.set()
                    if not release.wait(3):
                        raise TimeoutError("test did not release inventory response")
                return {"inventory_revision": payload["inventory_revision"]}
            return {
                "assignments": [],
                "authorized": {},
                "assignments_authoritative": True,
            }

        runner = Runner(
            state,
            "http://local.invalid",
            consumer="ordinary_consumer:app",
            transport=controller,
        )
        runner.inventory_ready.set()
        task = asyncio.create_task(runner.control())
        try:
            async with asyncio.timeout(3):
                while not posted.is_set():
                    await asyncio.sleep(0.01)
            runner.inventory = state.record_inventory(inventory, minimum_revision=2)
            release.set()
            async with asyncio.timeout(3):
                while runner.inventory_sent_session != (state.session_id, 2):
                    await asyncio.sleep(0.01)
            self.assertEqual(revisions, [original["inventory_revision"], 2])
            self.assertIsNone(runner.inventory_publish_error)
        finally:
            release.set()
            runner.stopped.set()
            await task
            state.close()

    async def test_malformed_refresh_cannot_partially_apply_retirement(self):
        state = State(self.root / "state")
        inventory = await snapshot("ordinary_consumer:app", state.directory / "bundles")
        config = assignment(inventory)
        state.adopt(config, 0)
        state.record_inventory(inventory)
        runner = Runner(state, "http://local.invalid", consumer="ordinary_consumer:app")
        try:
            for bad in (
                None,
                [],
                {"ordinary-package": True},
                {"ordinary-package": 2**63},
                {"ordinary-package": {"after_revision": 1}},
                {"ordinary-package": {"after_revision": True, "lifecycle_revision": 3}},
                {
                    "ordinary-package": {
                        "after_revision": 1,
                        "lifecycle_revision": 2**63 - 1,
                    }
                },
            ):
                with self.assertRaisesRegex(ValueError, "inventory refresh"):
                    runner.reconcile(
                        {
                            "assignments": [],
                            "authorized": {},
                            "assignments_authoritative": True,
                            "inventory_refresh": bad,
                        }
                    )
                self.assertEqual(state.assignments(), {config["id"]: config})
                self.assertEqual(runner.active, {config["id"]: config})
        finally:
            state.close()

    async def test_inventory_refresh_revision_bounds_and_idempotence(self):
        state = State(self.root / "state")
        inventory = await snapshot("ordinary_consumer:app", state.directory / "bundles")
        try:
            state.record_inventory(inventory)
            refreshed = state.record_inventory(inventory, minimum_revision=10)
            self.assertEqual(refreshed["inventory_revision"], 10)
            self.assertEqual(state.record_inventory(inventory), refreshed)
            self.assertEqual(
                state.record_inventory(inventory, minimum_revision=10), refreshed
            )
            for invalid in (True, 0, -1, 2**63 - 1):
                with self.assertRaisesRegex(ValueError, "minimum inventory revision"):
                    state.record_inventory(inventory, minimum_revision=invalid)
                self.assertEqual(state.inventory(), refreshed)
            marked = state.record_inventory(inventory, restoration_revision=3)
            self.assertEqual(marked["inventory_revision"], 11)
            self.assertEqual(marked["restoration_revision"], 3)
            self.assertEqual(state.record_inventory(inventory), marked)
            self.assertEqual(
                state.record_inventory(inventory, restoration_revision=3), marked
            )
            newer = state.record_inventory(inventory, restoration_revision=5)
            self.assertEqual(newer["inventory_revision"], 12)
            self.assertEqual(newer["restoration_revision"], 5)
            for invalid in (True, 0, -1, 2**63 - 1):
                with self.assertRaisesRegex(ValueError, "restoration revision"):
                    state.record_inventory(inventory, restoration_revision=invalid)
                self.assertEqual(state.inventory(), newer)
        finally:
            state.close()

    async def test_cancelled_restore_stops_discovery_retries_and_can_be_requested_again(
        self,
    ):
        state = State(self.root / "state")
        runner = Runner(state, "http://local.invalid", consumer="ordinary_consumer:app")
        retry_waiting = asyncio.Event()
        retry_released = asyncio.Event()

        async def pause(_seconds):
            retry_waiting.set()
            await retry_released.wait()

        runner.pause = pause
        with patch("mondek_runner.runtime.snapshot", wraps=snapshot) as discover:
            task = asyncio.create_task(runner.discover())
            try:
                await asyncio.wait_for(runner.inventory_ready.wait(), 3)
                response = {
                    "assignments": [],
                    "authorized": {},
                    "assignments_authoritative": True,
                    "inventory_refresh": {
                        "ordinary-package": {
                            "after_revision": 1,
                            "lifecycle_revision": 3,
                        }
                    },
                }
                self.source.write_text("raise RuntimeError('failed restoration')\n")
                runner.reconcile(response)
                await asyncio.wait_for(retry_waiting.wait(), 3)
                self.assertEqual(discover.await_count, 2)
                runner.reconcile({**response, "inventory_refresh": {}})
                self.assertNotIn("inventory_refresh", runner.status())
                self.source.write_text(SOURCE)
                retry_released.set()
                await asyncio.sleep(0.02)
                self.assertEqual(discover.await_count, 2)
                self.assertEqual(state.inventory()["inventory_revision"], 1)
                self.assertFalse(runner.inventory_refresh_needed.is_set())
                runner.reconcile(
                    {
                        **response,
                        "inventory_refresh": {
                            "ordinary-package": {
                                "after_revision": 1,
                                "lifecycle_revision": 5,
                            }
                        },
                    }
                )
                async with asyncio.timeout(3):
                    while state.inventory()["inventory_revision"] == 1:
                        await asyncio.sleep(0.01)
                self.assertEqual(discover.await_count, 3)
                self.assertEqual(state.inventory()["inventory_revision"], 2)
                self.assertEqual(state.inventory()["restoration_revision"], 5)
            finally:
                runner.stopped.set()
                task.cancel()
                await asyncio.gather(task, return_exceptions=True)
                state.close()


if __name__ == "__main__":
    unittest.main()
