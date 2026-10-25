# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Source-declared scope and execution eligibility stay distinct and durable."""

from __future__ import annotations

import asyncio
import json
import os
import sys
import tempfile
import unittest
import uuid
from pathlib import Path
from types import ModuleType
from typing import Annotated
from unittest.mock import patch

from mondek_runner import (
    App,
    Binding,
    Datasource,
    DatasourceFactory,
    Environment,
    FromFactory,
    Output,
    Placement,
    RunnerContext,
    Target,
    authoring,
    bundle,
    check,
    ok,
)
from mondek_runner.runtime import Runner, execute
from mondek_runner.state import State

STAGING = Environment("staging", "Staging", metadata={"private": "stage-secret"})
PRODUCTION = Environment(
    "production", "Production", metadata={"private": "prod-secret"}
)


class Files(Datasource):
    placement = Placement(
        requires=("local-files",), runner_contexts=("node-a", "node-b")
    )
    constructed = 0

    def __init__(self, secret: str):
        Files.constructed += 1
        self.secret = secret


class FilesFactory(DatasourceFactory):
    placement = Placement(requires=("network",), runner_contexts=("node-b", "node-c"))
    constructed = 0

    def __init__(self, prefix: str):
        FilesFactory.constructed += 1
        self.prefix = prefix

    def new(self, suffix: str) -> Files:
        return Files(self.prefix + suffix)


class Missing(Datasource):
    pass


@check(
    id="combined",
    expected_keys=("health",),
    placement=Placement(requires=("processes",), runner_contexts=("node-b", "node-d")),
)
def combined(source: Annotated[Files, FromFactory(FilesFactory, "suffix")]):
    return ok("health", source.secret)


