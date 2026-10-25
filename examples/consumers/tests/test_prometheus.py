# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Explicit Prometheus membership, original scrape age and bounded collection."""

from __future__ import annotations

import copy
import json
import os
import tempfile
import unittest
import urllib.error
import urllib.parse
from datetime import UTC, datetime
from pathlib import Path
from unittest.mock import MagicMock, patch

from mondek_runner import Environment, Target
from mondek_runner.bundle import snapshot
from mondek_runner.runtime import execute

from mondek_examples import monitoring, prometheus

SAMPLED = datetime(2009, 9, 15, tzinfo=UTC)
SETTINGS = {
    "url": "http://prometheus:9090",
    "targets": {
        "target:8080": {
            "key": "monitoring-target",
            "label": "Local scrape target",
            "kind": "service",
        },
        "second:9090": {
            "key": "second-target",
            "label": "Second target",
            "kind": "service",
        },
    },
}


def series(identity="target:8080", values=None):
    return {
        "metric": {"instance": identity},
        "values": [[SAMPLED.timestamp(), "1"]] if values is None else values,
    }


def response(*items):
    return json.dumps(
        {"status": "success", "data": {"resultType": "matrix", "result": list(items)}}
    ).encode()


class ParserTests(unittest.TestCase):
    def test_latest_real_sample_retains_its_original_age(self):
        raw = response(
            series(values=[[SAMPLED.timestamp() - 10, "0"], [SAMPLED.timestamp(), "1"]])
        )
        self.assertEqual(
            prometheus.parse_samples(raw, "instance"),
            {"target:8080": (1, "2009-09-15T00:00:00.000000Z")},
        )

    def test_duplicate_or_absent_identity_is_ambiguous_even_for_empty_series(self):
        for items in (
            (series(), series()),
            (series(values=[]), series()),
            ({"metric": {"job": "same-name"}, "values": []},),
            (series(identity=""),),
        ):
            with self.subTest(items=items), self.assertRaises(ValueError):
                prometheus.parse_samples(response(*items), "instance")

    def test_malformed_nonbinary_and_nonfinite_samples_fail_closed(self):
        for values in (
            [[SAMPLED.timestamp(), "NaN"]],
            [[SAMPLED.timestamp(), "Inf"]],
            [[SAMPLED.timestamp(), "2"]],
            [[SAMPLED.timestamp(), 1]],
            [[True, "1"]],
            [[1e300, "1"]],
            [[float("nan"), "1"]],
            [[10**100, "1"]],
            [[SAMPLED.timestamp(), "1"], [SAMPLED.timestamp() - 1, "0"]],
            [[SAMPLED.timestamp()]],
            "malformed",
        ):
            with self.subTest(values=values), self.assertRaises(ValueError):
                prometheus.parse_samples(response(series(values=values)), "instance")

    def test_response_kind_warnings_and_resource_bounds_are_checked(self):
        for raw in (
            b"[]",
            b'{"status":"success","data":{"resultType":"vector","result":[]}}',
            b'{"status":"success","warnings":["partial"],"data":{"resultType":"matrix","result":[]}}',
            b'{"status":"success","status":"error"}',
            b"x" * (prometheus.MAX_RESPONSE_BYTES + 1),
            response(*[series() for _ in range(513)]),
            response(series(values=[[SAMPLED.timestamp(), "1"]] * 1025)),
        ):
            with self.subTest(size=len(raw)), self.assertRaises(ValueError):
                prometheus.parse_samples(raw, "instance")

    def test_http_request_has_exact_query_deadline_and_read_bound(self):
        datasource = prometheus.Prometheus(
            "http://unused.invalid/base/", 'up{job="local"}[30s]', "instance"
        )
        opened = MagicMock()
        opened.__enter__.return_value.read.return_value = response(series())
        with patch.object(
            prometheus.urllib.request, "urlopen", return_value=opened
        ) as request:
            datasource.collect()
        url = urllib.parse.urlsplit(request.call_args.args[0])
        self.assertEqual(url.path, "/base/api/v1/query")
        self.assertEqual(
            urllib.parse.parse_qs(url.query),
            {"query": ['up{job="local"}[30s]'], "timeout": ["2s"]},
        )
        self.assertEqual(request.call_args.kwargs, {"timeout": 3})
        opened.__enter__.return_value.read.assert_called_once_with(256 * 1024 + 1)

    def test_queries_cannot_replace_scrape_age_with_evaluation_timestamps(self):
        for query in ("up", "(up)[30s:1s]", "timestamp(up)", "up[30s] + 1"):
            with (
                self.subTest(query=query),
                self.assertRaisesRegex(ValueError, "raw metric range selector"),
            ):
                prometheus.Prometheus("http://unused.invalid", query, "instance")


