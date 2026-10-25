# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Real-file byte policy and the explicit shared bulk-configuration contract."""

from __future__ import annotations

import json
import tempfile
import unittest
from datetime import UTC, datetime
from pathlib import Path

from mondek_examples import bulk_exports, load
from mondek_runner import App, Environment
from mondek_runner.authoring import validate_params


class BulkExportsTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.files = load.ExportDirectory(str(self.directory))
        self.path = self.directory / "export-0000.txt"
        self.binding = load.make_group(0, 1, delegated=True)

    def test_minimum_byte_thresholds_use_strict_boundaries_and_fresh_inspections(
        self,
    ) -> None:
        self.path.write_bytes(b"valid export\n")
        for critical, warning, health, summary in (
            (1, 13, "OK", "meets both minimums"),
            (13, 13, "OK", "meets both minimums"),
            (13, 14, "WARN", "below warning minimum 14 bytes"),
            (14, 14, "CRIT", "below critical minimum 14 bytes"),
            (0, 0, "OK", "meets both minimums"),
            (32, 32, "CRIT", "below critical minimum 32 bytes"),
        ):
            with self.subTest(critical=critical, warning=warning):
                before = datetime.now(UTC)
                result = next(
                    self.binding.function(
                        self.files,
                        {"critical_min_bytes": critical, "warn_min_bytes": warning},
                    )
                )
                after = datetime.now(UTC)
                self.assertEqual(result.health, health)
                self.assertEqual(result.value, 13)
                self.assertIn("13 bytes", result.summary)
                self.assertIn(summary, result.summary)
                self.assertLessEqual(before, datetime.fromisoformat(result.source_at))
                self.assertLessEqual(datetime.fromisoformat(result.source_at), after)

    def test_missing_invalid_and_inaccessible_keep_distinct_meaning(self) -> None:
        result = next(self.binding.function(self.files))
        self.assertEqual(result.health, "CRIT")
        self.assertIn("missing", result.summary)
        self.assertIsNotNone(result.source_at)
        for content in (b"", b"invalid export\n", b"valid export\n" + b"x" * 33):
            with self.subTest(content=content):
                self.path.write_bytes(content)
                result = next(
                    self.binding.function(
                        self.files, {"critical_min_bytes": 0, "warn_min_bytes": 0}
                    )
                )
                self.assertEqual(result.health, "CRIT")
                self.assertIn("contents are invalid", result.summary)
                self.assertIsNotNone(result.source_at)
        self.path.unlink()
        self.path.mkdir()
        result = next(self.binding.function(self.files))
        self.assertEqual(result.health, "UNKNOWN")
        self.assertIn("Cannot inspect export", result.summary)
        self.assertIsNone(result.source_at)

    def test_all_500_scheduled_checks_share_one_complete_semantic_contract(
        self,
    ) -> None:
        app = bulk_exports.make_app(directory=str(self.directory))
        metadata = app.metadata("a" * 64)
        self.assertEqual(app.source_id, "export-policy")
        self.assertEqual(len(metadata), 500)
        self.assertEqual(len({entry["key"] for entry in metadata}), 500)
        self.assertEqual(
            {entry["parameter_contract"] for entry in metadata},
            {"export.minimum-bytes.v1"},
        )
        self.assertEqual({entry["params_owner"] for entry in metadata}, {"ui"})
        self.assertEqual(
            {entry["environment"] for entry in metadata}, {"bulk-config-test"}
        )
        self.assertEqual(
            {entry["environment_label"] for entry in metadata}, {"Configuration test"}
        )
        schemas = {
            json.dumps(entry["parameter_schema"], sort_keys=True) for entry in metadata
        }
        self.assertEqual(len(schemas), 1)
        schema = metadata[0]["parameter_schema"]
        self.assertEqual(
            schema["comparisons"],
            [{"left": "critical_min_bytes", "op": "lte", "right": "warn_min_bytes"}],
        )
        self.assertEqual(
            set(schema["fields"]), {"critical_min_bytes", "warn_min_bytes"}
        )
        for field in schema["fields"].values():
            self.assertEqual(field["type"], "integer")
            self.assertEqual(field["unit"], "bytes")
            self.assertEqual((field["minimum"], field["maximum"]), (0, 32))
        for entry in metadata:
            self.assertEqual(
                entry["params"], {"critical_min_bytes": 1, "warn_min_bytes": 13}
            )
            self.assertEqual(entry["interval_seconds"], 120)
            self.assertEqual(entry["freshness_seconds"], 360)
            self.assertEqual(len(entry["outputs"]), 1)
            self.assertNotIn(str(self.directory), json.dumps(entry))

    def test_policy_requires_complete_bounded_ordered_integer_parameters(self) -> None:
        entry = bulk_exports.make_app(count=1).metadata("a" * 64)[0]
        for params in (
            {"critical_min_bytes": 14, "warn_min_bytes": 13},
            {"critical_min_bytes": -1, "warn_min_bytes": 13},
            {"critical_min_bytes": 1, "warn_min_bytes": 33},
            {"critical_min_bytes": 1.5, "warn_min_bytes": 13},
            {"critical_min_bytes": True, "warn_min_bytes": 13},
            {"critical_min_bytes": 1},
            {"critical_min_bytes": 1, "warn_min_bytes": 13, "path": "/elsewhere"},
        ):
            with self.subTest(params=params):
                with self.assertRaises(ValueError):
                    validate_params(params, entry["parameter_schema"], entry["params"])

    def test_grouping_keeps_all_results_and_readonly_capacity_stays_source_owned(
        self,
    ) -> None:
        grouped = bulk_exports.make_app(count=17, group_size=16, interval_seconds=30)
        metadata = grouped.metadata("a" * 64)
        self.assertEqual([len(entry["outputs"]) for entry in metadata], [16, 1])
        self.assertEqual({entry["freshness_seconds"] for entry in metadata}, {90})
        binding = load.make_group(0, 1)
        app = App(
            source_id="readonly-test", environment=Environment("test"), checks=[binding]
        )
        app.register_datasource(load.ExportDirectory, directory=str(self.directory))
        entry = app.metadata("a" * 64)[0]
        self.assertEqual(entry["params_owner"], "source")
        self.assertEqual(entry["params"], {})
        self.assertEqual(entry["parameter_schema"], {"fields": {}, "comparisons": []})
        self.assertNotIn("parameter_contract", entry)
        self.path.write_bytes(b"valid export\n")
        result = next(binding.function(self.files))
        self.assertEqual(result.health, "OK")
        self.assertEqual(result.summary, "Export contents are valid")


if __name__ == "__main__":
    unittest.main()
