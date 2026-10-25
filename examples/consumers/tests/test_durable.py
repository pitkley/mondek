# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Consumer-owned file semantics and source membership for durable-rule examples."""

from __future__ import annotations

import json
import os
import tempfile
import unittest
import uuid
from pathlib import Path
from unittest.mock import patch

from mondek_examples import durable
from mondek_runner import bundle
from mondek_runner.runtime import execute


class DurableVolumeTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.path = Path(self.temporary.name) / "orders.queue"
        self.settings = json.dumps(
            [{"id": "orders", "label": "Orders volume", "path": str(self.path)}]
        )

    def test_real_file_boundaries_and_recovery_follow_received_parameters(self) -> None:
        source = durable.VolumeFile(str(self.path))
        params = {"warning_items": 5, "critical_items": 10}
        for value, health in ((0, "OK"), (5, "WARN"), (10, "CRIT"), (0, "OK")):
            with self.subTest(value=value):
                self.path.write_text(f"{value}\n")
                result = durable.inspect_pending(source, params)
                self.assertEqual(result.health, health)
                self.assertEqual(result.value, value)
                self.assertIsNotNone(result.source_at)
        self.path.write_text("12\n")
        self.assertEqual(durable.inspect_pending(source, durable.DEFAULTS).health, "OK")
        self.assertEqual(durable.inspect_pending(source, params).health, "CRIT")

    def test_missing_invalid_and_oversized_input_preserve_unknown_expected_result(
        self,
    ) -> None:
        source = durable.VolumeFile(str(self.path))
        for content in (None, "invalid", "-1", "1000001", "0" * 65, "1.5"):
            with self.subTest(content=content):
                if content is not None:
                    self.path.write_text(content)
                result = durable.inspect_pending(source, durable.DEFAULTS)
                self.assertEqual(result.key, "pending")
                self.assertEqual(result.health, "UNKNOWN")
                self.assertIsNone(result.source_at)
        self.path.write_bytes(b"\xff\xfe")
        self.assertEqual(
            durable.inspect_pending(source, durable.DEFAULTS).health, "UNKNOWN"
        )

    def test_logical_volume_identity_and_schema_survive_observer_changes(self) -> None:
        inventories = [
            durable.make_app(node, self.settings).metadata("a" * 64)
            for node in ("node-a", "node-b")
        ]
        self.assertEqual(len(inventories[0]), 1)
        for inventory in inventories:
            entry = inventory[0]
            self.assertEqual(entry["key"], "volume:orders")
            self.assertEqual(entry["environment"], "production")
            self.assertEqual(entry["outputs"][0]["target"]["key"], "volume:orders")
            self.assertEqual(entry["outputs"][0]["target"]["kind"], "volume")
            self.assertEqual(entry["parameter_contract"], durable.CONTRACT)
            self.assertEqual(entry["params"], durable.DEFAULTS)
            self.assertNotIn(str(self.path), json.dumps(inventory))
        self.assertEqual(
            inventories[0][0]["parameter_schema"], inventories[1][0]["parameter_schema"]
        )

    def test_missing_input_never_withdraws_declared_membership(self) -> None:
        app = durable.make_app("node-a", self.settings)
        self.assertFalse(self.path.exists())
        self.assertEqual(len(app.metadata("a" * 64)), 1)
        self.assertEqual(durable.make_app("node-a", "[]").metadata("a" * 64), [])
        self.assertEqual(
            app.private_settings()["construction_environment"][
                "MONDEK_VOLUME_DECLARATIONS"
            ],
            self.settings,
        )

    def test_factory_binds_each_file_without_discovery_io(self) -> None:
        other = self.path.with_name("billing.queue")
        raw = json.dumps(
            [
                {"id": "orders", "label": "Orders", "path": str(self.path)},
                {"id": "billing", "label": "Billing", "path": str(other)},
            ]
        )
        with patch.object(
            durable.VolumeFile, "__init__", side_effect=AssertionError("constructed")
        ):
            app = durable.make_app("node-a", raw)
            self.assertEqual(len(app.metadata("a" * 64)), 2)
        self.assertEqual(
            app.arguments("volume:orders", durable.DEFAULTS)["source"].path, self.path
        )
        self.assertEqual(
            app.arguments("volume:billing", durable.DEFAULTS)["source"].path, other
        )

    def test_invalid_declarations_fail_instead_of_silently_reducing_coverage(
        self,
    ) -> None:
        entry = {"id": "orders", "label": "Orders", "path": str(self.path)}
        for raw in (
            "",
            "{}",
            "null",
            "[",
            json.dumps([entry, entry]),
            json.dumps([{**entry, "path": "relative"}]),
            '[{"id":"a","id":"b","label":"x","path":"/x"}]',
        ):
            with self.subTest(raw=raw), self.assertRaises(ValueError):
                durable.make_app("node-a", raw)

    def test_frozen_declaration_value_takes_precedence_over_mutable_file(self) -> None:
        path = self.path.with_name("volumes.json")
        path.write_text("[]")
        with patch.dict(
            "os.environ",
            {
                "MONDEK_VOLUME_DECLARATIONS": self.settings,
                "MONDEK_VOLUME_DECLARATIONS_FILE": str(path),
            },
        ):
            self.assertEqual(durable.declared_settings(), self.settings)


class DurableVolumeSnapshotTests(unittest.IsolatedAsyncioTestCase):
    async def test_accepted_worker_retains_declarations_when_local_settings_change(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            data = root / "orders.queue"
            data.write_text("12\n")
            settings = root / "volumes.json"
            settings.write_text(
                json.dumps(
                    [
                        {"id": "orders", "label": "Orders", "path": str(data)},
                    ]
                )
            )
            bundles = root / "bundles"
            with patch.dict(
                os.environ,
                {
                    "MONDEK_RULES_NODE": "node-a",
                    "MONDEK_VOLUME_DECLARATIONS_FILE": str(settings),
                },
            ):
                os.environ.pop("MONDEK_VOLUME_DECLARATIONS", None)
                inventory = await bundle.snapshot(
                    "mondek_examples.durable:app", bundles
                )
                entry = inventory["checks"][0]
                assignment = {
                    **entry,
                    "id": str(uuid.uuid4()),
                    "kind": "python",
                    "generation": 1,
                    "source_key": entry["key"],
                    "source_id": inventory["source_id"],
                    "source_revision": inventory["source_revision"],
                    "expected_keys": ["pending"],
                    "params": {"warning_items": 5, "critical_items": 10},
                }
                for replacement in ("[]", "["):
                    with self.subTest(replacement=replacement):
                        settings.write_text(replacement)
                        if replacement == "[":
                            with self.assertRaises(ValueError):
                                await bundle.snapshot(
                                    "mondek_examples.durable:app", bundles
                                )
                        outcome = await execute(assignment, bundle_dir=bundles)
                        self.assertTrue(outcome["complete"], outcome)
                        self.assertEqual(outcome["results"][0]["health"], "CRIT")
                        self.assertEqual(outcome["results"][0]["value"], 12)


if __name__ == "__main__":
    unittest.main()
