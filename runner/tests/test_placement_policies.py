# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Placement selects declared coverage without turning outages into removal."""

from __future__ import annotations

import asyncio
import json
import os
import sys
import tempfile
import unittest
import uuid
from pathlib import Path
from typing import Annotated
from unittest.mock import patch

from mondek_runner import (
    App,
    Binding,
    Capability,
    Datasource,
    DatasourceFactory,
    Environment,
    FromFactory,
    Output,
    Placement,
    PlacementContext,
    RunnerContext,
    Target,
    bundle,
    check,
    ok,
)
from mondek_runner.runtime import Runner, execute
from mondek_runner.state import State

STAGING = Environment("staging", "Staging")
PRODUCTION = Environment("production", "Production")
NODE = Target("node-a", "Node A", "host")


class Logs(Datasource):
    placement = Placement(requires=("logs",))


class Database(Datasource):
    placement = Placement(requires=("database",))


class StagingOnly(Datasource):
    placement = Placement(monitored_environments=("staging",))


class ProductionOnly(Datasource):
    placement = Placement(monitored_environments=("production",))


class ProductionFactory(DatasourceFactory):
    placement = Placement(monitored_environments=("production",))

    def new(self) -> StagingOnly:
        return StagingOnly()


def observer_policy(context: PlacementContext) -> str | None:
    return (
        None
        if context.runner.id == "assigned-observer"
        else "Another observer owns this shard"
    )


class PolicyDatasource(Datasource):
    placement = Placement(policy=observer_policy)


@check(id="logs", expected_keys=("health",), environments=(STAGING, PRODUCTION))
def logs_check(logs: Logs):
    return ok("health", "Logs queried")