class PlacementTests(unittest.TestCase):
    def app(self, checks, *, runner=None, environment=PRODUCTION):
        return App(
            source_id="placement-tests",
            runner=runner or RunnerContext("node-b"),
            environment=environment,
            checks=checks,
        )

    def test_invalid_context_and_placement_declarations_fail_before_discovery(self):
        for identity in ("", "space is invalid", "a" * 129):
            with self.subTest(identity=identity), self.assertRaises(ValueError):
                RunnerContext(identity)
        for values in (("",), ("space is invalid",), ("a" * 129,)):
            with self.subTest(values=values), self.assertRaises(ValueError):
                RunnerContext("node-a", capabilities=values)
            with self.subTest(values=values), self.assertRaises(ValueError):
                Placement(requires=values)
            with self.subTest(values=values), self.assertRaises(ValueError):
                Placement(runner_contexts=values)
        for declaration in ("all", True, {"requires": ["local-files"]}):
            with self.subTest(declaration=declaration), self.assertRaises(ValueError):
                check(id="invalid", expected_keys=("health",), placement=declaration)

    def test_capabilities_union_and_context_intersection_include_factory_rules(self):
        Files.constructed = FilesFactory.constructed = 0
        all_capabilities = ("processes", "local-files", "network")
        for capabilities in ((), ("processes", "local-files"), all_capabilities):
            for identity in ("node-a", "node-b", "node-c", "node-d"):
                with self.subTest(identity=identity, capabilities=capabilities):
                    app = self.app(
                        [combined],
                        runner=RunnerContext(identity, capabilities=capabilities),
                    )
                    eligible = identity == "node-b" and capabilities == all_capabilities
                    self.assertEqual(set(app.bindings), {"combined"})
                    self.assertEqual(
                        set(app.selected_bindings()),
                        {"combined"} if eligible else set(),
                    )
                    if eligible:
                        app.register_datasource_factory(FilesFactory, prefix="private-")
                    metadata = app.metadata("a" * 64)
                    self.assertEqual(len(metadata), int(eligible))
                    self.assertNotIn("private-", json.dumps(metadata))
        self.assertEqual(Files.constructed, 0)
        self.assertEqual(FilesFactory.constructed, 0)

    def test_selected_missing_provider_fails_the_complete_inventory(self):
        @check(id="ordinary", expected_keys=("health",))
        def ordinary():
            return ok("health", "healthy")

        @check(id="missing", expected_keys=("health",))
        def missing(source: Missing):
            raise AssertionError("discovery must not execute the check")

        app = self.app([ordinary, missing])
        with self.assertRaises(ValueError):
            app.metadata("a" * 64)
        eligible_factory = self.app(
            [combined],
            runner=RunnerContext(
                "node-b", capabilities=("processes", "local-files", "network")
            ),
        )
        with self.assertRaises(ValueError):
            eligible_factory.metadata("a" * 64)

    def test_excluded_checks_need_no_provider_and_cannot_execute(self):
        @check(
            id="elsewhere",
            expected_keys=("health",),
            placement=Placement(runner_contexts=("other-node",)),
        )
        def elsewhere(source: Missing):
            raise AssertionError("excluded code must not execute")

        app = self.app([elsewhere])
        self.assertEqual(app.metadata("a" * 64), [])
        self.assertEqual(set(app.bindings), {"elsewhere"})
        self.assertEqual(app.selected_bindings(), {})
        with self.assertRaises(ValueError):
            app.arguments("elsewhere", {})
        with self.assertRaises(ValueError):
            app.arguments("elsewhere", {}, instantiate=False)
        summary = json.dumps(app.placement_summary())
        self.assertIn("elsewhere", summary)
        self.assertIn("other-node", summary)

    def test_contradictory_context_constraints_are_errors_even_on_excluded_runners(
        self,
    ):
        @check(
            id="contradiction",
            expected_keys=("health",),
            placement=Placement(runner_contexts=("elsewhere",)),
        )
        def contradiction(source: Files):
            raise AssertionError("must not execute")

        for runner in (RunnerContext("node-a"), RunnerContext("unrelated")):
            with self.subTest(runner=runner.id), self.assertRaises(ValueError):
                self.app([contradiction], runner=runner).metadata("a" * 64)

    def test_scoped_plain_functions_expand_stably_across_order_label_and_additions(
        self,
    ):
        def inventory(environments):
            @check(
                id="remote-status", expected_keys=("health",), environments=environments
            )
            def remote_status(environment: Environment, runner: RunnerContext):
                return ok("health", environment.id + ":" + runner.id)

            app = App(
                source_id="scoped",
                runner=RunnerContext("dedicated"),
                checks=[remote_status],
            )
            entries = app.metadata("a" * 64)
            return app, {entry["environment"]: entry for entry in entries}

        initial_app, initial = inventory((STAGING, PRODUCTION))
        _, reordered = inventory((PRODUCTION, STAGING))
        _, extended = inventory((Environment("development"), PRODUCTION, STAGING))
        _, renamed = inventory((Environment("staging", "Renamed staging"), PRODUCTION))
        self.assertEqual(len(initial_app.bindings), 2)
        self.assertEqual(len({entry["key"] for entry in initial.values()}), 2)
        for environment, entry in initial.items():
            for later in (reordered, extended, renamed):
                self.assertEqual(later[environment]["key"], entry["key"])
            arguments = initial_app.arguments(entry["key"], {})
            self.assertEqual(arguments["environment"].id, environment)
            self.assertEqual(arguments["runner"].id, "dedicated")
            self.assertNotIn("secret", json.dumps(entry))

    def test_scoped_keys_do_not_change_when_second_environment_is_added(self):
        @check(id="first", expected_keys=("health",), environments=(STAGING,))
        def one():
            return ok("health", "one")

        @check(
            id="first", expected_keys=("health",), environments=(STAGING, PRODUCTION)
        )
        def two():
            return ok("health", "two")

        first = self.app([one]).metadata("a" * 64)[0]
        later = next(
            entry
            for entry in self.app([two]).metadata("b" * 64)
            if entry["environment"] == "staging"
        )
        self.assertEqual(first["key"], later["key"])

    def test_binding_selects_one_declared_scope_and_rejects_an_undeclared_scope(self):
        @check(
            id="multi", expected_keys=("health",), environments=(STAGING, PRODUCTION)
        )
        def multi():
            return ok("health", "scope")

        app = self.app([Binding(multi, environment=PRODUCTION)])
        entries = app.metadata("a" * 64)
        self.assertEqual(len(entries), 1)
        self.assertEqual(entries[0]["environment"], "production")
        full = self.app([multi]).metadata("a" * 64)
        production = next(
            entry for entry in full if entry["environment"] == "production"
        )
        self.assertEqual(entries[0]["key"], production["key"])
        with self.assertRaises(ValueError):
            self.app([Binding(multi, environment=Environment("unknown"))]).metadata(
                "a" * 64
            )

    def test_scope_declaration_rejects_duplicate_and_malformed_environments(self):
        for environments in (
            (STAGING, STAGING),
            (STAGING, "production"),
            [],
            {},
            "",
            0,
        ):
            with self.subTest(environments=environments), self.assertRaises(ValueError):

                @check(
                    id="invalid", expected_keys=("health",), environments=environments
                )
                def invalid():
                    return ok("health", "must be rejected")

                self.app([invalid]).metadata("a" * 64)

    def test_capability_and_context_lists_have_validated_512_item_bounds(self):
        identities = tuple(f"capability-{index}" for index in range(512))
        context = RunnerContext("node-a", capabilities=identities)
        self.assertEqual(set(context.capabilities), set(identities))
        self.assertEqual(set(Placement(requires=identities).requires), set(identities))
        self.assertEqual(
            set(Placement(runner_contexts=identities).runner_contexts), set(identities)
        )
        for invalid in ([], "local-files", identities + ("overflow",)):
            with self.subTest(invalid=type(invalid)), self.assertRaises(ValueError):
                RunnerContext("node-a", capabilities=invalid)
            with self.subTest(invalid=type(invalid)), self.assertRaises(ValueError):
                Placement(requires=invalid)
            with self.subTest(invalid=type(invalid)), self.assertRaises(ValueError):
                Placement(runner_contexts=invalid)
        with self.assertRaises(ValueError):
            Placement(runner_contexts=())
        canonical = RunnerContext("node-a", capabilities=("z", "a", "z"))
        self.assertEqual(canonical.capabilities, ("a", "z"))

    def test_expansion_keeps_long_component_ids_distinct_and_enforces_total_bound(self):
        long_environments = (Environment("e" * 127 + "a"), Environment("e" * 127 + "b"))

        @check(id="x" * 128, expected_keys=("health",), environments=long_environments)
        def long_identity():
            return ok("health", "long identities")

        entries = self.app([long_identity]).metadata("a" * 64)
        self.assertEqual(len({entry["key"] for entry in entries}), 2)
        self.assertTrue(all(len(entry["key"]) <= 128 for entry in entries))

        @check(
            id="many",
            expected_keys=("health",),
            environments=tuple(Environment(f"scope-{index}") for index in range(512)),
        )
        def many():
            return ok("health", "many environments")

        self.assertEqual(len(self.app([many]).metadata("a" * 64)), 512)
        with self.assertRaises(ValueError):
            self.app([many, long_identity]).metadata("a" * 64)

    def test_failed_expanded_addition_leaves_every_registered_binding_unchanged(self):
        @check(
            id="scoped", expected_keys=("health",), environments=(STAGING, PRODUCTION)
        )
        def scoped():
            return ok("health", "scope")

        @check(id="ordinary", expected_keys=("health",))
        def ordinary():
            return ok("health", "ordinary")

        applications = {
            "capacity exceeded after first expansion": self.app(
                [Binding(ordinary, key=f"ordinary-{index}") for index in range(511)]
            ),
            "collision in second environment": self.app(
                [Binding(scoped, environment=PRODUCTION)]
            ),
        }
        for reason, app in applications.items():
            with self.subTest(reason=reason):
                original = dict(app.bindings)
                with self.assertRaises(ValueError):
                    app.add(scoped)
                self.assertEqual(app.bindings, original)
                for key, binding in original.items():
                    self.assertIs(app.bindings[key], binding)

    def test_shared_placement_annotations_are_cached_without_caching_eligibility(self):
        capabilities = ("processes", "local-files", "network")
        eligible = RunnerContext("node-b", capabilities=capabilities)
        app = self.app(
            [Binding(combined, key=f"combined-{index}") for index in range(500)],
            runner=eligible,
        )
        with patch.object(
            authoring, "get_type_hints", wraps=authoring.get_type_hints
        ) as hints:
            self.assertEqual(len(app.selected_bindings()), 500)
            self.assertEqual(hints.call_count, 1)
            app.runner = RunnerContext("node-b", capabilities=("local-files",))
            self.assertEqual(app.selected_bindings(), {})
            app.runner = RunnerContext("node-a", capabilities=capabilities)
            self.assertEqual(app.selected_bindings(), {})
            app.runner = eligible
            self.assertEqual(len(app.selected_bindings()), 500)
            self.assertEqual(hints.call_count, 1)
        self.assertEqual(len(app.bindings), 500)

    def test_default_subject_distinguishes_local_observer_and_remote_scope(self):
        @check(id="local", expected_keys=("health",))
        def local():
            return ok("health", "local")

        @check(id="scope", expected_keys=("health",), environments=(PRODUCTION,))
        def scope():
            return ok("health", "remote")

        host = Target("node:observer", "Observer host")
        observer = RunnerContext("observer", target=host)
        local_target = self.app([local], runner=observer).metadata("a" * 64)[0][
            "outputs"
        ][0]["target"]
        self.assertEqual(local_target, host.to_dict())
        scoped_target = self.app([scope], runner=observer).metadata("a" * 64)[0][
            "outputs"
        ][0]["target"]
        self.assertEqual(
            scoped_target, Target("production", "Production", "environment").to_dict()
        )
        implicit_target = self.app([local], runner=RunnerContext("observer")).metadata(
            "a" * 64
        )[0]["outputs"][0]["target"]
        self.assertEqual(implicit_target, scoped_target)
        legacy = App(source_id="legacy", environment=PRODUCTION, checks=[local])
        self.assertEqual(
            legacy.metadata("a" * 64)[0]["outputs"][0]["target"],
            Target("production", "Production").to_dict(),
        )

    def test_selected_unscoped_check_still_requires_a_monitored_environment(self):
        @check(id="unscoped", expected_keys=("health",))
        def unscoped():
            return ok("health", "unscoped")

        app = App(
            source_id="missing-scope",
            runner=RunnerContext("observer"),
            checks=[unscoped],
        )
        with self.assertRaisesRegex(ValueError, "environment"):
            app.metadata("a" * 64)

    def test_connectivity_errors_do_not_change_declared_eligibility(self):
        class Unreachable(Datasource):
            placement = Placement(requires=("network",))

            def __init__(self):
                raise ConnectionError("datasource is offline")

        @check(id="unreachable", expected_keys=("health",))
        def unreachable(source):
            raise AssertionError("constructor fails before check execution")

        unreachable.__annotations__ = {"source": Unreachable}
        app = self.app(
            [unreachable], runner=RunnerContext("observer", capabilities=("network",))
        )
        app.register_datasource(Unreachable)
        self.assertEqual(
            [entry["key"] for entry in app.metadata("a" * 64)], ["unreachable"]
        )
        with self.assertRaisesRegex(ConnectionError, "offline"):
            app.arguments("unreachable", {})
        self.assertEqual(set(app.selected_bindings()), {"unreachable"})

    def test_module_discovery_preserves_plain_decorated_functions_and_scopes(self):
        module = ModuleType("placement_discovery")

        @check(
            id="discovered",
            expected_keys=("health",),
            environments=(STAGING, PRODUCTION),
        )
        def discovered():
            return ok("health", "found")

        discovered.__module__ = module.__name__
        module.discovered = discovered
        app = self.app([module])
        self.assertEqual(
            {entry["environment"] for entry in app.metadata("a" * 64)},
            {"staging", "production"},
        )

    def test_runner_injection_is_distinct_from_remote_monitored_scope(self):
        remote = Target("remote-service", "Remote service", "service")

        @check(
            id="remote",
            outputs=(Output("health", target=remote),),
            environments=(PRODUCTION,),
        )
        def remote_status(environment: Environment, runner: RunnerContext):
            return ok("health", f"{environment.id} from {runner.id}")

        observer = RunnerContext(
            "observer",
            "Dedicated observer",
            capabilities=("prometheus",),
            target=Target("node:observer", "Observer node"),
        )
        app = App(source_id="remote", runner=observer, checks=[remote_status])
        metadata = app.metadata("a" * 64)[0]
        arguments = app.arguments(metadata["key"], {})
        self.assertEqual(arguments["environment"], PRODUCTION)
        self.assertEqual(arguments["runner"], observer)
        self.assertEqual(metadata["outputs"][0]["target"]["key"], "remote-service")
        self.assertEqual(metadata["environment"], "production")


