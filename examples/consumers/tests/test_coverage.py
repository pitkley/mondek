# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""The consumer declares intended scopes before selecting its own work."""

from __future__ import annotations

import unittest
from unittest.mock import Mock, patch

from mondek_examples import coverage
from mondek_examples.grouped import Sample

AT = "2009-09-01T08:00:00.000000Z"


def catalogue(app):
    return app.coverage_metadata(app.metadata("a" * 64))


class CoverageConsumerTests(unittest.TestCase):
    def test_node_a_publishes_the_never_installed_node_b_and_both_services(self):
        app = coverage.make_app("node-a")
        selected = app.metadata("a" * 64)
        self.assertEqual(
            {row["key"] for row in selected}, {"root-disk-node-a", "local-collection"}
        )
        candidates = {row["key"]: row for row in catalogue(app)["candidates"]}
        self.assertEqual(len(candidates), 5)
        absent = candidates["root-disk-node-b"]
        self.assertFalse(absent["selected"])
        self.assertTrue(absent["scope_resolved"])
        self.assertEqual(absent["environment"], "production")
        self.assertEqual(
            absent["outputs"][0]["target"], coverage.ROSTER["node-b"].to_dict()
        )
        self.assertTrue(absent["exclusion_reason"])
        services = [
            row
            for row in candidates.values()
            if row["label"] == "Search service capacity"
        ]
        self.assertEqual(
            {row["environment"] for row in services}, {"staging", "production"}
        )
        self.assertTrue(
            all(not row["selected"] and row["scope_resolved"] for row in services)
        )

    def test_subjectless_shared_runner_keeps_local_template_unbound(self):
        app = coverage.make_app("service-a")
        candidates = catalogue(app)["candidates"]
        template = next(row for row in candidates if row["key"] == "local-collection")
        self.assertFalse(template["selected"])
        self.assertFalse(template["scope_resolved"])
        self.assertIsNone(template["environment"])
        self.assertIsNone(template["outputs"][0]["target"])
        self.assertTrue(template["scope_reason"])
        self.assertNotIn(coverage.LocalSample, app._providers)

    def test_service_grants_select_only_supported_environments_without_hiding_intent(
        self,
    ):
        for access in (("staging",), ("staging", "production")):
            with self.subTest(access=access):
                app = coverage.make_app("service-b", access=access)
                self.assertEqual(
                    {row["environment"] for row in app.metadata("a" * 64)}, set(access)
                )
                services = [
                    row
                    for row in catalogue(app)["candidates"]
                    if row["label"] == "Search service capacity"
                ]
                self.assertEqual(len(services), 2)
                self.assertEqual(
                    {row["environment"] for row in services if row["selected"]},
                    set(access),
                )
                self.assertTrue(
                    all(
                        row["outputs"][0]["target"] == coverage.SERVICE.to_dict()
                        for row in services
                    )
                )

    def test_duplicate_service_observers_keep_the_same_scope_and_independent_settings(
        self,
    ):
        first = coverage.make_app("service-a", "http://target:8080")
        second = coverage.make_app("service-b", "http://target:8080/")
        one, two = first.metadata("a" * 64)[0], second.metadata("a" * 64)[0]
        for field in ("key", "environment", "outputs"):
            self.assertEqual(one[field], two[field])
        self.assertNotEqual(first.runner.id, second.runner.id)
        self.assertNotEqual(
            first.arguments(one["key"], {})["source"].observer,
            second.arguments(two["key"], {})["source"].observer,
        )

    def test_private_connection_settings_do_not_appear_in_public_catalogue(self):
        first = coverage.make_app("service-a", "https://first.invalid/private-path")
        second = coverage.make_app("service-a", "https://second.invalid/different-path")
        self.assertEqual(catalogue(first), catalogue(second))
        self.assertNotIn("private-path", repr(catalogue(first)))

    def test_discovery_does_not_construct_selected_or_excluded_datasources(self):
        with (
            patch.object(
                coverage.LocalSample,
                "__init__",
                side_effect=AssertionError("constructed"),
            ),
            patch.object(
                coverage.ServiceSample,
                "__init__",
                side_effect=AssertionError("constructed"),
            ),
        ):
            for observer in ("node-a", "node-b", "service-a"):
                self.assertEqual(
                    len(catalogue(coverage.make_app(observer))["candidates"]), 5
                )

    def test_failure_is_a_measurement_while_unavailable_does_not_invent_health(self):
        for used, health in ((40, "OK"), (90, "WARN"), (95, "CRIT")):
            with self.subTest(used=used):
                result = coverage.capacity(Sample(used, False, True, AT), "Subject")
                self.assertEqual(result.health, health)
                self.assertEqual(result.source_at, AT)
                self.assertEqual(result.value, used)
        result = coverage.capacity(Sample(99, False, False, AT), "Subject")
        self.assertEqual(result.health, "UNKNOWN")
        self.assertEqual(result.source_at, AT)
        self.assertIsNone(result.value)

    def test_network_error_has_no_invented_source_timestamp(self):
        source = Mock()
        source.read.side_effect = OSError("connection unavailable")
        app = coverage.make_app("node-a")
        for result in (
            coverage.root_disk(source, app.runner),
            coverage.local_collection(source),
            coverage.service_capacity(source, coverage.PRODUCTION),
        ):
            self.assertEqual(result.health, "UNKNOWN")
            self.assertIsNone(result.source_at)

    def test_each_service_environment_reads_its_own_fixture_identity(self):
        source = coverage.ServiceSample("service-b", "http://target:8080")
        with patch.object(coverage, "FixtureData") as fixture:
            sample = Sample(40, False, True, AT)
            fixture.return_value.read.return_value = sample
            self.assertIs(source.read(coverage.PRODUCTION), sample)
            fixture.assert_called_once_with(
                "coverage-service-b-production", "elasticsearch", "http://target:8080"
            )

    def test_misspelled_observer_or_access_fails_before_publication(self):
        with self.assertRaisesRegex(ValueError, "coverage observer"):
            coverage.make_app("node-typo")
        with self.assertRaisesRegex(ValueError, "coverage access"):
            coverage.make_app("service-a", access=("production-typo",))


if __name__ == "__main__":
    unittest.main()