class PlacementPolicyTests(unittest.TestCase):
    def app(self, checks, *, runner=None, environment=PRODUCTION):
        return App(
            source_id="policy-tests",
            runner=runner or RunnerContext("observer"),
            environment=environment,
            checks=checks,
        )

    def ordinary(self, *, placement, outputs=(), environments=()):
        @check(
            id="ordinary",
            expected_keys=() if outputs else ("health",),
            placement=placement,
            outputs=outputs,
            environments=environments,
        )
        def ordinary():
            return ok("health", "Collected")

        return ordinary

    def test_scoped_access_selects_per_environment_without_constructing_dependencies(
        self,
    ):
        runner = RunnerContext(
            "observer", capabilities=(Capability("logs", environments=("staging",)),)
        )
        app = self.app([logs_check], runner=runner)
        selected = app.selected_bindings()
        self.assertEqual(
            [binding.environment.id for binding in selected.values()], ["staging"]
        )
        self.assertTrue(runner.supports("logs", STAGING))
        self.assertFalse(runner.supports("logs", PRODUCTION))
        summary = json.dumps(app.placement_summary())
        self.assertIn("production", summary)
        self.assertIn("logs", summary)
        # Selected declarations still need a provider; placement grants are not
        # a replacement for dependency configuration or successful collection.
        with self.assertRaisesRegex(ValueError, "unregistered"):
            app.metadata("a" * 64)
        app.register_datasource(Logs)
        self.assertEqual(
            [entry["environment"] for entry in app.metadata("a" * 64)], ["staging"]
        )

    def test_unrestricted_grants_remain_compatible_and_conflicting_grants_fail(self):
        for declaration in ("logs", Capability("logs")):
            runner = RunnerContext("observer", capabilities=(declaration, declaration))
            self.assertTrue(runner.supports("logs", STAGING))
            self.assertTrue(runner.supports("logs", PRODUCTION))
            self.assertEqual(
                len(self.app([logs_check], runner=runner).selected_bindings()), 2
            )
        stage = Capability("logs", environments=("staging",))
        prod = Capability("logs", environments=("production",))
        self.assertEqual(
            len(RunnerContext("observer", capabilities=(stage, stage)).capabilities), 1
        )
        for grants in ((stage, prod), (prod, stage), (stage, "logs"), ("logs", stage)):
            with self.subTest(grants=grants), self.assertRaises(ValueError):
                RunnerContext("observer", capabilities=grants)

    def test_capability_and_constraint_declarations_are_bounded_and_typed(self):
        for name in ("", "contains spaces", "a" * 129):
            with self.subTest(name=name), self.assertRaises(ValueError):
                Capability(name)
        for environments in ((), [], ["staging"], "staging", ("",), ("a" * 129,)):
            with self.subTest(environments=environments), self.assertRaises(ValueError):
                Capability("logs", environments=environments)
            with self.subTest(environments=environments), self.assertRaises(ValueError):
                Placement(monitored_environments=environments)
        for locality in (None, True, "local", "same-target"):
            with self.subTest(locality=locality), self.assertRaises(ValueError):
                Placement(locality=locality)
        with self.assertRaises(ValueError):
            RunnerContext("observer", local_environment="production")
        with self.assertRaises(ValueError):
            Placement(policy="allow")
        for policy in (lambda: None, lambda context, required: None):
            with self.subTest(policy=policy), self.assertRaises(ValueError):
                Placement(policy=policy)

    def test_replacing_runner_context_replaces_cached_scoped_access(self):
        original = RunnerContext(
            "observer", capabilities=(Capability("logs", environments=("staging",)),)
        )
        replacement = RunnerContext(
            "observer", capabilities=(Capability("logs", environments=("production",)),)
        )
        app = self.app([logs_check], runner=original)
        for observer, expected, excluded in (
            (original, STAGING, PRODUCTION),
            (replacement, PRODUCTION, STAGING),
        ):
            app.runner = observer
            for _ in range(3):
                self.assertTrue(app.runner.supports("logs", expected))
                self.assertFalse(app.runner.supports("logs", excluded))
                self.assertEqual(
                    [
                        binding.environment.id
                        for binding in app.selected_bindings().values()
                    ],
                    [expected.id],
                )
        self.assertTrue(original.supports("logs", STAGING))
        self.assertFalse(original.supports("logs", PRODUCTION))

    def test_mixed_datasources_require_access_to_the_same_monitored_environment(self):
        @check(
            id="mixed", expected_keys=("health",), environments=(STAGING, PRODUCTION)
        )
        def mixed(logs: Logs, database: Database):
            return ok("health", "Compared")

        split_access = RunnerContext(
            "observer",
            capabilities=(
                Capability("logs", environments=("staging",)),
                Capability("database", environments=("production",)),
            ),
        )
        self.assertEqual(self.app([mixed], runner=split_access).metadata("a" * 64), [])
        production_access = RunnerContext(
            "observer",
            capabilities=(
                "logs",
                Capability("database", environments=("production",)),
            ),
        )
        app = self.app([mixed], runner=production_access)
        self.assertEqual(
            [binding.environment.id for binding in app.selected_bindings().values()],
            ["production"],
        )

    def test_source_scope_contract_cannot_silently_crop_declared_coverage(self):
        @check(
            id="invalid-scope",
            expected_keys=("health",),
            environments=(STAGING, PRODUCTION),
            placement=Placement(runner_contexts=("another-observer",)),
        )
        def invalid_scope(source: StagingOnly):
            raise AssertionError("Cannot collect an unsupported scope")

        with self.assertRaises(ValueError):
            self.app([invalid_scope]).metadata("a" * 64)
        selected = self.app([Binding(invalid_scope, environment=STAGING)])
        self.assertEqual(selected.metadata("a" * 64), [])

    def test_empty_datasource_and_factory_scope_intersections_are_configuration_errors(
        self,
    ):
        @check(id="incompatible", expected_keys=("health",))
        def incompatible(first: StagingOnly, second: ProductionOnly):
            raise AssertionError("No common monitored environment")

        @check(id="incompatible-factory", expected_keys=("health",))
        def incompatible_factory(
            source: Annotated[StagingOnly, FromFactory(ProductionFactory)],
        ):
            raise AssertionError("Factory cannot satisfy datasource contract")

        for function in (incompatible, incompatible_factory):
            with self.subTest(check=function.__name__), self.assertRaises(ValueError):
                self.app([function]).metadata("a" * 64)

    def test_same_environment_matches_ids_without_restricting_remote_subjects(self):
        service = Target("service:billing", "Billing", "service")
        function = self.ordinary(
            placement=Placement(locality="same-environment"),
            outputs=(Output("health", target=service),),
        )
        runner = RunnerContext(
            "node-a",
            local_environment=Environment("production", "Renamed production"),
            target=NODE,
        )
        metadata = self.app([function], runner=runner).metadata("a" * 64)
        self.assertEqual(metadata[0]["outputs"][0]["target"], service.to_dict())
        remote = self.app([function], runner=runner, environment=STAGING)
        self.assertEqual(remote.metadata("a" * 64), [])
        self.assertEqual(
            remote.placement_summary()["excluded_checks"][0]["reason"],
            "Requires execution in staging; runner executes in production",
        )

    def test_missing_local_declarations_fail_for_otherwise_eligible_runner(self):
        function = self.ordinary(
            placement=Placement(requires=("local-files",), locality="same-environment")
        )
        self.assertEqual(self.app([function]).metadata("a" * 64), [])
        with self.assertRaises(ValueError):
            self.app(
                [function],
                runner=RunnerContext("node-a", capabilities=("local-files",)),
            ).metadata("a" * 64)
        host_only = self.ordinary(placement=Placement(locality="runner-target"))
        with self.assertRaises(ValueError):
            self.app(
                [host_only],
                runner=RunnerContext("node-a", local_environment=PRODUCTION),
            ).metadata("a" * 64)

    def test_runner_target_matches_key_and_kind_for_every_resolved_output(self):
        runner = RunnerContext("node-a", local_environment=PRODUCTION, target=NODE)
        own_alias = Target(NODE.key, "Renamed node", NODE.kind)
        function = self.ordinary(
            placement=Placement(locality="runner-target"),
            outputs=(Output("first", target=own_alias), Output("second")),
        )
        metadata = self.app([function], runner=runner).metadata("a" * 64)
        self.assertEqual(len(metadata[0]["outputs"]), 2)
        for wrong_target in (
            Target("node-b", "Other node"),
            Target(NODE.key, NODE.label, "volume"),
        ):
            function = self.ordinary(
                placement=Placement(locality="runner-target"),
                outputs=(
                    Output("first", target=own_alias),
                    Output("second", target=wrong_target),
                ),
            )
            excluded = self.app([function], runner=runner)
            self.assertEqual(excluded.metadata("a" * 64), [])
            self.assertEqual(
                excluded.placement_summary()["excluded_checks"][0]["reason"],
                f"Requires execution on target {wrong_target.kind}:{wrong_target.key}; "
                f"runner target is {NODE.kind}:{NODE.key}",
            )
        # Matching subject alone is insufficient: local observations cannot be
        # relabeled as a different monitored environment.
        own = self.ordinary(placement=Placement(locality="runner-target"))
        self.assertEqual(
            self.app([own], runner=runner, environment=STAGING).metadata("a" * 64), []
        )

    def test_explicit_scope_does_not_implicitly_change_environment_subject_into_host(
        self,
    ):
        runner = RunnerContext("node-a", local_environment=PRODUCTION, target=NODE)
        function = self.ordinary(
            placement=Placement(locality="runner-target"),
            environments=(PRODUCTION,),
        )
        self.assertEqual(self.app([function], runner=runner).metadata("a" * 64), [])
        metadata = self.app([Binding(function, target=NODE)], runner=runner).metadata(
            "a" * 64
        )
        self.assertEqual(metadata[0]["outputs"][0]["target"], NODE.to_dict())

    def test_policy_receives_resolved_inputs_and_preserves_exclusion_reason(self):
        contexts = []
        service = Target("api", "API", "service")

        def policy(context: PlacementContext) -> str | None:
            contexts.append(context)
            return "Observer is outside the declared application shard"

        function = self.ordinary(
            placement=Placement(policy=policy),
            outputs=(Output("health", target=service),),
        )
        app = self.app([Binding(function, target=NODE)])
        self.assertEqual(app.metadata("a" * 64), [])
        context = contexts[0]
        self.assertIsInstance(context, PlacementContext)
        self.assertEqual(context.check_id, "ordinary")
        self.assertEqual(context.environment.id, "production")
        self.assertEqual(context.runner.id, "observer")
        self.assertEqual(context.targets, (service,))
        self.assertIn("declared application shard", json.dumps(app.placement_summary()))

    def test_custom_policy_cannot_override_builtin_exclusions(self):
        def policy(context):
            raise AssertionError("Builtin exclusion must run first")

        function = self.ordinary(placement=Placement(requires=("logs",), policy=policy))
        self.assertEqual(self.app([function]).metadata("a" * 64), [])

    def test_check_and_datasource_policies_must_both_permit_the_invocation(self):
        @check(
            id="policies",
            expected_keys=("health",),
            placement=Placement(policy=lambda context: None),
        )
        def policies(source: PolicyDatasource):
            return ok("health", "Collected")

        app = self.app([policies])
        self.assertEqual(app.metadata("a" * 64), [])
        self.assertIn("owns this shard", json.dumps(app.placement_summary()))
        assigned = self.app([policies], runner=RunnerContext("assigned-observer"))
        assigned.register_datasource(PolicyDatasource)
        self.assertEqual(len(assigned.metadata("a" * 64)), 1)

    def test_policy_errors_and_invalid_results_reject_complete_inventory(self):
        for result in (True, False, 1, {}, "", "  ", "x" * 201, "é" * 101):
            function = self.ordinary(
                placement=Placement(policy=lambda context, result=result: result)
            )
            with self.subTest(result=result), self.assertRaises(ValueError):
                self.app([function]).metadata("a" * 64)

        def broken(context):
            raise RuntimeError("Broken placement policy")

        function = self.ordinary(placement=Placement(policy=broken))
        with self.assertRaises((ValueError, RuntimeError)):
            self.app([function]).metadata("a" * 64)
        allowed = self.ordinary(placement=Placement(policy=lambda context: None))
        self.assertEqual(len(self.app([allowed]).metadata("a" * 64)), 1)
        boundary = self.ordinary(placement=Placement(policy=lambda context: "é" * 100))
        self.assertEqual(self.app([boundary]).metadata("a" * 64), [])

    def test_policy_input_mutation_cannot_change_deployment_or_later_invocations(self):
        scope = Environment("production", metadata={"owners": ["team-a"]})
        observed = []

        def policy(context):
            observed.append(list(context.environment.metadata["owners"]))
            context.environment.metadata["owners"].append("injected")
            context.runner.local_environment.metadata["owners"].append("injected")
            return None

        function = self.ordinary(placement=Placement(policy=policy))
        app = self.app(
            [function],
            environment=scope,
            runner=RunnerContext("node-a", local_environment=scope, target=NODE),
        )
        app.metadata("a" * 64)
        app.metadata("a" * 64)
        self.assertTrue(observed)
        self.assertTrue(all(owners == ["team-a"] for owners in observed))
        self.assertEqual(scope.metadata, {"owners": ["team-a"]})


