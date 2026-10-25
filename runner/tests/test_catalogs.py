# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Dynamic membership is discovered once, persisted, and frozen for execution."""

import asyncio
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from mondek_runner import App, Binding, Environment, Parameter, check, ok
from mondek_runner.bundle import snapshot
from mondek_runner.catalogs import DiscoveryCatalog, materialize, prepare
from mondek_runner.runtime import Runner
from mondek_runner.state import State


def app_for(observed, *, fail=False):
    @check(
        id="policy",
        expected_keys=("health",),
        params={"exclude": ""},
        parameters={"exclude": Parameter("string", "Exclude")},
        parameter_contract="catalog-test.v1",
    )
    def policy(params):
        return ok("health", "policy")

    def discover(params):
        if fail:
            raise OSError("secret should not appear in diagnostics")
        return observed

    def bind(key, descriptor, present):
        @check(id="resource." + key, expected_keys=("health",))
        def resource():
            return ok("health", str((descriptor, present)))

        return Binding(resource)

    policy.mondek_discovery = DiscoveryCatalog(
        discover,
        bind,
        select=lambda key, descriptor, params: key != params["exclude"],
        interval_seconds=1,
        grace_seconds=10,
    )
    return App(
        source_id="catalog-test", environment=Environment("local"), checks=[policy]
    )


class CatalogTests(unittest.TestCase):
    def test_disappearance_grace_failure_retention_reappearance_and_selection(self):
        initial = app_for({"one": {"path": "/one"}, "two": {"path": "/two"}})
        first = prepare(initial, {}, {}, 100)
        missing = app_for({"two": {"path": "/two"}})
        second = prepare(missing, first["state"], {}, 101)
        self.assertFalse(missing._catalogs["policy"]["one"]["present"])
        self.assertIn("resource.one", missing.bindings)
        failed = app_for({}, fail=True)
        third = prepare(failed, second["state"], {}, 109)
        self.assertIn("resource.one", failed.bindings)
        self.assertNotIn("secret", json.dumps(third["errors"]))
        self.assertEqual(third["state"]["policy"]["one"]["missing_since"], 109)
        recovered = app_for({"two": {"path": "/two"}})
        fourth = prepare(recovered, third["state"], {}, 115)
        self.assertIn("resource.one", recovered.bindings)
        retired = app_for({"two": {"path": "/two"}})
        fifth = prepare(retired, fourth["state"], {}, 119)
        self.assertNotIn("resource.one", retired.bindings)
        returned = app_for({"one": {"path": "/one"}, "two": {"path": "/two"}})
        sixth = prepare(returned, fifth["state"], {"policy": {"exclude": "two"}}, 120)
        self.assertIn("resource.one", returned.bindings)
        self.assertNotIn("resource.two", returned.bindings)
        self.assertEqual(set(sixth["state"]["policy"]), {"one"})
        # Active policy input never rewrites the source's published defaults.
        self.assertEqual(returned.metadata("revision")[0]["params"], {"exclude": ""})

    def test_noop_frozen_data_and_replay_never_calls_discovery(self):
        first = app_for({"one": {"path": "/one"}})
        state = prepare(first, {}, {}, 100)
        second = app_for({"one": {"path": "/one"}})
        prepare(second, state["state"], {}, 200)
        self.assertEqual(first.private_settings(), second.private_settings())
        replay = app_for({}, fail=True)
        materialize(replay, first._catalogs)
        replay.restore_private_settings(first.private_settings())
        self.assertEqual(first.metadata("revision"), replay.metadata("revision"))

    def test_invalid_parameters_and_oversized_evidence_fail_closed(self):
        changed = prepare(
            app_for({"one": {}}), {}, {"policy": {"old_field": True}}, 100
        )
        self.assertIn("one", changed["state"]["policy"])
        self.assertIn("incompatible", changed["errors"][0])
        app = app_for({str(i): {} for i in range(4097)})
        result = prepare(app, {}, {}, 100)
        self.assertTrue(result["errors"])
        self.assertEqual(set(app.bindings), {"policy"})


SOURCE = """import json, os
from pathlib import Path
from mondek_runner import App, Binding, Environment, Parameter, check, ok
from mondek_runner.catalogs import DiscoveryCatalog
@check(id="policy", expected_keys=("health",), params={"exclude": ""},
       parameters={"exclude": Parameter("string", "Exclude")},
       parameter_contract="catalog-test.v1")
def policy(params): return ok("health", "policy")
def discover(params):
    return json.loads(Path(os.environ["CATALOG_TEST_FILE"]).read_text())
def bind(key, descriptor, present):
    @check(id="resource." + key, expected_keys=("health",))
    def resource(): return ok("health", descriptor["value"])
    return Binding(resource)
policy.mondek_discovery = DiscoveryCatalog(discover, bind,
    select=lambda key, descriptor, params: key != params["exclude"],
    interval_seconds=1, grace_seconds=10)
app = App(source_id="catalog-test", environment=Environment("local"), checks=[policy])
"""


class CatalogProcessTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        package = self.root / "site" / "catalog_probe"
        package.mkdir(parents=True)
        (package / "__init__.py").write_text(SOURCE)
        self.evidence = self.root / "evidence.json"
        self.evidence.write_text('{"one": {"value": "frozen"}}')
        self.environment = patch.dict(
            os.environ,
            {
                "PYTHONPATH": str(package.parent)
                + os.pathsep
                + os.environ.get("PYTHONPATH", ""),
                "CATALOG_TEST_FILE": str(self.evidence),
            },
        )
        self.environment.start()
        self.addCleanup(self.environment.stop)

    async def test_snapshot_noop_and_frozen_worker_with_unavailable_discovery(self):
        from test_construction_environment import assignment

        from mondek_runner.runtime import execute

        first = await snapshot(
            "catalog_probe:app", self.root / "bundles", include_discovery=True
        )
        second = await snapshot(
            "catalog_probe:app",
            self.root / "bundles",
            discovery_state=first["discovery"]["state"],
            include_discovery=True,
        )
        self.assertEqual(first["inventory"], second["inventory"])
        inventory = first["inventory"]
        self.evidence.unlink()
        task = assignment(
            {
                **inventory,
                "checks": [
                    item
                    for item in inventory["checks"]
                    if item["key"] == "resource.one"
                ],
            }
        )
        result = await execute(task, bundle_dir=self.root / "bundles")
        self.assertTrue(result["complete"], result)
        self.assertEqual(result["results"][0]["summary"], "frozen")

    async def test_runtime_periodic_discovery_and_restart_preserve_membership(self):
        state = State(self.root / "state")
        runner = Runner(state, "http://local.invalid", consumer="catalog_probe:app")
        task = asyncio.create_task(runner.discover())
        try:
            await asyncio.wait_for(runner.inventory_ready.wait(), 5)
            initial = runner.inventory["inventory_revision"]
            self.evidence.write_text(
                '{"one": {"value": "frozen"}, "two": {"value": "new"}}'
            )
            async with asyncio.timeout(5):
                while len(runner.inventory["checks"]) != 3:
                    await asyncio.sleep(0.05)
            self.assertGreater(runner.inventory["inventory_revision"], initial)
        finally:
            task.cancel()
            await asyncio.gather(task, return_exceptions=True)
            state.close()
        self.evidence.write_text("{}")
        restored = State(self.root / "state")
        runner = Runner(restored, "http://local.invalid", consumer="catalog_probe:app")
        task = asyncio.create_task(runner.discover())
        try:
            await asyncio.wait_for(runner.inventory_ready.wait(), 5)
            self.assertEqual(len(runner.inventory["checks"]), 3)
            self.assertFalse(runner.discovery["state"]["policy"]["one"]["present"])
        finally:
            task.cancel()
            await asyncio.gather(task, return_exceptions=True)
            restored.close()

    async def test_first_snapshot_timeout_recovers_without_operator_refresh(self):
        state = State(self.root / "state")
        runner = Runner(state, "http://local.invalid", consumer="catalog_probe:app")
        attempts = 0

        async def first_times_out(*args, **kwargs):
            nonlocal attempts
            attempts += 1
            if attempts == 1:
                raise TimeoutError("discovery worker timed out")
            return await snapshot(*args, **kwargs)

        with (
            patch("mondek_runner.runtime.snapshot", first_times_out),
            patch("mondek_runner.runtime.DISCOVERY_RETRY_SECONDS", 0.1),
        ):
            task = asyncio.create_task(runner.discover())
            try:
                await asyncio.wait_for(runner.inventory_ready.wait(), 5)
                self.assertIsNone(runner.inventory)
                self.assertIn(
                    "last successful snapshot retained", runner.inventory_error
                )
                async with asyncio.timeout(5):
                    while runner.inventory is None:
                        await asyncio.sleep(0.01)
                self.assertEqual(attempts, 2)
                self.assertIsNone(runner.inventory_error)
                self.assertIsNone(state.get("diagnostic"))
            finally:
                task.cancel()
                await asyncio.gather(task, return_exceptions=True)
                state.close()
