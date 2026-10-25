# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Prebuilt CI must preserve execution and fail closed on missing/wrong images."""

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import ci_images

from scripts import ci


class PrebuiltImagesTests(unittest.TestCase):
    def setUp(self):
        ci_images._overlays.clear()
        ci_images._verified.clear()

    def test_focused_browser_selection_preserves_audits_and_omits_service_suites(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output = root / ".local/ci"
            output.mkdir(parents=True)
            (output / "images.json").write_text(
                json.dumps(
                    {
                        f"{kind}/Dockerfile": {"id": f"sha256:{kind}"}
                        for kind in ("controller", "runner")
                    }
                )
            )
            with (
                patch.object(ci, "ROOT", root),
                patch.object(
                    sys,
                    "argv",
                    [
                        "ci.py",
                        "packaged",
                        "--mode",
                        "browser",
                        "--browser-suites",
                        "inventory coverage",
                    ],
                ),
                patch.dict(os.environ, {}, clear=True),
                patch.object(
                    ci.subprocess,
                    "run",
                    return_value=subprocess.CompletedProcess([], 0),
                ) as run,
            ):
                ci.main()
            commands = [call.args[0] for call in run.call_args_list]
            self.assertEqual(len(commands), 5)
            self.assertIn("scripts/runtime_licenses.py", commands[0])
            self.assertIn("scripts/image_licenses.py", commands[1])
            self.assertIn("scripts/image_licenses.py", commands[2])
            self.assertEqual(commands[3][-2:], ["--suite", "inventory"])
            self.assertEqual(commands[4][-2:], ["--suite", "coverage"])

    def test_invalid_browser_selection_fails_before_any_commands(self):
        for suites in ("inventory typo", "inventory inventory", "inventory;echo"):
            with (
                self.subTest(suites=suites),
                patch.object(
                    sys,
                    "argv",
                    [
                        "ci.py",
                        "packaged",
                        "--mode",
                        "browser",
                        "--browser-suites",
                        suites,
                    ],
                ),
                patch.object(ci.subprocess, "run") as run,
                self.assertRaises(SystemExit),
            ):
                ci.main()
            run.assert_not_called()

    def test_ordinary_local_commands_are_unchanged(self):
        command = ["docker", "compose", "-p", "owned", "up", "--build"]
        self.assertEqual(ci_images.prebuilt_command(command, {}), command)

    def test_reuse_verifies_digest_removes_build_and_keeps_project_and_operation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            manifest = root / "images.json"
            manifest.write_text(
                json.dumps(
                    {
                        "controller/Dockerfile": {
                            "tag": "ci:tested",
                            "id": "sha256:tested",
                        }
                    }
                )
            )
            config = {
                "services": {
                    "controller": {
                        "build": {
                            "context": str(root),
                            "dockerfile": "controller/Dockerfile",
                        }
                    },
                    "postgres": {"image": "postgres:pinned"},
                }
            }
            env = {"MONDEK_CI_IMAGES": str(manifest)}
            prefix = ["docker", "compose", "-p", "owned"]
            with (
                patch.object(ci_images, "ROOT", root),
                patch.object(
                    ci_images.subprocess,
                    "check_output",
                    side_effect=[json.dumps(config), "sha256:tested\n"],
                ) as read,
            ):
                command = ci_images.prebuilt_command(
                    [*prefix, "up", "--build", "controller"], env
                )
                self.assertEqual(command[:4], prefix)
                self.assertEqual(command[-3:], ["up", "--no-build", "controller"])
                overlay = Path(command[-4]).read_text()
                self.assertIn("build: !reset null", overlay)
                self.assertIn('image: "sha256:tested"', overlay)
                self.assertNotIn("postgres", overlay)
                self.assertIsNone(
                    ci_images.prebuilt_command([*prefix, "build", "controller"], env)
                )
                self.assertEqual(read.call_count, 2)

    def test_missing_image_or_changed_identity_cannot_fall_back_to_a_build(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            manifest = root / "images.json"
            env = {"MONDEK_CI_IMAGES": str(manifest)}
            config = {
                "services": {
                    "controller": {
                        "build": {
                            "context": str(root),
                            "dockerfile": "controller/Dockerfile",
                        }
                    }
                }
            }
            for entries, expected, outputs in [
                ({}, KeyError, [json.dumps(config)]),
                (
                    {
                        "controller/Dockerfile": {
                            "tag": "ci:tested",
                            "id": "sha256:tested",
                        }
                    },
                    ValueError,
                    [json.dumps(config), "sha256:changed"],
                ),
            ]:
                manifest.write_text(json.dumps(entries))
                with (
                    self.subTest(expected=expected),
                    patch.object(ci_images, "ROOT", root),
                    patch.object(
                        ci_images.subprocess, "check_output", side_effect=outputs
                    ),
                    self.assertRaises(expected),
                ):
                    ci_images.prebuilt_command(
                        ["docker", "compose", "up", "--build"], env
                    )


class PackagedFailuresTests(unittest.TestCase):
    def test_independent_suites_continue_but_failed_run_cannot_pass(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            output = root / ".local/ci"
            output.mkdir(parents=True)
            (output / "images.json").write_text(
                json.dumps(
                    {
                        f"{name}/Dockerfile": {"id": f"sha256:{name}"}
                        for name in ("controller", "runner")
                    }
                )
            )
            for failing_command, later_stage in [
                ("tests/e2e/acceptance.py", "Browser lifecycle"),
                ("scripts/runtime_licenses.py", None),
            ]:

                def execute(command, **kwargs):
                    return subprocess.CompletedProcess(
                        command, 1 if failing_command in command else 0
                    )

                with (
                    self.subTest(failing_command=failing_command),
                    patch.object(ci, "ROOT", root),
                    patch.object(sys, "argv", ["ci.py", "packaged", "--mode", "smoke"]),
                    patch.dict(
                        os.environ, {"GITHUB_STEP_SUMMARY": str(root / "summary.md")}
                    ),
                    patch.object(ci.subprocess, "run", side_effect=execute),
                    self.assertRaises((SystemExit, subprocess.CalledProcessError)),
                ):
                    ci.main()
                measurements = json.loads(
                    (output / "packaged-timings.json").read_text()
                )
                self.assertTrue(any(row["returncode"] == 1 for row in measurements))
                summary = (root / "summary.md").read_text()
                self.assertIn("| Fail |", summary)
                self.assertIn(failing_command, summary)
                self.assertIn("job evidence artifact", summary)
                self.assertIn("Integration and browser tests", summary)
                for row in measurements:
                    self.assertEqual(summary.count(f"| {row['stage']} |"), 1)
                if later_stage:
                    self.assertIn(later_stage, [row["stage"] for row in measurements])
                else:
                    self.assertEqual(len(measurements), 1)
