# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Consumer domain behavior; packaged acceptance separately tests real services."""

from __future__ import annotations

import json
import tempfile
import unittest
from datetime import UTC, datetime, timedelta
from pathlib import Path
from unittest.mock import patch

from mondek_examples import load, monitoring, node


class NodeChecksTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.files = node.LocalFiles(str(self.directory))
        self.params = {"warn_age_seconds": 60, "crit_age_seconds": 120}

    def test_export_missing_invalid_and_unreadable_are_distinct(self) -> None:
        result = node.export_file(self.files, self.params)
        self.assertEqual(result.health, "CRIT")
        self.assertIn("missing", result.summary)
        self.assertIsNotNone(result.source_at)
        (self.directory / "export.json").write_text("invalid JSON")
        self.assertEqual(node.export_file(self.files, self.params).health, "CRIT")
        with patch.object(self.files, "read_json", side_effect=PermissionError):
            result = node.export_file(self.files, self.params)
        self.assertEqual(result.health, "UNKNOWN")
        self.assertIsNone(result.source_at)

    def test_export_age_boundaries_use_domain_time_with_fresh_inspection(self) -> None:
        now = datetime(2009, 9, 16, 0, 0, tzinfo=UTC)
        for age, health in (
            (60, "OK"),
            (60.001, "WARN"),
            (120, "WARN"),
            (120.001, "CRIT"),
        ):
            with self.subTest(age=age):
                (self.directory / "export.json").write_text(
                    json.dumps(
                        {
                            "generated_at": (now - timedelta(seconds=age)).isoformat(),
                            "records": [{"id": 1}],
                        }
                    )
                )
                with patch.object(node, "datetime") as clock:
                    clock.now.return_value = now
                    clock.fromisoformat.side_effect = datetime.fromisoformat
                    result = node.export_file(self.files, self.params)
                self.assertEqual(result.health, health)
                self.assertAlmostEqual(result.value, age)
                self.assertIsNotNone(result.source_at)

    def test_process_identity_rejects_reused_pid_and_distinguishes_visibility(
        self,
    ) -> None:
        with patch.object(
            self.files, "read_json", return_value={"pid": 42, "start": "100"}
        ):
            with patch.object(
                Path,
                "read_text",
                return_value="42 (worker) " + " ".join(["S"] + ["0"] * 18 + ["101"]),
            ):
                result = node.application_process(self.files)
            self.assertEqual(result.health, "CRIT")
            self.assertIn("reused", result.summary)
            with patch.object(Path, "read_text", side_effect=PermissionError("denied")):
                self.assertEqual(node.application_process(self.files).health, "UNKNOWN")
            with patch.object(Path, "read_text", side_effect=FileNotFoundError):
                self.assertEqual(node.application_process(self.files).health, "CRIT")

    def test_load_results_actually_read_each_declared_file(self) -> None:
        (self.directory / "export-0000.txt").write_bytes(b"valid export\n")
        (self.directory / "export-0001.txt").write_bytes(b"invalid\n")
        binding = load.make_group(0, 3)
        results = list(binding.function(load.ExportDirectory(str(self.directory))))
        self.assertEqual(
            [result.key for result in results],
            ["export-0000", "export-0001", "export-0002"],
        )
        self.assertEqual([result.health for result in results], ["OK", "CRIT", "CRIT"])
        self.assertIn("missing", results[-1].summary)


class PrometheusChecksTests(unittest.IsolatedAsyncioTestCase):
    async def test_shared_collection_preserves_source_age_and_independent_results(
        self,
    ) -> None:
        source = monitoring.Prometheus("http://unused.invalid")
        sampled_at = "2009-09-15T00:00:00.000000Z"
        with patch.object(
            source,
            "collect",
            return_value={"primary": (0, sampled_at), "secondary": (1, sampled_at)},
        ) as collect:
            results = [result async for result in monitoring.service_readiness(source)]
        self.assertEqual(collect.call_count, 1)
        self.assertEqual([result.health for result in results], ["CRIT", "OK"])
        self.assertEqual({result.source_at for result in results}, {sampled_at})

    async def test_collection_outage_and_missing_series_preserve_expected_keys(
        self,
    ) -> None:
        source = monitoring.Prometheus("http://unused.invalid")
        with patch.object(source, "collect", side_effect=OSError("offline")):
            results = [result async for result in monitoring.service_readiness(source)]
        self.assertEqual({result.key for result in results}, {"primary", "secondary"})
        self.assertEqual({result.health for result in results}, {"UNKNOWN"})
        with patch.object(source, "collect", return_value={}):
            missing = [result async for result in monitoring.service_readiness(source)]
        self.assertEqual(len(missing), 2)
        self.assertTrue(all("No recent" in result.summary for result in missing))

    async def test_metadata_exposes_expected_membership_without_datasource_io(
        self,
    ) -> None:
        with patch.object(
            monitoring.Prometheus,
            "__init__",
            side_effect=AssertionError("constructed during discovery"),
        ):
            metadata = monitoring.app.metadata("a" * 64)
        self.assertEqual(len(metadata), 1)
        self.assertEqual(len(metadata[0]["outputs"]), 2)
        self.assertNotEqual(
            metadata[0]["outputs"][0]["target"], metadata[0]["outputs"][1]["target"]
        )


if __name__ == "__main__":
    unittest.main()
