# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Numeric policy boundaries, private series bindings and original sample age."""

from __future__ import annotations

import json
import sys
import unittest
from datetime import UTC, datetime
from decimal import Decimal
from unittest.mock import MagicMock, patch

from mondek_runner import Environment, Target
from mondek_runner.authoring import validate_params

from mondek_examples import prometheus
from mondek_examples.prometheus_numeric import NumericPrometheus, make_numeric_app

SAMPLED = datetime(2009, 9, 15, tzinfo=UTC)
SOURCE_AT = "2009-09-15T00:00:00.000000Z"
TARGETS = {
    "primary-private-series": Target("queue:primary", "Primary queue", "queue"),
    "secondary-private-series": Target("queue:secondary", "Secondary queue", "queue"),
}


def response(value="5", *, identity="primary-private-series", values=None):
    return json.dumps(
        {
            "status": "success",
            "data": {
                "resultType": "matrix",
                "result": [
                    {
                        "metric": {"service": identity},
                        "values": values
                        if values is not None
                        else [[SAMPLED.timestamp(), value]],
                    }
                ],
            },
        }
    ).encode()


def consumer(**overrides):
    return make_numeric_app(
        **(
            {
                "source_id": "numeric-test",
                "environment": Environment("local-test", "Local test"),
                "url": "http://private-user:private-secret@unused.invalid",
                "query": "queue_depth[30s]",
                "identity_label": "service",
                "targets": TARGETS,
                "unit": "items",
                "direction": "above",
                "warning": 5,
                "critical": 10,
                "minimum": -1_000_000,
                "maximum": 1_000_000,
            }
            | overrides
        )
    )


async def evaluate(app, samples, params=None):
    function = app.bindings["numeric-thresholds"].function
    parameters = params or function.mondek_definition["params"]
    arguments = app.arguments("numeric-thresholds", parameters)
    with patch.object(
        arguments["prometheus"], "collect", return_value=samples
    ) as collect:
        results = [result async for result in function(**arguments)]
    collect.assert_called_once_with()
    return results


class NumericParserTests(unittest.TestCase):
    def test_latest_finite_numeric_value_keeps_original_age(self):
        for value in ("5.25", "-273.15", "0", "1e100"):
            raw = response(
                values=[[SAMPLED.timestamp() - 8, "2"], [SAMPLED.timestamp(), value]]
            )
            self.assertEqual(
                prometheus.parse_numeric_samples(raw, "service"),
                {"primary-private-series": (float(value), SOURCE_AT)},
            )
        self.assertLess(SAMPLED.timestamp(), datetime.now(UTC).timestamp() - 60)

    def test_binary_readiness_remains_strict_including_older_range_samples(self):
        for values in (
            [[SAMPLED.timestamp(), "2"]],
            [[SAMPLED.timestamp() - 1, "2"], [SAMPLED.timestamp(), "1"]],
        ):
            raw = response(values=values)
            self.assertTrue(prometheus.parse_numeric_samples(raw, "service"))
            with self.assertRaisesRegex(ValueError, "zero or one"):
                prometheus.parse_samples(raw, "service")

    def test_malformed_nonfinite_partial_and_oversized_numeric_data_are_rejected(self):
        for raw in (
            response("NaN"),
            response("+Inf"),
            response("-Inf"),
            response("1e1000"),
            response("not-a-number"),
            response(True),
            response(
                values=[[SAMPLED.timestamp() - 1, "NaN"], [SAMPLED.timestamp(), "5"]]
            ),
            response(values=[[True, "5"]]),
            response(values=[[SAMPLED.timestamp(), "5"], [SAMPLED.timestamp(), "6"]]),
            response(values=[[datetime.now(UTC).timestamp() + 60, "5"]]),
            b'{"status":"success","warnings":["partial"],"data":{}}',
            b'{"status":"success","data":{"resultType":"vector","result":[]}}',
            b"x" * (prometheus.MAX_RESPONSE_BYTES + 1),
        ):
            with self.subTest(raw=raw[:80]), self.assertRaises(ValueError):
                prometheus.parse_numeric_samples(raw, "service")

    def test_numeric_collection_uses_one_bounded_http_read_and_raw_query(self):
        app = consumer()
        datasource = app.arguments("numeric-thresholds", {})["prometheus"]
        opened = MagicMock()
        opened.__enter__.return_value.read.return_value = response("5.5")
        with patch.object(
            prometheus.urllib.request, "urlopen", return_value=opened
        ) as request:
            self.assertEqual(
                datasource.collect()["primary-private-series"], (5.5, SOURCE_AT)
            )
        self.assertEqual(request.call_count, 1)
        self.assertIn(
            "query=queue_depth%5B30s%5D&timeout=2s", request.call_args.args[0]
        )
        self.assertEqual(request.call_args.kwargs, {"timeout": 3})
        opened.__enter__.return_value.read.assert_called_once_with(256 * 1024 + 1)


