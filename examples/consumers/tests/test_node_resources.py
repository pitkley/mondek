# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Explicit plural node resources execute independently and preserve source identity."""

from __future__ import annotations

import json
import os
import tempfile
import unittest
import uuid
from pathlib import Path
from unittest.mock import patch

from mondek_runner.bundle import snapshot
from mondek_runner.runtime import execute

from mondek_examples.node_common import LocalProcess, capacity_policy, file_policy
from mondek_examples.node_resources import (
    FileResource,
    MountResource,
    NodeResources,
    ProcessResource,
    configuration_from_settings,
    make_app,
)


def assignment(inventory, key):
    entry = next(item for item in inventory["checks"] if item["key"] == key)
    return {
        **entry,
        "id": str(uuid.uuid4()),
        "kind": "python",
        "generation": 1,
        "source_key": key,
        "source_id": inventory["source_id"],
        "source_revision": inventory["source_revision"],
        "expected_keys": [output["key"] for output in entry["outputs"]],
    }


class NodeResourceTests(unittest.TestCase):
    def test_two_files_one_failed_and_real_filesystem_inspection_are_independent(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            existing = directory / "real-file"
            existing.write_text("real data")
            app = make_app(
                NodeResources(
                    "node-a",
                    files=(
                        FileResource("first", str(existing)),
                        FileResource("second", str(directory / "missing")),
                    ),
                    mounts=(MountResource("root", "/", "Root"),),
                )
            )
            results = {}
            for metadata in app.metadata("a" * 64):
                key = metadata["key"]
                kwargs = app.arguments(key, metadata["params"])
                results[key] = app.bindings[key].function(**kwargs)
            self.assertEqual(results["file:first"].health, "OK")
            self.assertEqual(results["file:second"].health, "CRIT")
            self.assertIsNotNone(results["file:second"].source_at)
            self.assertIn(results["filesystem:root"].health, {"OK", "WARN", "CRIT"})
            self.assertIsNotNone(results["filesystem:root"].source_at)
            self.assertNotIn(str(directory), json.dumps(app.metadata("a" * 64)))

    def test_distinct_process_filesystem_targets_and_complete_shared_policies(self):
        app = make_app(
            NodeResources(
                "node-a",
                "Application node",
                files=(FileResource("same-id", "/private/export"),),
                processes=(
                    ProcessResource("same-id", "/private/a.pid", "/private/a"),
                    ProcessResource("worker", "/private/b.pid", "/private/b"),
                ),
                mounts=(
                    MountResource("same-id", "/private/a", "Application data"),
                    MountResource("logs", "/private/b", "Log data"),
                ),
            )
        )
        checks = app.metadata("a" * 64)
        self.assertEqual(len(checks), 5)
        self.assertEqual(
            len({item["outputs"][0]["target"]["key"] for item in checks}), 5
        )
        for entry in checks:
            kind = entry["key"].split(":")[0]
            if kind == "process":
                self.assertEqual(entry["params_owner"], "source")
                self.assertNotIn("parameter_contract", entry)
                with patch.object(LocalProcess, "available", return_value=False):
                    result = app.bindings[entry["key"]].function(
                        **app.arguments(entry["key"], {})
                    )
                self.assertEqual(result.health, "UNKNOWN")
                self.assertIsNone(result.source_at)
            else:
                expected = capacity_policy() if kind == "filesystem" else file_policy()
                self.assertEqual(
                    entry["parameter_contract"], expected["parameter_contract"]
                )
                self.assertEqual(entry["params"], expected["params"])
                self.assertEqual(
                    entry["parameter_schema"]["fields"],
                    {
                        name: field.to_dict()
                        for name, field in expected["parameters"].items()
                    },
                )
                if kind == "filesystem":
                    self.assertIn("Filesystem containing", entry["label"])
        self.assertNotIn("/private", json.dumps(checks))

    def test_resource_rename_or_relocation_keeps_logical_ids_but_replacement_does_not(
        self,
    ):
        def metadata(id, label, path):
            return make_app(
                NodeResources("node-a", files=(FileResource(id, path, label),))
            ).metadata("a" * 64)[0]

        before = metadata("daily", "Old label", "/private/old")
        moved = metadata("daily", "New label", "/private/new")
        replaced = metadata("weekly", "New label", "/private/new")
        self.assertEqual(before["key"], moved["key"])
        self.assertEqual(
            before["outputs"][0]["target"]["key"], moved["outputs"][0]["target"]["key"]
        )
        self.assertNotEqual(before["key"], replaced["key"])

    def test_duplicate_ids_partial_settings_and_bounds_reject_without_private_values(
        self,
    ):
        base = {"node_id": "node", "files": [{"id": "file", "path": "/private/export"}]}
        for raw in (
            '{"node_id":"node","node_id":"other"}',
            "not JSON",
            "x" * (48 * 1024 + 1),
            json.dumps(base | {"unknown": "private-value"}),
            json.dumps(base | {"files": base["files"] * 2}),
            json.dumps(base | {"files": [{"id": "file", "path": "private-value"}]}),
            json.dumps(
                base | {"processes": [{"id": "process", "pid_file": "/private/value"}]}
            ),
            json.dumps(base | {"interval_seconds": True}),
            json.dumps({"node_id": "node"}),
        ):
            with self.subTest(raw=raw[:60]), self.assertRaises(ValueError) as raised:
                configuration_from_settings(raw)
            self.assertNotIn("private-value", str(raised.exception))
        with self.assertRaisesRegex(ValueError, "1–512"):
            NodeResources(
                "node", files=tuple(FileResource(f"file-{i}", "/x") for i in range(513))
            )
        config = configuration_from_settings(
            json.dumps(
                {
                    "node_id": "node",
                    "files": [{"id": f"f{i}", "path": "/x"} for i in range(512)],
                }
            )
        )
        self.assertEqual(len(make_app(config).metadata("a" * 64)), 512)


class NodeResourceSnapshotTests(unittest.IsolatedAsyncioTestCase):
    async def test_path_change_revises_source_and_old_worker_keeps_original_file(self):
        with tempfile.TemporaryDirectory() as temporary, patch.dict(os.environ):
            directory = Path(temporary)
            old = directory / "old-file"
            old.write_text("old real file")
            bundles = directory / "bundles"
            settings = {
                "node_id": "node-a",
                "files": [{"id": "export", "path": str(old)}],
            }
            os.environ["MONDEK_NODE_RESOURCES_SETTINGS"] = json.dumps(settings)
            first = await snapshot("mondek_examples.node_multi:app", bundles)
            settings["files"][0]["path"] = str(directory / "missing-file")
            os.environ["MONDEK_NODE_RESOURCES_SETTINGS"] = json.dumps(settings)
            second = await snapshot("mondek_examples.node_multi:app", bundles)
            self.assertNotEqual(first["source_revision"], second["source_revision"])
            self.assertEqual(
                first["checks"][0]["outputs"], second["checks"][0]["outputs"]
            )
            self.assertNotIn(str(directory), json.dumps(first))
            os.environ["MONDEK_NODE_RESOURCES_SETTINGS"] = "broken replacement"
            with self.assertRaisesRegex(ValueError, "malformed"):
                await snapshot("mondek_examples.node_multi:app", bundles)
            for inventory, health in ((first, "OK"), (second, "CRIT")):
                outcome = await execute(
                    assignment(inventory, "file:export"), bundle_dir=bundles
                )
                self.assertTrue(outcome["complete"], outcome)
                self.assertEqual(outcome["results"][0]["health"], health)
