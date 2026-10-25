# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Independent source semantics over owned, bounded fixture observations."""

from __future__ import annotations

import io
import json
import unittest
import urllib.error
from datetime import UTC, datetime, timedelta
from unittest.mock import MagicMock, patch

from mondek_examples import grouped

SOURCE_AT = "2009-01-02T03:04:05.123456Z"


def payload(**changes):
    return {
        "used_percent": 40,
        "writes_blocked": False,
        "available": True,
        "source_at": SOURCE_AT,
    } | changes


class GroupedExampleTests(unittest.TestCase):
    def test_independent_sources_and_targets_share_only_declared_condition(self):
        definitions = []
        sources = set()
        for observer, kind in (("node-a", "volume"), ("service-a", "elasticsearch")):
            app = grouped.make_app(observer, kind, "http://fixture.invalid")
            sources.add(app.source_id)
            with patch.object(
                grouped.FixtureData,
                "__init__",
                side_effect=AssertionError("constructed"),
            ):
                metadata = app.metadata("a" * 64)
            self.assertEqual(len(metadata), 1)
            self.assertEqual(metadata[0]["environment"], "production")
            self.assertEqual(metadata[0]["params_owner"], "source")
            self.assertNotIn("fixture.invalid", json.dumps(metadata))
            self.assertEqual(app.runner.id, observer)
            definitions.append(metadata[0]["outputs"][0])
        self.assertEqual(
            sources, {"linux-volume-monitoring", "elasticsearch-monitoring"}
        )
        self.assertNotEqual(definitions[0]["target"], definitions[1]["target"])
        self.assertEqual(definitions[0]["condition"], definitions[1]["condition"])
        self.assertEqual(
            definitions[0]["condition"],
            {
                "namespace": "grouped-example",
                "key": "search-volume-pressure",
                "label": "Search storage capacity",
            },
        )

    def test_peer_observers_do_not_change_target_or_condition_and_environments_stay_distinct(
        self,
    ):
        first = grouped.make_app("node-a", "volume", "http://fixture.invalid")
        peer = grouped.make_app("node-b", "volume", "http://fixture.invalid")
        staging = grouped.make_app(
            "node-c", "volume", "http://fixture.invalid", "staging"
        )
        self.assertEqual(first.metadata("a" * 64), peer.metadata("a" * 64))
        other = staging.metadata("a" * 64)[0]
        self.assertEqual(other["environment"], "staging")
        self.assertEqual(other["outputs"], first.metadata("a" * 64)[0]["outputs"])
        settings = first.private_settings()["construction_environment"]
        self.assertEqual(settings["MONDEK_GROUPED_OBSERVER"], "node-a")
        self.assertEqual(settings["MONDEK_GROUPED_KIND"], "volume")

    def test_inclusive_thresholds_blocked_writes_and_recovery(self):
        source = grouped.FixtureData("node-a", "volume", "http://fixture.invalid")
        for function in (grouped.volume_capacity, grouped.elasticsearch_storage):
            for used, health in (
                (0, "OK"),
                (89.99, "OK"),
                (90, "WARN"),
                (94.99, "WARN"),
                (95, "CRIT"),
                (100, "CRIT"),
                (40, "OK"),
            ):
                with (
                    self.subTest(function=function.__name__, used=used),
                    patch.object(
                        source,
                        "read",
                        return_value=grouped.parse_sample(payload(used_percent=used)),
                    ),
                ):
                    result = function(source)
                    self.assertEqual(result.health, health)
                    self.assertEqual(result.value, used)
                    self.assertEqual(result.source_at, SOURCE_AT)
                    self.assertEqual(result.impacts, ())
            with patch.object(
                source,
                "read",
                return_value=grouped.parse_sample(
                    payload(used_percent=95, writes_blocked=True)
                ),
            ):
                result = function(source)
                self.assertEqual(result.health, "CRIT")
                self.assertEqual(result.impacts, (grouped.WRITES_BLOCKED,))
            with patch.object(
                source,
                "read",
                return_value=grouped.parse_sample(payload(writes_blocked=True)),
            ):
                self.assertEqual(function(source).health, "CRIT")

    def test_unavailable_and_delayed_samples_preserve_source_age_without_impacts(self):
        source = grouped.FixtureData(
            "service-a", "elasticsearch", "http://fixture.invalid"
        )
        with patch.object(
            source,
            "read",
            return_value=grouped.parse_sample(
                payload(available=False, writes_blocked=True)
            ),
        ):
            result = grouped.elasticsearch_storage(source)
        self.assertEqual(result.health, "UNKNOWN")
        self.assertEqual(result.source_at, SOURCE_AT)
        self.assertIsNone(result.value)
        self.assertEqual(result.impacts, ())
        recent = (
            datetime.now(UTC).isoformat(timespec="microseconds").replace("+00:00", "Z")
        )
        for observed_at in (recent, SOURCE_AT):
            with patch.object(
                source,
                "read",
                return_value=grouped.parse_sample(
                    payload(source_at=observed_at, used_percent=95)
                ),
            ):
                result = grouped.elasticsearch_storage(source)
                self.assertEqual(result.health, "CRIT")
                self.assertEqual(result.source_at, observed_at)

    def test_invalid_fields_and_times_reject_instead_of_manufacturing_healthy_data(
        self,
    ):
        for changes in (
            {"used_percent": True},
            {"used_percent": float("nan")},
            {"used_percent": float("inf")},
            {"used_percent": -1},
            {"used_percent": 101},
            {"used_percent": "95"},
            {"available": 1},
            {"writes_blocked": "false"},
            {"source_at": None},
            {"source_at": "2009-01-02T03:04:05Z"},
            {"source_at": "1999-01-02T03:04:05.123456Z"},
            {"source_at": "2009-99-99T03:04:05.123456Z"},
            {
                "source_at": (datetime.now(UTC) + timedelta(days=1)).isoformat(
                    timespec="microseconds"
                )
            },
            {"source_at": "2009-01-02T03:04:05.123456+02:00"},
            {"extra": "ignored?"},
        ):
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                grouped.parse_sample(payload(**changes))
        for value in (None, [], {}, {"used_percent": 1}):
            with self.assertRaises(ValueError):
                grouped.parse_sample(value)

    def test_collection_failure_has_unknown_health_and_no_invented_source_time(self):
        source = grouped.FixtureData("node-a", "volume", "http://fixture.invalid")
        for error in (
            TimeoutError(),
            OSError(),
            ValueError(),
            UnicodeDecodeError("utf8", b"\xff", 0, 1, "invalid"),
        ):
            with (
                self.subTest(error=type(error).__name__),
                patch.object(source, "read", side_effect=error),
            ):
                result = grouped.volume_capacity(source)
                self.assertEqual(result.health, "UNKNOWN")
                self.assertIsNone(result.source_at)
                self.assertIsNone(result.value)
                self.assertEqual(result.impacts, ())

    def test_http_reads_bound_bytes_timeout_and_encoded_observer_without_ambient_proxy(
        self,
    ):
        with patch.object(grouped.urllib.request, "build_opener") as build:
            source = grouped.FixtureData("node/a", "volume", "http://fixture.invalid/")
        handlers = build.call_args.args
        self.assertEqual(handlers[0].proxies, {})
        self.assertIsInstance(handlers[1], grouped._NoRedirect)
        response = MagicMock()
        response.status = 200
        response.headers = {}
        response.read.return_value = json.dumps(payload()).encode()
        response.__enter__.return_value = response
        source.client.open.return_value = response
        self.assertEqual(source.read().source_at, SOURCE_AT)
        request = source.client.open.call_args.args[0]
        self.assertEqual(
            request.full_url, "http://fixture.invalid/grouped/node%2Fa/volume"
        )
        self.assertEqual(source.client.open.call_args.kwargs["timeout"], 2)
        response.read.assert_called_once_with(grouped.MAX_BODY + 1)

    def test_http_oversize_bad_encoding_and_non200_remain_unknown(self):
        source = grouped.FixtureData("node-a", "volume", "http://fixture.invalid")
        for raw, status, headers in (
            (b"x" * 4097, 200, {}),
            (b"not json", 200, {}),
            (b"\xff", 200, {}),
            (json.dumps(payload()).encode(), 503, {}),
            (json.dumps(payload()).encode(), 200, {"Content-Encoding": "gzip"}),
        ):
            response = MagicMock(status=status, headers=headers)
            response.read.return_value = raw
            response.__enter__.return_value = response
            with patch.object(source.client, "open", return_value=response):
                result = grouped.volume_capacity(source)
                self.assertEqual(result.health, "UNKNOWN")
                self.assertIsNone(result.source_at)
        redirect = urllib.error.HTTPError(source.url, 302, "Found", {}, io.BytesIO())
        with patch.object(source.client, "open", side_effect=redirect):
            self.assertEqual(grouped.volume_capacity(source).health, "UNKNOWN")
        redirect.close()

    def test_deployment_settings_reject_bad_kind_observer_or_url_before_registration(
        self,
    ):
        for observer, kind, url in (
            ("bad name", "volume", "http://fixture.invalid"),
            ("node", "other", "http://fixture.invalid"),
            ("node", "volume", "file:///tmp/state"),
            ("node", "volume", "http://user:password@fixture.invalid"),
            ("node", "volume", "http://fixture.invalid?token=private"),
            ("node", "volume", "http://fixture.invalid#fragment"),
            ("node", "volume", "http://fixture.invalid:bad"),
            ("node", "volume", "http://fixture.invalid/\n"),
        ):
            with (
                self.subTest(observer=observer, kind=kind, url=url),
                self.assertRaises(ValueError),
            ):
                grouped.make_app(observer, kind, url)


if __name__ == "__main__":
    unittest.main()