class NumericConsumerTests(unittest.IsolatedAsyncioTestCase):
    async def test_source_selected_ranges_preserve_exact_schema_after_decimal_expansion(
        self,
    ):
        def expanded_number(token):
            decimal = Decimal(token)
            return (
                int(decimal)
                if decimal == decimal.to_integral_value()
                else float(decimal)
            )

        for maximum in (1_000_000, 1_000_000.0, 1e23, sys.float_info.max):
            entry = consumer(minimum=-273.15, maximum=maximum).metadata("a" * 64)[0]
            schema = entry["parameter_schema"]
            # PostgreSQL jsonb expands exponent notation before Jason decodes
            # it. Integral literals can therefore return as exact integers.
            round_tripped = json.loads(json.dumps(schema), parse_float=expanded_number)
            self.assertEqual(round_tripped, schema)
            self.assertIs(type(schema["fields"]["warning"]["maximum"]), int)
            self.assertEqual(schema["fields"]["warning"]["maximum"], int(maximum))
            validate_params(entry["params"], round_tripped, entry["params"])

        from mondek_examples.prometheus_numeric_example import app

        schema = app.metadata("a" * 64)[0]["parameter_schema"]
        self.assertEqual(schema["fields"]["warning"]["minimum"], 0)
        self.assertEqual(schema["fields"]["critical"]["maximum"], 1_000_000)
        self.assertNotIn("e+308", json.dumps(schema))

    async def test_above_and_below_have_inclusive_warning_and_critical_boundaries(self):
        cases = (
            (
                consumer(),
                [(4.9, "OK"), (5, "WARN"), (9.9, "WARN"), (10, "CRIT"), (11, "CRIT")],
            ),
            (
                consumer(direction="below", warning=5, critical=2, unit="bytes"),
                [(6, "OK"), (5, "WARN"), (2.1, "WARN"), (2, "CRIT"), (-1, "CRIT")],
            ),
        )
        for app, boundaries in cases:
            for value, health in boundaries:
                with self.subTest(
                    direction=app.bindings[
                        "numeric-thresholds"
                    ].function.mondek_definition["comparisons"],
                    value=value,
                ):
                    results = await evaluate(
                        app, {"primary-private-series": (value, SOURCE_AT)}
                    )
                    self.assertEqual(results[0].health, health)
                    self.assertEqual(results[0].value, value)
                    self.assertEqual(results[0].source_at, SOURCE_AT)
                    self.assertEqual(
                        (results[1].health, results[1].source_at), ("UNKNOWN", None)
                    )

    async def test_one_collection_keeps_fixed_results_independent_and_ignores_unmapped_series(
        self,
    ):
        results = await evaluate(
            consumer(),
            {
                "primary-private-series": (12, SOURCE_AT),
                "secondary-private-series": (1, SOURCE_AT),
                "unexpected-series": (100, SOURCE_AT),
            },
        )
        self.assertEqual(
            [(item.key, item.health) for item in results],
            [("queue:primary", "CRIT"), ("queue:secondary", "OK")],
        )
        self.assertTrue(
            all("items according to Prometheus" in item.summary for item in results)
        )

    async def test_failed_collection_preserves_all_expected_outputs_without_private_details(
        self,
    ):
        app = consumer()
        kwargs = app.arguments("numeric-thresholds", {"warning": 5, "critical": 10})
        with patch.object(
            kwargs["prometheus"], "collect", side_effect=ValueError("private-secret")
        ):
            results = [
                item
                async for item in app.bindings["numeric-thresholds"].function(**kwargs)
            ]
        self.assertEqual(
            [(item.key, item.health, item.source_at) for item in results],
            [("queue:primary", "UNKNOWN", None), ("queue:secondary", "UNKNOWN", None)],
        )
        self.assertNotIn("private-secret", repr(results))

    async def test_manually_registered_datasource_cannot_change_declared_policy(self):
        for changed in ({"unit": "bytes"}, {"direction": "below"}):
            app = consumer()
            kwargs = app.arguments("numeric-thresholds", {"warning": 5, "critical": 10})
            for key, value in changed.items():
                setattr(kwargs["prometheus"], key, value)
            with patch.object(kwargs["prometheus"], "collect") as collect:
                results = [
                    item
                    async for item in app.bindings["numeric-thresholds"].function(
                        **kwargs
                    )
                ]
            collect.assert_not_called()
            self.assertEqual(
                [(item.health, item.source_at) for item in results],
                [("UNKNOWN", None), ("UNKNOWN", None)],
            )

    async def test_complete_schema_is_delegated_but_units_direction_and_access_are_source_owned(
        self,
    ):
        with patch.object(
            NumericPrometheus,
            "__init__",
            side_effect=AssertionError("discovery performed I/O"),
        ):
            app = consumer(parameter_contract="queue-depth.items.above.v1")
            entry = app.metadata("a" * 64)[0]
        self.assertEqual(entry["params_owner"], "ui")
        self.assertEqual(entry["params"], {"warning": 5, "critical": 10})
        self.assertEqual(entry["parameter_contract"], "queue-depth.items.above.v1")
        self.assertEqual(
            set(entry["parameter_schema"]["fields"]), {"warning", "critical"}
        )
        self.assertEqual(
            entry["parameter_schema"]["fields"]["warning"]["unit"], "items"
        )
        self.assertEqual(
            entry["parameter_schema"]["comparisons"],
            [{"left": "warning", "op": "lt", "right": "critical"}],
        )
        below = consumer(direction="below", warning=5, critical=2).metadata("a" * 64)[0]
        self.assertEqual(
            below["parameter_schema"]["comparisons"],
            [{"left": "critical", "op": "lt", "right": "warning"}],
        )
        self.assertNotIn("parameter_contract", below)
        for private in (
            "private-secret",
            "private-user",
            "private-series",
            "queue_depth[30s]",
        ):
            self.assertNotIn(private, json.dumps(entry))
        for params in (
            {"warning": 5},
            {"warning": 10, "critical": 5},
            {"warning": 5, "critical": 5},
            {"warning": 5, "critical": 10, "unit": "bytes"},
        ):
            with self.subTest(params=params), self.assertRaises(ValueError):
                validate_params(params, entry["parameter_schema"], entry["params"])
        validate_params(
            {"warning": 1, "critical": 2}, entry["parameter_schema"], entry["params"]
        )
        results = await evaluate(
            app,
            {"primary-private-series": (2, SOURCE_AT)},
            {"warning": 1, "critical": 2},
        )
        self.assertEqual(results[0].health, "CRIT")

    async def test_prepared_private_series_and_query_restore_without_exposing_bindings(
        self,
    ):
        original = consumer()
        saved = original.private_settings()
        changed = consumer(
            query="other_queue[30s]",
            targets={
                "new-private-series": TARGETS["primary-private-series"],
                "new-secondary": TARGETS["secondary-private-series"],
            },
        )
        self.assertNotEqual(saved, changed.private_settings())
        changed.restore_private_settings(saved)
        source = changed.arguments("numeric-thresholds", {})["prometheus"]
        self.assertEqual(source.query, "queue_depth[30s]")
        self.assertEqual(
            source.expected_series["queue:primary"], "primary-private-series"
        )
        results = await evaluate(
            changed,
            {
                "primary-private-series": (1, SOURCE_AT),
                "new-private-series": (12, SOURCE_AT),
            },
        )
        self.assertEqual(results[0].health, "OK")

    async def test_policy_and_membership_bounds_are_validated_before_discovery(self):
        invalid = (
            {"minimum": True},
            {"minimum": float("nan")},
            {"maximum": float("inf")},
            {"minimum": 10, "maximum": 5},
            {"minimum": 6},
            {"maximum": 9},
            {"warning": True},
            {"critical": float("nan")},
            {"warning": float("inf")},
            {"critical": 10**500},
            {"warning": 10, "critical": 5},
            {"direction": "below", "warning": 5, "critical": 10},
            {"direction": "sideways"},
            {"unit": ""},
            {"unit": "x" * 65},
            {"targets": {}},
            {
                "targets": {
                    "a": TARGETS["primary-private-series"],
                    "b": TARGETS["primary-private-series"],
                }
            },
            {"targets": {str(i): Target(str(i), str(i)) for i in range(17)}},
            {"query": "queue_depth"},
            {"query": "(queue_depth)[30s:1s]"},
            {"parameter_contract": "bad\ncontract"},
        )
        for overrides in invalid:
            with self.subTest(overrides=overrides), self.assertRaises(ValueError):
                consumer(**overrides)


if __name__ == "__main__":
    unittest.main()
