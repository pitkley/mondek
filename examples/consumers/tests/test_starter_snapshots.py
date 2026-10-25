# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""The real starter entrypoints reconstruct accepted source under broken settings."""

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


def assignments(inventory):
    return [
        {
            **entry,
            "id": str(uuid.uuid4()),
            "kind": "python",
            "generation": 1,
            "source_key": entry["key"],
            "source_id": inventory["source_id"],
            "source_revision": inventory["source_revision"],
            "expected_keys": [output["key"] for output in entry["outputs"]],
        }
        for entry in inventory["checks"]
    ]


class StarterSnapshotTests(unittest.IsolatedAsyncioTestCase):
    async def test_node_preserves_original_optional_membership_and_paths(self):
        with tempfile.TemporaryDirectory() as temporary, patch.dict(os.environ):
            directory = Path(temporary)
            bundles = directory / "bundles"
            for name in list(os.environ):
                if name.startswith("MONDEK_LOCAL_"):
                    os.environ.pop(name)
            os.environ["MONDEK_LOCAL_NODE_ID"] = "original-node"
            first = await snapshot("mondek_examples.node_local:app", bundles)
            config = assignments(first)[0]
            os.environ["MONDEK_LOCAL_INTERVAL"] = "private invalid interval"
            with self.assertRaisesRegex(ValueError, "must be an integer") as raised:
                await snapshot("mondek_examples.node_local:app", bundles)
            self.assertNotIn("private invalid interval", str(raised.exception))
            os.environ.pop("MONDEK_LOCAL_INTERVAL")
            file = directory / "private-export"
            file.write_text("real ordinary file")
            os.environ.update(
                MONDEK_LOCAL_FILE=str(file),
                MONDEK_LOCAL_FILE_ID="export",
                MONDEK_LOCAL_PID_FILE=str(directory / "absent.pid"),
                MONDEK_LOCAL_EXPECTED_EXECUTABLE="/private/service",
                MONDEK_LOCAL_PROCESS_ID="service",
            )
            old = await execute(config, bundle_dir=bundles)
            self.assertTrue(old["complete"], old)
            self.assertEqual(len(first["checks"]), 1)
            second = await snapshot("mondek_examples.node_local:app", bundles)
            self.assertEqual(len(second["checks"]), 3)
            self.assertNotEqual(first["source_revision"], second["source_revision"])
            self.assertNotIn(str(directory), json.dumps(second))
            for name in list(os.environ):
                if name.startswith("MONDEK_LOCAL_"):
                    os.environ.pop(name)
            with self.assertRaisesRegex(ValueError, "MONDEK_LOCAL_NODE_ID"):
                await snapshot("mondek_examples.node_local:app", bundles)
            for config in assignments(second):
                prepared = await execute(config, prepare=True, bundle_dir=bundles)
                self.assertTrue(prepared["prepared"], prepared)
                outcome = await execute(config, bundle_dir=bundles)
                self.assertTrue(outcome["complete"], outcome)
                if config["source_key"] == "configured-file":
                    self.assertEqual(outcome["results"][0]["health"], "OK")
            # Required and optional inputs are still absent outside construction.
            self.assertNotIn("MONDEK_LOCAL_NODE_ID", os.environ)
            self.assertNotIn("MONDEK_LOCAL_FILE", os.environ)

    async def test_prometheus_old_entrypoint_prepares_under_malformed_current_json(
        self,
    ):
        settings = json.dumps(
            {
                "url": "http://private-prometheus:9090",
                "targets": {
                    "private-series:9090": {
                        "key": "service",
                        "label": "Service",
                        "kind": "service",
                    }
                },
            }
        )
        with (
            tempfile.TemporaryDirectory() as temporary,
            patch.dict(os.environ, {"MONDEK_PROMETHEUS_SETTINGS": settings}),
        ):
            bundles = Path(temporary)
            first = await snapshot("mondek_examples.prometheus_local:app", bundles)
            self.assertNotIn("private-prometheus", json.dumps(first))
            self.assertNotIn("private-series", json.dumps(first))
            os.environ["MONDEK_PROMETHEUS_SETTINGS"] = "broken private replacement"
            with self.assertRaisesRegex(ValueError, "malformed") as raised:
                await snapshot("mondek_examples.prometheus_local:app", bundles)
            self.assertNotIn("broken private replacement", str(raised.exception))
            prepared = await execute(
                assignments(first)[0], prepare=True, bundle_dir=bundles
            )
            self.assertTrue(prepared["prepared"], prepared)
            self.assertEqual(
                os.environ["MONDEK_PROMETHEUS_SETTINGS"],
                "broken private replacement",
            )
