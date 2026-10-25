# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Node-local behavior using ordinary files and controlled process-identity reads."""

from __future__ import annotations

import io
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from mondek_runner.authoring import validate_params

with patch.dict(os.environ, {"MONDEK_LOCAL_NODE_ID": "test-node"}):
    from mondek_examples import node_local


class NodeLocalTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.file = self.directory / "ordinary-file"
        self.pid_file = self.directory / "application.pid"
        self.files = node_local.LocalFile(str(self.file))
        self.params = {
            "minimum_bytes": 1,
            "warn_age_seconds": 3600,
            "crit_age_seconds": 7200,
        }

    def test_explicit_identity_optional_membership_and_private_access_settings(self):
        root_only = node_local.make_app(node_local.NodeConfiguration("node-a"))
        self.assertEqual(list(root_only.bindings), ["root-filesystem"])
        root_result = root_only.bindings["root-filesystem"].function(
            {"warn_percent": 80, "crit_percent": 90}
        )
        self.assertIn(root_result.health, {"OK", "WARN", "CRIT"})
        self.assertIsNotNone(root_result.source_at)
        self.assertGreaterEqual(root_result.value, 0)
        self.assertLessEqual(root_result.value, 100)

        consumer = node_local.make_app(
            node_local.NodeConfiguration(
                "node-a",
                "My node",
                file_path=str(self.file),
                pid_file=str(self.pid_file),
                expected_executable="/private/application/bin/service",
                interval_seconds=60,
            )
        )
        metadata = consumer.metadata("a" * 64)
        self.assertEqual(len(metadata), 3)
        self.assertEqual({entry["interval_seconds"] for entry in metadata}, {60})
        self.assertEqual({entry["freshness_seconds"] for entry in metadata}, {180})
        self.assertEqual({entry["environment"] for entry in metadata}, {"node-a"})
        self.assertNotIn(str(self.directory), json.dumps(metadata))
        self.assertNotIn("/private/application", json.dumps(metadata))
        for entry in metadata:
            self.assertEqual(
                set(entry["params"]), set(entry["parameter_schema"]["fields"])
            )
            validate_params(entry["params"], entry["parameter_schema"], entry["params"])
        self.assertEqual(
            metadata[0]["parameter_contract"], "root-filesystem.used-percent.v1"
        )
        self.assertEqual(
            metadata[1]["parameter_contract"], "regular-file.size-and-age.v1"
        )
        self.assertNotIn("parameter_contract", metadata[-1])
        self.assertEqual(metadata[-1]["params_owner"], "source")
        self.assertEqual(metadata[1]["params_owner"], "ui")

    def test_bulk_contracts_match_across_nodes_and_private_paths_but_not_check_kinds(
        self,
    ):
        inventories = []
        for node, path in (
            ("node-a", "/srv/first-export"),
            ("node-b", "/opt/second-export"),
        ):
            consumer = node_local.make_app(
                node_local.NodeConfiguration(
                    node,
                    file_path=path,
                    pid_file=f"/run/{node}.pid",
                    expected_executable=f"/opt/{node}/service",
                )
            )
            self.assertEqual(consumer.source_id, "node-local")
            inventories.append(
                {entry["key"]: entry for entry in consumer.metadata("a" * 64)}
            )
        contracts = set()
        for key in ("root-filesystem", "configured-file"):
            first, second = (inventory[key] for inventory in inventories)
            self.assertEqual(first["parameter_contract"], second["parameter_contract"])
            self.assertEqual(first["parameter_schema"], second["parameter_schema"])
            self.assertEqual(first["params_owner"], "ui")
            self.assertEqual(second["params_owner"], "ui")
            self.assertNotEqual(
                first["outputs"][0]["target"]["key"],
                second["outputs"][0]["target"]["key"],
            )
            contracts.add(first["parameter_contract"])
        self.assertEqual(len(contracts), 2)
        for inventory in inventories:
            self.assertNotIn("parameter_contract", inventory["configured-process"])
            self.assertEqual(inventory["configured-process"]["params_owner"], "source")

    def test_logical_target_ids_survive_renames_and_paths_but_change_explicitly(self):
        def metadata(label, path, file_id="application"):
            return node_local.make_app(
                node_local.NodeConfiguration(
                    "node-a",
                    label,
                    file_path=path,
                    file_id=file_id,
                )
            ).metadata("a" * 64)[1]

        before = metadata("Before", "/private/before")
        renamed = metadata("After", "/private/after")
        replaced = metadata("After", "/private/after", "new-export")
        self.assertEqual(before["key"], renamed["key"])
        self.assertEqual(
            before["outputs"][0]["target"]["key"],
            renamed["outputs"][0]["target"]["key"],
        )
        self.assertNotEqual(
            before["outputs"][0]["target"]["key"],
            replaced["outputs"][0]["target"]["key"],
        )

    def test_settings_reject_ambiguous_identity_and_partial_process_configuration(self):
        with self.assertRaisesRegex(ValueError, "MONDEK_LOCAL_NODE_ID"):
            node_local.configuration_from_environment({})
        for values in (
            {"node_id": ""},
            {"node_id": "not stable"},
            {"node_id": "a" * 65},
            {"node_id": "node", "file_path": "relative"},
            {"node_id": "node", "file_path": "/path\n"},
            {"node_id": "node", "pid_file": "/run/service.pid"},
            {"node_id": "node", "expected_executable": "/bin/service"},
            {"node_id": "node", "interval_seconds": 4},
        ):
            with self.subTest(values=values), self.assertRaises(ValueError):
                node_local.NodeConfiguration(**values)
        config = node_local.configuration_from_environment(
            {
                "MONDEK_LOCAL_NODE_ID": "node-a",
                "MONDEK_LOCAL_NODE_LABEL": "Node A",
                "MONDEK_LOCAL_FILE": "/srv/export",
                "MONDEK_LOCAL_FILE_ID": "export",
                "MONDEK_LOCAL_PID_FILE": "/run/service.pid",
                "MONDEK_LOCAL_EXPECTED_EXECUTABLE": "/usr/bin/service",
                "MONDEK_LOCAL_PROCESS_ID": "service",
                "MONDEK_LOCAL_INTERVAL": "45",
            }
        )
        self.assertEqual(config.interval_seconds, 45)
        self.assertEqual(config.process_id, "service")

    def test_file_size_and_age_boundaries_are_real_fresh_inspections(self):
        now = 1_800_000_000_000_000_000
        for size, age, health in (
            (1, 3600, "OK"),
            (1, 3600.5, "WARN"),
            (1, 7200, "WARN"),
            (1, 7200.5, "CRIT"),
            (0, 0, "CRIT"),
            (10, -3, "CRIT"),
        ):
            with self.subTest(size=size, age=age):
                self.file.write_bytes(b"x" * size)
                modified = now - int(age * 1_000_000_000)
                os.utime(self.file, ns=(modified, modified))
                with patch.object(node_local.time, "time_ns", return_value=now):
                    result = node_local.inspect_file(self.files, self.params)
                self.assertEqual(result.health, health)
                self.assertIsNotNone(result.source_at)
                self.assertNotIn(str(self.directory), result.summary)
        self.file.write_bytes(b"")
        self.assertEqual(
            node_local.inspect_file(
                self.files, self.params | {"minimum_bytes": 0}
            ).health,
            "OK",
        )

    def test_missing_unreadable_nonregular_and_replaced_files_are_distinct(self):
        missing = node_local.inspect_file(self.files, self.params)
        self.assertEqual(missing.health, "CRIT")
        self.assertIn("missing", missing.summary)
        with patch.object(
            self.files,
            "inspect",
            side_effect=PermissionError(13, "Permission denied", str(self.file)),
        ):
            inaccessible = node_local.inspect_file(self.files, self.params)
        self.assertEqual(inaccessible.health, "UNKNOWN")
        self.assertIsNone(inaccessible.source_at)
        self.assertNotIn(str(self.directory), inaccessible.summary)
        self.file.mkdir()
        self.assertEqual(
            node_local.inspect_file(self.files, self.params).health, "CRIT"
        )
        self.file.rmdir()
        os.mkfifo(self.file)
        self.assertEqual(
            node_local.inspect_file(self.files, self.params).health, "CRIT"
        )
        self.file.unlink()
        self.file.write_bytes(b"original")
        replacement = self.directory / "replacement"
        replacement.write_bytes(b"replaced")
        original_stat = Path.stat

        def replace_before_final_stat(path, *args, **kwargs):
            if path == self.file:
                replacement.replace(self.file)
            return original_stat(path, *args, **kwargs)

        with patch.object(Path, "stat", replace_before_final_stat):
            changed = node_local.inspect_file(self.files, self.params)
        self.assertEqual(changed.health, "UNKNOWN")
        self.assertIsNone(changed.source_at)

    def test_process_exact_executable_and_in_inspection_birth_identity(self):
        self.pid_file.write_text("42\n")
        process = node_local.LocalProcess(str(self.pid_file), "/opt/service")
        for after, executable, health, text in (
            (100, "/opt/service", "OK", "running"),
            (100, "/opt/other", "CRIT", "different executable"),
            (101, "/opt/service", "UNKNOWN", "reused during inspection"),
        ):
            with self.subTest(after=after, executable=executable):
                with (
                    patch.object(process, "available", return_value=True),
                    patch.object(
                        process,
                        "identity",
                        side_effect=[
                            node_local.ProcessIdentity(42, 100, "S"),
                            node_local.ProcessIdentity(42, after, "R"),
                        ],
                    ),
                    patch.object(process, "executable", return_value=executable),
                ):
                    result = process.inspect()
                self.assertEqual(result.health, health)
                self.assertIn(text, result.summary)
                self.assertEqual(result.source_at is None, health == "UNKNOWN")

    def test_process_missing_inaccessible_unsupported_and_changed_pid_file(self):
        self.pid_file.write_text("42\n")
        process = node_local.LocalProcess(str(self.pid_file), "/opt/service")
        for error, health in (
            (FileNotFoundError(), "CRIT"),
            (PermissionError(), "UNKNOWN"),
        ):
            with (
                patch.object(process, "available", return_value=True),
                patch.object(process, "identity", side_effect=error),
            ):
                self.assertEqual(process.inspect().health, health)
        with patch.object(process, "available", return_value=False):
            unsupported = process.inspect()
        self.assertEqual(unsupported.health, "UNKNOWN")
        self.assertIn("Linux /proc", unsupported.summary)

        def replace_pid(_):
            self.pid_file.write_text("43\n")
            return "/opt/service"

        with (
            patch.object(process, "available", return_value=True),
            patch.object(
                process,
                "identity",
                return_value=node_local.ProcessIdentity(42, 100, "S"),
            ),
            patch.object(process, "executable", side_effect=replace_pid),
        ):
            changed = process.inspect()
        self.assertEqual(changed.health, "UNKNOWN")
        self.assertIn("PID file changed", changed.summary)
        for value in ("0", "42 43", "42\n43", "x", "4" * 65, "2147483648"):
            self.pid_file.write_text(value)
            with self.subTest(value=value), self.assertRaises(ValueError):
                process.read_pid()

    def test_linux_stat_parser_handles_parentheses_and_checks_size_and_pid(self):
        process = node_local.LocalProcess(str(self.pid_file), "/opt/service")
        raw = b"42 (name with ) spaces) S " + b"0 " * 18 + b"100\n"
        with patch.object(Path, "open", return_value=io.BytesIO(raw)):
            self.assertEqual(
                process.identity(42), node_local.ProcessIdentity(42, 100, "S")
            )
        for raw in (raw.replace(b"42 (", b"41 ("), b"x" * 8193):
            with (
                patch.object(Path, "open", return_value=io.BytesIO(raw)),
                self.assertRaises(ValueError),
            ):
                process.identity(42)


if __name__ == "__main__":
    unittest.main()
