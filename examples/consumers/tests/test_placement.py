# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Placement selects local dependencies before any dependency construction."""

from __future__ import annotations

import unittest
from dataclasses import replace
from unittest.mock import patch

from mondek_runner import Output, Target
from mondek_examples import placement


class PlacementExampleTests(unittest.TestCase):
    def test_nodes_share_production_but_measure_their_own_distinct_hosts(self) -> None:
        targets = set()
        for observer in ("node-a", "node-b"):
            with self.subTest(observer=observer):
                app = placement.make_app(observer)
                self.assertEqual(len(app.bindings), 3)
                self.assertEqual(len(app.selected_bindings()), 1)
                metadata = app.metadata("a" * 64)
                self.assertEqual(len(metadata), 1)
                self.assertEqual(metadata[0]["environment"], "production")
                targets.add(metadata[0]["outputs"][0]["target"]["key"])
        self.assertEqual(targets, {"node:node-a", "node:node-b"})

    def test_one_shared_runner_observes_staging_and_production(self) -> None:
        app = placement.make_app("shared-services", "http://local.invalid")
        metadata = app.metadata("a" * 64)
        self.assertEqual(len(metadata), 2)
        self.assertEqual(
            {item["environment"] for item in metadata}, {"staging", "production"}
        )
        self.assertEqual(len({item["key"] for item in metadata}), 2)
        self.assertEqual(
            len({item["outputs"][0]["target"]["key"] for item in metadata}), 2
        )
        self.assertEqual(
            {
                (
                    item["outputs"][0]["target"]["key"],
                    item["outputs"][0]["target"]["kind"],
                )
                for item in metadata
            },
            {("staging", "environment"), ("production", "environment")},
        )
        self.assertTrue(
            all(
                binding.function is placement.service_readiness
                for binding in app.selected_bindings().values()
            )
        )
        for key, binding in app.selected_bindings().items():
            with self.subTest(environment=binding.environment):
                self.assertEqual(
                    app.arguments(key, {})["environment"], binding.environment
                )

    def test_shared_runner_with_staging_access_keeps_both_source_declarations(
        self,
    ) -> None:
        app = placement.make_app(
            "shared-services", "http://local.invalid", ("staging",)
        )
        self.assertEqual(len(app.bindings), 3)
        self.assertEqual(
            [item["environment"] for item in app.metadata("a" * 64)], ["staging"]
        )
        reasons = [
            item["reason"] for item in app.placement_summary()["excluded_checks"]
        ]
        self.assertTrue(
            any(
                "production" in reason and "service-query" in reason
                for reason in reasons
            )
        )

    def test_node_locality_rejects_mislabelled_environment_or_host(self) -> None:
        for override in (
            {"environment": placement.STAGING},
            {"target": Target("node:node-b", "Node B", "host")},
            {
                "outputs": (
                    Output("capacity", target=Target("node:node-b", "Node B", "host")),
                )
            },
        ):
            with self.subTest(override=override):
                app = placement.make_app("node-a")
                app.bindings["root-disk"] = replace(
                    app.bindings["root-disk"], **override
                )
                self.assertEqual(app.selected_bindings(), {})

    def test_excluded_unregistered_datasource_does_not_block_node_discovery(
        self,
    ) -> None:
        # The ordinary node deployment has no URL and no SharedHTTP registration.
        app = placement.make_app("node-a")
        with patch.object(
            placement.SharedHTTP, "__init__", side_effect=AssertionError("constructed")
        ):
            self.assertEqual(len(app.metadata("a" * 64)), 1)
            arguments = app.arguments(
                next(iter(app.selected_bindings())),
                {"warn_percent": 90, "crit_percent": 95},
            )
        self.assertIsInstance(arguments["filesystem"], placement.LocalFilesystem)

    def test_selected_datasource_without_local_settings_is_an_error(self) -> None:
        with self.assertRaisesRegex(ValueError, "unregistered"):
            placement.make_app("shared-services").metadata("a" * 64)

    def test_discovery_never_constructs_even_selected_datasources(self) -> None:
        app = placement.make_app("shared-services", "http://local.invalid")
        with patch.object(
            placement.SharedHTTP, "__init__", side_effect=AssertionError("constructed")
        ):
            self.assertEqual(len(app.metadata("a" * 64)), 2)

    def test_disk_boundaries_and_visibility_are_distinct(self) -> None:
        source = placement.LocalFilesystem()
        params = {"warn_percent": 90, "crit_percent": 95}
        for used, health in ((89.9, "OK"), (90, "WARN"), (95, "CRIT")):
            with (
                self.subTest(used=used),
                patch.object(source, "used_percent", return_value=used),
            ):
                result = placement.root_disk(source, params)
                self.assertEqual(result.health, health)
                self.assertEqual(result.value, used)
                self.assertIsNotNone(result.source_at)
        with patch.object(source, "used_percent", side_effect=PermissionError):
            result = placement.root_disk(source, params)
        self.assertEqual(result.health, "UNKNOWN")
        self.assertIsNone(result.source_at)

    def test_http_failure_is_measured_but_connection_failure_is_unavailable(
        self,
    ) -> None:
        source = placement.SharedHTTP("http://local.invalid")
        for status, health in ((200, "OK"), (503, "CRIT")):
            with (
                self.subTest(status=status),
                patch.object(source, "status", return_value=status),
            ):
                result = placement.service_readiness(source, placement.STAGING)
                self.assertEqual(result.health, health)
                self.assertIsNotNone(result.source_at)
        with patch.object(source, "status", side_effect=OSError):
            result = placement.service_readiness(source, placement.PRODUCTION)
        self.assertEqual(result.health, "UNKNOWN")
        self.assertIsNone(result.source_at)

    def test_unknown_runner_context_fails_before_discovery(self) -> None:
        with self.assertRaisesRegex(ValueError, "runner context"):
            placement.make_app("typo-node-a")


if __name__ == "__main__":
    unittest.main()