SOURCE = """import json
import os
from mondek_runner import (
    App, Capability, Environment, Placement, RunnerContext, check, ok,
)

def policy(context):
    return None

@check(id="scope", expected_keys=("health",), timeout_seconds=3,
    environments=(Environment("production"), Environment("staging")),
    placement=Placement(requires=("logs",), locality="same-environment", policy=policy))
def scoped(environment: Environment, runner: RunnerContext):
    return ok("health", json.dumps({
        "environment": environment.id,
        "local_environment": runner.local_environment.id,
        "local_owner": runner.local_environment.metadata["owner"],
        "production_access": runner.supports("logs", Environment("production")),
        "staging_access": runner.supports("logs", Environment("staging")),
    }))

app = App(source_id="placement-policy-probe", checks=[scoped],
    runner=RunnerContext("shared-observer",
        local_environment=Environment(os.environ["POLICY_LOCAL_ENV"],
            metadata={"owner": os.environ["POLICY_OWNER"]}),
        capabilities=(
            Capability("logs", environments=(os.environ["POLICY_ACCESS"],)),)))
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


class PlacementPolicySnapshotTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        package = self.root / "site" / "placement_policy_probe"
        package.mkdir(parents=True)
        self.source = package / "__init__.py"
        self.source.write_text(SOURCE)
        self.bundles = self.root / "bundles"
        self.addCleanup(setattr, sys, "path", list(sys.path))
        self.addCleanup(setattr, sys, "dont_write_bytecode", sys.dont_write_bytecode)
        environment = patch.dict(
            os.environ,
            {
                "PYTHONPATH": str(package.parent)
                + os.pathsep
                + os.environ.get("PYTHONPATH", ""),
                "POLICY_LOCAL_ENV": "production",
                "POLICY_ACCESS": "production",
                "POLICY_OWNER": "original-owner",
            },
        )
        environment.start()
        self.addCleanup(environment.stop)

    async def test_worker_uses_frozen_scope_and_grants_after_deployment_inputs_change(
        self,
    ):
        inventory = await bundle.snapshot("placement_policy_probe:app", self.bundles)
        self.assertEqual(
            [entry["environment"] for entry in inventory["checks"]], ["production"]
        )
        self.assertNotIn("original-owner", json.dumps(inventory))
        config = assignment(inventory)
        os.environ.update(
            POLICY_LOCAL_ENV="staging",
            POLICY_ACCESS="staging",
            POLICY_OWNER="replacement-owner",
        )
        prepared = await execute(config, prepare=True, bundle_dir=self.bundles)
        self.assertTrue(prepared["prepared"], prepared)
        result = await execute(config, bundle_dir=self.bundles)
        self.assertTrue(result["complete"], result)
        self.assertEqual(
            json.loads(result["results"][0]["summary"]),
            {
                "environment": "production",
                "local_environment": "production",
                "local_owner": "original-owner",
                "production_access": True,
                "staging_access": False,
            },
        )

    async def test_failed_policy_deployment_preserves_inventory_and_executable_coverage(
        self,
    ):
        state = State(str(self.root / "state"))
        self.addCleanup(state.close)
        runner = Runner(
            state, "http://127.0.0.1:1", consumer="placement_policy_probe:app"
        )
        runner.stopped.set()
        await asyncio.wait_for(runner.discover(), timeout=20)
        original = runner.inventory
        self.assertIsNotNone(original)
        config = assignment(original)
        runner.active[config["id"]] = config
        self.source.write_text(
            SOURCE.replace(
                "def policy(context):\n    return None",
                "def policy(context):\n"
                '    raise ValueError("Broken replacement policy")',
            )
        )
        await asyncio.wait_for(runner.discover(), timeout=20)
        self.assertEqual(runner.inventory, original)
        self.assertIn("last successful snapshot retained", runner.inventory_error)
        result = await execute(config, bundle_dir=runner.bundle_dir)
        self.assertTrue(result["complete"], result)
        self.assertEqual(
            json.loads(result["results"][0]["summary"])["local_environment"],
            "production",
        )


if __name__ == "__main__":
    unittest.main()
