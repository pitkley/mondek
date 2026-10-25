# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Actual local observation, bounded review evidence and unavailable collection."""

import tempfile
import unittest
from pathlib import Path

from mondek_examples.discovery_demo import LocalDirectories, directories


class DirectoryDiscoveryTests(unittest.TestCase):
    def test_actual_directories_have_stable_identities_and_do_not_include_files(self):
        with tempfile.TemporaryDirectory() as root:
            source = LocalDirectories(root)
            self.assertEqual(directories(source).health, "OK")
            (Path(root) / "app").mkdir()
            (Path(root) / "data").mkdir()
            (Path(root) / "ordinary-file").write_text("Not a directory")
            first = directories(source)
            second = directories(source)
            self.assertEqual(first.health, "WARN")
            self.assertIn("- 'app'", first.details)
            self.assertIn("- 'data'", first.details)
            self.assertEqual(first.discovery.to_dict(), second.discovery.to_dict())
            self.assertEqual(
                [item.label for item in first.discovery.candidates], ["app", "data"]
            )
            (Path(root) / "app").rmdir()
            self.assertEqual(
                directories(source).discovery.candidates,
                (first.discovery.candidates[1],),
            )

    def test_bounded_candidates_count_omissions_and_escape_filesystem_names(self):
        with tempfile.TemporaryDirectory() as root:
            for index in range(25):
                (Path(root) / str(index)).mkdir()
            (Path(root) / ("é" * 100)).mkdir()
            (Path(root) / "bad\nname").mkdir()
            result = directories(LocalDirectories(root))
            result.to_dict()
            self.assertIn("7 additional directories omitted", result.details)
            self.assertLessEqual(len(result.details.encode("utf-8")), 16384)
            self.assertEqual(len(result.discovery.candidates), 20)
            self.assertEqual(result.discovery.omitted, 7)
            for path in Path(root).iterdir():
                if path.name.isnumeric():
                    path.rmdir()
            result = directories(LocalDirectories(root))
            result.to_dict()
            self.assertTrue(
                all(
                    len(item.label.encode()) <= 200
                    for item in result.discovery.candidates
                )
            )
            self.assertTrue(
                all("\n" not in item.label for item in result.discovery.candidates)
            )

    def test_missing_root_is_unavailable_not_an_empty_healthy_inventory(self):
        with tempfile.TemporaryDirectory() as root:
            with self.assertRaises(FileNotFoundError):
                directories(LocalDirectories(str(Path(root) / "missing")))
