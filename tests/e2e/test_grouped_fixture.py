# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Owned fixture control semantics; no HTTP server or Docker is started."""

from __future__ import annotations

import copy
import importlib.util
import json
import sqlite3
import tempfile
import unittest
from concurrent.futures import ThreadPoolExecutor
from contextlib import closing
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest.mock import Mock, patch

FIXTURE_PATH = Path(__file__).resolve().parents[1] / "fixtures" / "service.py"
SPEC = importlib.util.spec_from_file_location("grouped_fixture_tests", FIXTURE_PATH)
assert SPEC is not None and SPEC.loader is not None
fixture = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(fixture)
AT = datetime(2009, 9, 16, 12, 0, 0, 123456, tzinfo=timezone.utc)


class GroupedFixtureTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.path = Path(temporary.name) / "fixture.sqlite3"
        settings = patch.object(fixture, "STATE_PATH", self.path)
        settings.start()
        self.addCleanup(settings.stop)
        fixture.initialize()

    def test_independent_partial_patches_preserve_defaults_existing_modes_and_peers(
        self,
    ):
        original_defaults = copy.deepcopy(fixture.DEFAULT_MODE)
        fixture.update_mode({"backlog": 7, "webhook": "reject"})
        fixture.update_mode(
            {"grouped_samples": {"node-a/volume": {"used_percent": 96}}}
        )
        current = fixture.update_mode(
            {"grouped_samples": {"service-a/elasticsearch": {"writes_blocked": True}}}
        )
        self.assertEqual(
            current["grouped_samples"]["node-a/volume"]["used_percent"], 96
        )
        self.assertEqual(
            current["grouped_samples"]["service-a/elasticsearch"]["used_percent"], 40
        )
        self.assertTrue(
            current["grouped_samples"]["service-a/elasticsearch"]["writes_blocked"]
        )
        self.assertFalse(current["grouped_samples"]["node-a/volume"]["writes_blocked"])
        self.assertEqual(current["backlog"], 7)
        self.assertEqual(current["webhook"], "reject")
        fixture.initialize()
        self.assertEqual(fixture.mode(), current)
        self.assertEqual(fixture.DEFAULT_MODE, original_defaults)

    def test_concurrent_observer_changes_are_merged_in_the_database_transaction(self):
        patches = [
            {"grouped_samples": {"node-a/volume": {"used_percent": 95}}},
            {"grouped_samples": {"service-a/elasticsearch": {"available": False}}},
        ]
        with ThreadPoolExecutor(max_workers=2) as workers:
            list(workers.map(fixture.update_mode, patches))
        samples = fixture.mode()["grouped_samples"]
        self.assertEqual(samples["node-a/volume"]["used_percent"], 95)
        self.assertFalse(samples["service-a/elasticsearch"]["available"])

    def test_database_connections_close_after_success_and_rollback(self):
        opened = []
        connect = fixture.database

        def tracked_connection():
            connection = connect()
            opened.append(connection)
            return connection

        with patch.object(fixture, "database", side_effect=tracked_connection):
            fixture.initialize()
            fixture.mode()
            fixture.update_mode({"backlog": 7})
            with self.assertRaises(ValueError):
                fixture.update_mode({"backlog": 9, "ready": "invalid"})

        self.assertEqual(fixture.mode()["backlog"], 7)
        self.assertEqual(len(opened), 4)
        for connection in opened:
            with self.assertRaisesRegex(sqlite3.ProgrammingError, "closed database"):
                connection.execute("SELECT 1")

    def test_original_age_and_unavailability_are_explicit_without_sleeping(self):
        fixture.update_mode(
            {
                "grouped_samples": {
                    "service-a/elasticsearch": {
                        "available": False,
                        "writes_blocked": True,
                        "sample_age_seconds": 60.25,
                    }
                }
            }
        )
        with patch.object(fixture.time, "sleep", side_effect=AssertionError("slept")):
            result = fixture.grouped_sample("/grouped/service-a/elasticsearch", AT)
            fresh = fixture.grouped_sample("/grouped/node-a/volume", AT)
        self.assertEqual(
            set(result), {"used_percent", "available", "writes_blocked", "source_at"}
        )
        self.assertFalse(result["available"])
        self.assertTrue(result["writes_blocked"])
        self.assertEqual(
            datetime.fromisoformat(result["source_at"]), AT - timedelta(seconds=60.25)
        )
        self.assertEqual(fresh["source_at"], "2009-09-16T12:00:00.123456Z")

    def test_invalid_updates_are_atomic_and_do_not_change_existing_behavior(self):
        before = fixture.mode()
        for sample in (
            {"used_percent": True},
            {"used_percent": float("nan")},
            {"used_percent": float("inf")},
            {"used_percent": -1},
            {"used_percent": 101},
            {"sample_age_seconds": -1},
            {"sample_age_seconds": 86401},
            {"sample_age_seconds": True},
            {"available": 1},
            {"writes_blocked": "false"},
            {"unknown": 1},
            None,
            [],
        ):
            with self.subTest(sample=sample), self.assertRaises(ValueError):
                fixture.update_mode(
                    {"ready": False, "grouped_samples": {"node-a/volume": sample}}
                )
            self.assertEqual(fixture.mode(), before)
        for changes in (
            None,
            [],
            {"bad observer/volume": {}},
            {"node-a/other": {}},
            {"x" * 129 + "/volume": {}},
        ):
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                fixture.update_mode({"grouped_samples": changes})
            self.assertEqual(fixture.mode(), before)

    def test_sample_count_and_identity_bounds_support_additional_named_observers(self):
        extra = {
            f"additional-node-{index}/volume": {}
            for index in range(32 - len(fixture.DEFAULT_MODE["grouped_samples"]))
        }
        fixture.update_mode({"grouped_samples": extra})
        self.assertEqual(len(fixture.mode()["grouped_samples"]), 32)
        with self.assertRaisesRegex(ValueError, "32 independent"):
            fixture.update_mode({"grouped_samples": {"overflow/volume": {}}})
        self.assertIsNone(fixture.grouped_sample("/grouped/unknown/volume", AT))
        self.assertIsNone(fixture.grouped_sample("/grouped/node-a/elasticsearch", AT))

    def test_encoded_observer_and_http_handler_return_exact_contract_or404(self):
        fixture.update_mode(
            {"grouped_samples": {"node/a/volume": {"used_percent": 90}}}
        )
        self.assertEqual(
            fixture.grouped_sample("/grouped/node%2Fa/volume", AT)["used_percent"], 90
        )
        handler = object.__new__(fixture.Handler)
        handler.respond = Mock()
        handler.path = "/grouped/node-a/volume"
        handler.do_GET()
        status, body = handler.respond.call_args.args
        self.assertEqual(status, 200)
        self.assertEqual(
            set(body), {"used_percent", "writes_blocked", "available", "source_at"}
        )
        self.assertLess(len(json.dumps(body).encode()), 4096)
        handler.path = "/grouped/unknown/volume"
        handler.do_GET()
        self.assertEqual(handler.respond.call_args.args[0], 404)
        handler.path = "/ready"
        handler.do_GET()
        self.assertEqual(handler.respond.call_args.args, (200, {"ready": True}))

    def test_existing_persisted_mode_without_grouped_field_loads_new_defaults(self):
        old = {
            key: value
            for key, value in fixture.DEFAULT_MODE.items()
            if key != "grouped_samples"
        }
        with closing(fixture.database()) as db, db:
            db.execute("UPDATE settings SET mode=? WHERE id=1", (json.dumps(old),))
        self.assertEqual(
            fixture.grouped_sample("/grouped/node-a/volume", AT)["used_percent"], 40
        )
        fixture.update_mode({"backlog": 17})
        self.assertEqual(
            fixture.mode()["grouped_samples"], fixture.DEFAULT_MODE["grouped_samples"]
        )

    def test_coverage_defaults_upgrade_without_resetting_existing_owned_samples(self):
        old_samples = {
            "node-a/volume": fixture.GROUPED_SAMPLE_DEFAULTS | {"used_percent": 97},
            "service-a/elasticsearch": fixture.GROUPED_SAMPLE_DEFAULTS
            | {"available": False},
            **{
                f"old-node-{index}/volume": fixture.GROUPED_SAMPLE_DEFAULTS
                | {"used_percent": index}
                for index in range(14)
            },
        }
        old = fixture.DEFAULT_MODE | {
            "grouped_samples": old_samples,
            "webhook": "reject",
        }
        with closing(fixture.database()) as db, db:
            db.execute("UPDATE settings SET mode=? WHERE id=1", (json.dumps(old),))
        fixture.initialize()
        current = fixture.mode()
        self.assertEqual(len(current["grouped_samples"]), 22)
        self.assertEqual(current["webhook"], "reject")
        self.assertEqual(
            fixture.grouped_sample("/grouped/service-b/elasticsearch", AT)[
                "used_percent"
            ],
            40,
        )
        for identity, sample in old_samples.items():
            self.assertEqual(current["grouped_samples"][identity], sample)
        self.assertEqual(
            fixture.grouped_sample(
                "/grouped/coverage-service-b-production/elasticsearch", AT
            )["used_percent"],
            40,
        )
        fixture.update_mode(
            {"grouped_samples": {"node-b/volume": {"used_percent": 95}}}
        )
        fixture.initialize()
        self.assertEqual(
            fixture.mode()["grouped_samples"]["node-b/volume"]["used_percent"], 95
        )


if __name__ == "__main__":
    unittest.main()
