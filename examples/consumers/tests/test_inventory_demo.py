# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Shared target metadata and independently evaluated fixture signals."""

from __future__ import annotations

import unittest
from unittest.mock import patch

from mondek_examples import inventory_demo


class InventoryDemoTests(unittest.TestCase):
    def test_observers_publish_the_same_targets_without_acquiring_data(self) -> None:
        inventories = []
        with patch.object(
            inventory_demo.FixtureData, "__init__", side_effect=AssertionError("I/O")
        ):
            for observer in ("a", "b"):
                app = inventory_demo.make_app(observer, "http://fixture.invalid")
                inventories.append(app.metadata("a" * 64))
        self.assertEqual(inventories[0], inventories[1])
        self.assertEqual(len(inventories[0]), 5)
        outputs = [output for item in inventories[0] for output in item["outputs"]]
        self.assertEqual(len(outputs), 61)
        self.assertEqual(
            sum(
                output["target"] == inventory_demo.HOST.to_dict() for output in outputs
            ),
            60,
        )
        self.assertEqual(
            {item["environment"] for item in inventories[0]}, {"inventory-test"}
        )

    def test_one_real_input_can_change_the_last_named_signal_without_silencing_peers(
        self,
    ) -> None:
        source = inventory_demo.FixtureData("http://fixture.invalid")
        binding = inventory_demo.make_batch(45)
        for value, critical_count in ((2, 0), (9, 0), (10, 1), (12, 1), (2, 0)):
            with (
                self.subTest(value=value),
                patch.object(
                    source, "backlog", return_value=(value, "2009-09-16T12:00:00Z")
                ) as acquisition,
            ):
                results = list(binding.function(source))
            acquisition.assert_called_once_with()
            self.assertEqual(len(results), 15)
            self.assertEqual(
                sum(result.health == "CRIT" for result in results), critical_count
            )
            self.assertEqual(results[-1].key, "signal-059")
            self.assertTrue(all(result.value == value for result in results))
            self.assertTrue(
                all(result.source_at == "2009-09-16T12:00:00Z" for result in results)
            )

    def test_acquisition_failure_does_not_invent_healthy_results(self) -> None:
        source = inventory_demo.FixtureData("http://fixture.invalid")
        with patch.object(source, "backlog", side_effect=OSError("offline")):
            with self.assertRaises(OSError):
                list(inventory_demo.make_batch(0).function(source))
            with self.assertRaises(OSError):
                inventory_demo.fixture_service(source)


if __name__ == "__main__":
    unittest.main()