SOURCE = """import json
import os
from mondek_runner import (
    App, Datasource, Environment, Placement, RunnerContext, Target, check, ok,
)

class SecretSource(Datasource):
    placement = Placement(requires=("local-files",))
    def __init__(self, secret): self.secret = secret

@check(id="selected", expected_keys=("health",), timeout_seconds=3,
       environments=(Environment("production"),),
       placement=Placement(requires=("processes",), runner_contexts=("node-a",)))
def selected(source: SecretSource, environment: Environment, runner: RunnerContext):
    return ok("health", json.dumps({"scope": environment.id, "runner": runner.id,
        "capabilities": sorted(runner.capabilities), "target": runner.target.key,
        "private": source.secret}))

@check(id="excluded", expected_keys=("health",), timeout_seconds=3,
       placement=Placement(runner_contexts=("remote-only",)))
def excluded(): raise AssertionError("excluded code cannot execute")

app = App(source_id="placement-probe", environment=Environment("default-scope"),
    runner=RunnerContext(os.environ["PLACEMENT_RUNNER"],
        capabilities=tuple(os.environ["PLACEMENT_CAPABILITIES"].split(",")),
        target=Target(os.environ["PLACEMENT_TARGET"], "Local node")),
    checks=[selected, excluded])
app.register_datasource(SecretSource, secret=os.environ["PLACEMENT_SECRET"])
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
        "expected_keys": [output["key"] for output in entry["outputs"]],
    }


class PlacementSnapshotTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        package = self.root / "site" / "placement_probe"
        package.mkdir(parents=True)
        self.source = package / "__init__.py"
        self.source.write_text(SOURCE)
        self.bundles = self.root / "bundles"
        original_path = list(sys.path)
        original_bytecode = sys.dont_write_bytecode
        self.addCleanup(setattr, sys, "path", original_path)
        self.addCleanup(setattr, sys, "dont_write_bytecode", original_bytecode)
        values = {
            "PYTHONPATH": str(package.parent)
            + os.pathsep
            + os.environ.get("PYTHONPATH", ""),
            "PLACEMENT_RUNNER": "node-a",
            "PLACEMENT_CAPABILITIES": "processes,local-files",
            "PLACEMENT_TARGET": "node:original",
            "PLACEMENT_SECRET": "private-original",
        }
        environment = patch.dict(os.environ, values)
        environment.start()
        self.addCleanup(environment.stop)

    async def test_frozen_runner_context_and_private_settings_survive_new_deployment(
        self,
    ):
        inventory = await bundle.snapshot("placement_probe:app", self.bundles)
        self.assertEqual(len(inventory["checks"]), 1)
        self.assertNotIn("private-original", json.dumps(inventory))
        config = assignment(inventory)
        os.environ.update(
            PLACEMENT_RUNNER="other-node",
            PLACEMENT_CAPABILITIES="network",
            PLACEMENT_TARGET="node:replacement",
            PLACEMENT_SECRET="private-replacement",
        )
        prepared = await execute(config, prepare=True, bundle_dir=self.bundles)
        self.assertTrue(prepared["prepared"], prepared)
        result = await execute(config, bundle_dir=self.bundles)
        self.assertTrue(result["complete"], result)
        self.assertEqual(
            json.loads(result["results"][0]["summary"]),
            {
                "scope": "production",
                "runner": "node-a",
                "capabilities": ["local-files", "processes"],
                "target": "node:original",
                "private": "private-original",
            },
        )
        self.assertEqual(os.environ["PLACEMENT_RUNNER"], "other-node")

    async def test_forged_execution_of_an_excluded_check_is_rejected(self):
        inventory = await bundle.snapshot("placement_probe:app", self.bundles)
        config = assignment(inventory)
        config["source_key"] = "excluded"
        prepared = await execute(config, prepare=True, bundle_dir=self.bundles)
        self.assertFalse(prepared["prepared"], prepared)
        result = await execute(config, bundle_dir=self.bundles)
        self.assertFalse(result["complete"], result)
        self.assertNotIn("excluded code cannot execute", result["diagnostic"])

    async def test_empty_selection_exports_bounded_exclusion_diagnostics(self):
        os.environ["PLACEMENT_RUNNER"] = "no-matching-checks"
        inventory = await bundle.snapshot("placement_probe:app", self.bundles)
        self.assertEqual(inventory["checks"], [])
        placement = inventory["placement"]
        self.assertEqual(placement["runner_context"], "no-matching-checks")
        self.assertEqual(set(placement["capabilities"]), {"processes", "local-files"})
        self.assertEqual(len(placement["excluded_checks"]), 2)
        self.assertTrue(
            all(
                entry["key"] and entry["reason"]
                for entry in placement["excluded_checks"]
            )
        )
        self.assertNotIn("private-original", json.dumps(inventory))

    async def test_broken_discovery_retains_previous_inventory_and_executable_source(
        self,
    ):
        state = State(str(self.root / "state"))
        self.addCleanup(state.close)
        runner = Runner(state, "http://127.0.0.1:1", consumer="placement_probe:app")
        runner.stopped.set()
        await asyncio.wait_for(runner.discover(), timeout=20)
        original = runner.inventory
        self.assertIsNotNone(original)
        config = assignment(original)
        runner.active[config["id"]] = config
        broken_versions = (
            SOURCE + '\nraise ValueError("broken deployment")\n',
            SOURCE.replace(
                "app.register_datasource(SecretSource, "
                'secret=os.environ["PLACEMENT_SECRET"])',
                "",
            ),
        )
        for source in broken_versions:
            with self.subTest(source=source[-100:]):
                self.source.write_text(source)
                await asyncio.wait_for(runner.discover(), timeout=20)
                self.assertEqual(runner.inventory, original)
                self.assertIn(
                    "last successful snapshot retained", runner.inventory_error
                )
                result = await execute(config, bundle_dir=runner.bundle_dir)
                self.assertTrue(result["complete"], result)
                self.assertEqual(
                    json.loads(result["results"][0]["summary"])["runner"], "node-a"
                )


if __name__ == "__main__":
    unittest.main()
