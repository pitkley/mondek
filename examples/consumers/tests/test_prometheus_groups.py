# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Separate query bindings, fixed coverage and private collection settings."""

from __future__ import annotations

import json
import unittest
from dataclasses import replace
from unittest.mock import patch

from mondek_runner import Environment, Target

from mondek_examples.prometheus import Prometheus
from mondek_examples.prometheus_groups import CollectionGroup, make_grouped_app


def group(key="first", *, count=1):
    return CollectionGroup(
        id=key,
        name=f"Query group {key}",
        url=f"http://{key}.invalid/private-base",
        query=f'up{{job="{key}"}}[30s]',
        identity_label="instance",
        targets={
            f"{key}-{number}:9090": Target(
                f"node-{key}-{number}", f"Node {number}", "service"
            )
            for number in range(count)
        },
        measurement="scrape",
    )


def consumer(*groups):
    return make_grouped_app(
        source_id="separate-queries", environment=Environment("local"), groups=groups
    )


class PrometheusGroupTests(unittest.IsolatedAsyncioTestCase):
    async def test_two_queries_keep_independent_private_settings_and_result_semantics(
        self,
    ):
        first = group()
        second = replace(
            group("second"), query="service_ready[30s]", measurement="readiness"
        )
        app = consumer(first, second)
        public = json.dumps(app.metadata("a" * 64))
        for item in (first, second):
            self.assertNotIn(item.url, public)
            self.assertNotIn(item.query, public)
            self.assertNotIn(next(iter(item.targets)), public)
        calls = []

        def collect(source):
            calls.append((source.url, source.query, source.expected_series))
            return {
                next(iter(source.expected_series.values())): (
                    0,
                    "2009-09-15T00:00:00.000000Z",
                )
            }

        with patch.object(Prometheus, "collect", collect):
            results = {}
            for key in ("first", "second"):
                arguments = app.arguments(key, {})
                results[key] = [
                    item async for item in app.bindings[key].function(**arguments)
                ]
        self.assertEqual(
            [call[:2] for call in calls],
            [(first.url, first.query), (second.url, second.query)],
        )
        self.assertEqual(results["first"][0].key, "node-first-0")
        self.assertEqual(results["second"][0].key, "node-second-0")
        self.assertIn("scrape failed", results["first"][0].summary)
        self.assertIn("not ready", results["second"][0].summary)
        self.assertEqual(
            {items[0].source_at for items in results.values()},
            {"2009-09-15T00:00:00.000000Z"},
        )

    async def test_one_failed_query_keeps_its_expected_outputs_and_does_not_poison_another(
        self,
    ):
        app = consumer(group(count=2), group("second"))

        def collect(source):
            if "first.invalid" in source.url:
                raise OSError("private source unavailable")
            return {"second-0:9090": (1, "2009-09-15T00:00:00.000000Z")}

        with patch.object(Prometheus, "collect", collect):
            failed = [
                item
                async for item in app.bindings["first"].function(
                    **app.arguments("first", {})
                )
            ]
            healthy = [
                item
                async for item in app.bindings["second"].function(
                    **app.arguments("second", {})
                )
            ]
        self.assertEqual(
            [(item.key, item.health, item.source_at) for item in failed],
            [("node-first-0", "UNKNOWN", None), ("node-first-1", "UNKNOWN", None)],
        )
        self.assertEqual(healthy[0].health, "OK")
        self.assertNotIn("private source", failed[0].summary)

    async def test_previous_private_group_bindings_restore_without_affecting_other_groups(
        self,
    ):
        original = consumer(group(), group("second"))
        saved = original.private_settings()
        changed = consumer(
            replace(group(), url="http://changed.invalid", query="up[1m]"),
            group("second"),
        )
        changed.restore_private_settings(saved)
        self.assertEqual(changed.arguments("first", {})["prometheus"].url, group().url)
        self.assertEqual(
            changed.arguments("first", {})["prometheus"].query, group().query
        )
        self.assertEqual(
            changed.arguments("second", {})["prometheus"].url, group("second").url
        )

    async def test_hundreds_of_targets_use_explicit_stable_groups_without_querying_during_discovery(
        self,
    ):
        with patch.object(
            Prometheus,
            "collect",
            side_effect=AssertionError("discovery queried a source"),
        ):
            app = consumer(
                *(group(f"group-{number}", count=10) for number in range(50))
            )
            metadata = app.metadata("a" * 64)
        self.assertEqual(len(metadata), 50)
        self.assertEqual(sum(len(item["outputs"]) for item in metadata), 500)
        self.assertEqual(
            {item["key"] for item in metadata},
            {f"group-{number}" for number in range(50)},
        )

    async def test_invalid_membership_and_ambiguous_groups_are_rejected(self):
        for groups in (
            (),
            (group(), group()),
            (group(count=17),),
            (replace(group(), query="sum(up)[30s:1s]"),),
        ):
            with self.subTest(groups=len(groups)), self.assertRaises(ValueError):
                consumer(*groups)
        with self.assertRaisesRegex(ValueError, "512 checks"):
            consumer(*(group(f"group-{number}") for number in range(513)))


if __name__ == "__main__":
    unittest.main()