class ConsumerTests(unittest.IsolatedAsyncioTestCase):
    async def test_changed_series_binding_gets_a_new_revision_and_old_snapshot_keeps_its_series(
        self,
    ):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            package = root / "site" / "prometheus_binding_probe"
            package.mkdir(parents=True)
            (package / "__init__.py").write_text("""import os
from mondek_examples.prometheus import Prometheus, app_from_settings
Prometheus.collect = lambda self: {
    "old:9090": (1, "2009-09-15T00:00:00.000000Z"),
    "new:9090": (0, "2009-09-15T00:00:00.000000Z"),
}
app = app_from_settings(os.environ["MONDEK_PROMETHEUS_SETTINGS"])
""")
            distribution = package.parent / "prometheus_binding_probe-1.0.dist-info"
            distribution.mkdir()
            (distribution / "METADATA").write_text(
                "Name: prometheus-binding-probe\nVersion: 1.0\n"
            )
            bundles = root / "bundles"
            target = {"key": "stable-target", "label": "Same target", "kind": "service"}
            first_settings = SETTINGS | {"targets": {"old:9090": target}}
            second_settings = SETTINGS | {"targets": {"new:9090": target}}

            def config(inventory):
                item = inventory["checks"][0]
                return item | {
                    "id": "4848eeb0-d58b-4335-9e3c-afbd1ed33daf",
                    "kind": "python",
                    "generation": 1,
                    "source_key": item["key"],
                    "source_id": inventory["source_id"],
                    "source_revision": inventory["source_revision"],
                    "expected_keys": [output["key"] for output in item["outputs"]],
                }

            with patch.dict(
                os.environ,
                {
                    "PYTHONPATH": str(package.parent)
                    + os.pathsep
                    + os.environ.get("PYTHONPATH", ""),
                    "MONDEK_PROMETHEUS_SETTINGS": json.dumps(first_settings),
                },
            ):
                first = await snapshot("prometheus_binding_probe:app", bundles)
                with patch.dict(
                    os.environ,
                    {"MONDEK_PROMETHEUS_SETTINGS": json.dumps(second_settings)},
                ):
                    second = await snapshot("prometheus_binding_probe:app", bundles)
                    old_result = await execute(config(first), bundle_dir=bundles)
                    new_result = await execute(config(second), bundle_dir=bundles)
            self.assertNotEqual(first["source_revision"], second["source_revision"])
            self.assertEqual(
                first["checks"][0]["outputs"], second["checks"][0]["outputs"]
            )
            self.assertNotIn("old:9090", json.dumps(first))
            self.assertNotIn("new:9090", json.dumps(second))
            self.assertTrue(old_result["complete"], old_result)
            self.assertTrue(new_result["complete"], new_result)
            self.assertEqual(old_result["results"][0]["health"], "OK")
            self.assertEqual(new_result["results"][0]["health"], "CRIT")

    async def test_up_zero_measures_scrape_failure_without_claiming_service_health(
        self,
    ):
        app = prometheus.app_from_settings(json.dumps(SETTINGS))
        source = app.arguments("prometheus-up", {}, instantiate=True)["prometheus"]
        self.assertEqual(source.query, "up[30s]")
        self.assertEqual(source.identity_label, "instance")
        with patch.object(
            source,
            "collect",
            return_value={"target:8080": (0, "2009-09-15T00:00:00.000000Z")},
        ):
            results = [
                item async for item in app.bindings["prometheus-up"].function(source)
            ]
        self.assertEqual(results[0].health, "CRIT")
        self.assertIn("scrape failed", results[0].summary)
        self.assertNotIn("not ready", results[0].summary)
        self.assertEqual(results[1].health, "UNKNOWN")

    async def test_explicit_mapping_does_not_discover_or_drop_membership(self):
        app = prometheus.app_from_settings(json.dumps(SETTINGS))
        check = app.bindings["prometheus-up"].function
        source = app.arguments("prometheus-up", {}, instantiate=True)["prometheus"]
        with patch.object(
            source,
            "collect",
            return_value=prometheus.parse_samples(
                response(series(), series("unmapped:8080")), "instance"
            ),
        ):
            results = [item async for item in check(source)]
        self.assertEqual(
            [item.key for item in results], ["monitoring-target", "second-target"]
        )
        self.assertEqual([item.health for item in results], ["OK", "UNKNOWN"])
        self.assertEqual(results[0].source_at, "2009-09-15T00:00:00.000000Z")
        self.assertIsNone(results[1].source_at)
        self.assertIn("No recent", results[1].summary)

    async def test_collection_failure_keeps_all_outputs_and_hides_private_details(self):
        app = prometheus.app_from_settings(json.dumps(SETTINGS))
        source = app.arguments("prometheus-up", {}, instantiate=True)["prometheus"]
        with patch.object(
            source, "collect", side_effect=urllib.error.URLError("private-access-token")
        ):
            results = [
                item async for item in app.bindings["prometheus-up"].function(source)
            ]
        self.assertEqual(len(results), 2)
        self.assertEqual({item.health for item in results}, {"UNKNOWN"})
        self.assertTrue(all(item.source_at is None for item in results))
        self.assertNotIn("private-access-token", repr(results))

    async def test_settings_are_source_owned_and_private_during_inventory_discovery(
        self,
    ):
        settings = SETTINGS | {
            "url": "http://user:private-access-token@prometheus:9090",
            "environment": "site-a",
            "environment_label": "Production",
        }
        with patch.object(
            prometheus.Prometheus,
            "__init__",
            side_effect=AssertionError("datasource created during discovery"),
        ):
            app = prometheus.app_from_settings(json.dumps(settings))
            metadata = app.metadata("a" * 64)
        self.assertEqual(app.source_id, "prometheus-local")
        self.assertEqual(metadata[0]["environment"], "site-a")
        self.assertEqual(metadata[0]["environment_label"], "Production")
        self.assertEqual(metadata[0]["params_owner"], "source")
        self.assertEqual(metadata[0]["params"], {})
        self.assertEqual(len(metadata[0]["outputs"]), 2)
        self.assertNotIn("private-access-token", json.dumps(metadata))

    async def test_invalid_or_ambiguous_settings_are_rejected_without_echoing_secrets(
        self,
    ):
        duplicate_targets = copy.deepcopy(SETTINGS)
        duplicate_targets["targets"]["second:9090"]["key"] = "monitoring-target"
        many_targets = SETTINGS | {
            "targets": {
                str(index): {
                    "key": f"target-{index}",
                    "label": "Target",
                    "kind": "service",
                }
                for index in range(17)
            }
        }
        for raw in (
            "",
            "x" * (prometheus.MAX_SETTINGS_BYTES + 1),
            '{"url":"private-access-token",',
            '{"url":"first", "url":"private-access-token", "targets":{}}',
            json.dumps(SETTINGS | {"unexpected": True}),
            json.dumps(SETTINGS | {"identity_label": "ambiguous label"}),
            json.dumps(SETTINGS | {"query": "another_metric[30s]"}),
            json.dumps(SETTINGS | {"targets": {}}),
            json.dumps(SETTINGS | {"targets": {"target:8080": {"label": "Target"}}}),
            json.dumps(duplicate_targets),
            json.dumps(many_targets),
        ):
            with self.subTest(size=len(raw)), self.assertRaises(ValueError) as error:
                prometheus.app_from_settings(raw)
            self.assertNotIn("private-access-token", str(error.exception))

    async def test_factory_and_demo_keep_stable_explicit_output_contracts(self):
        app = prometheus.make_app(
            source_id="custom-source",
            environment=Environment("stable-site", "Site"),
            url="http://unused.invalid",
            query="up[30s]",
            identity_label="instance",
            targets={
                "[::1]:9090": Target("local-prometheus", "Local Prometheus", "service")
            },
        )
        self.assertEqual(
            app.metadata("a" * 64)[0]["outputs"][0]["key"], "local-prometheus"
        )
        legacy = monitoring.app.metadata("a" * 64)[0]
        self.assertEqual(monitoring.app.source_id, "monitoring-services")
        self.assertEqual(legacy["key"], "service-readiness")
        self.assertEqual(
            [item["key"] for item in legacy["outputs"]], ["primary", "secondary"]
        )
        self.assertEqual(
            [item["target"]["key"] for item in legacy["outputs"]],
            ["service:primary", "service:secondary"],
        )


if __name__ == "__main__":
    unittest.main()
