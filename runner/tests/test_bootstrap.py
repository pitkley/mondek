# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0

from __future__ import annotations

import json
import os
import shlex
import subprocess
import sys
import tempfile
import tomllib
import unittest
from pathlib import Path
from unittest.mock import patch

from mondek_runner.bootstrap import create_project

SDK = Path(__file__).resolve().parents[1]


class BootstrapTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.destination = self.root / "my monitoring"

    def cli(self, *arguments):
        return subprocess.run(
            [sys.executable, "-m", "mondek_runner", *arguments],
            text=True,
            capture_output=True,
            timeout=20,
        )

    def project_command(self, *arguments):
        return subprocess.run(
            [sys.executable, *arguments],
            cwd=self.destination,
            env={
                **os.environ,
                "PYTHONPATH": str(self.destination / "src")
                + os.pathsep
                + os.environ.get("PYTHONPATH", ""),
                "MONDEK_CONTROLLER_URL": "http://127.0.0.1:1",
            },
            text=True,
            capture_output=True,
            timeout=30,
        )

    def test_init_creates_source_layout_without_install_or_registration(self):
        result = self.cli("init", str(self.destination), "--sdk-path", str(SDK))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("uv sync --project '", result.stdout)
        with (self.destination / "pyproject.toml").open("rb") as stream:
            project = tomllib.load(stream)
        self.assertEqual(project["tool"]["uv"]["sources"]["mondek"]["path"], str(SDK))
        self.assertTrue(project["tool"]["uv"]["sources"]["mondek"]["editable"])
        self.assertEqual(
            project["tool"]["uv"]["build-backend"]["module-name"], "monitoring"
        )
        self.assertFalse((self.destination / ".venv").exists())
        self.assertFalse((self.destination / ".mondek-state").exists())
        self.assertFalse((self.destination / "uv.lock").exists())
        self.assertEqual((self.destination / "sample-backlog.txt").read_text(), "0\n")

    def test_registry_generation_has_no_checkout_dependency(self):
        result = self.cli("init", str(self.destination))
        self.assertEqual(result.returncode, 0, result.stderr)
        project = tomllib.loads((self.destination / "pyproject.toml").read_text())
        self.assertNotIn("sources", project.get("tool", {}).get("uv", {}))
        self.assertIn("mondek==", project["project"]["dependencies"][0])
        self.assertNotIn(str(SDK.parent), (self.destination / "README.md").read_text())

    def test_generated_project_does_not_assign_users_new_code_to_template_author(self):
        create_project(str(self.destination), str(SDK))
        for name in ("pyproject.toml", "src/monitoring/__init__.py"):
            text = (self.destination / name).read_text()
            self.assertIn("SPDX-License-Identifier: Apache-2.0", text)
            self.assertNotIn("Copyright", text)
        for name in ("src/monitoring/app.py", "tests/test_backlog.py"):
            text = (self.destination / name).read_text()
            self.assertIn("Copyright 2026 Pit Kleyersburg", text)
            self.assertIn("SPDX-License-Identifier: Apache-2.0", text)

    def test_generated_policy_tests_pass(self):
        create_project(str(self.destination), str(SDK))
        result = self.project_command("-m", "unittest", "discover", "-s", "tests")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Ran 3 tests", result.stderr)

    def test_readme_treats_placeholder_spelling_in_paths_as_literal_data(self):
        destination = create_project(
            str(self.root / "__CHECKOUT__ __PROJECT__"), str(SDK)
        )
        readme = (destination / "README.md").read_text()
        self.assertIn(f"cd {shlex.quote(str(destination))}\n", readme)
        self.assertIn(f"uv sync --project {shlex.quote(str(destination))}\n", readme)
        self.assertIn(str(SDK), readme)

    def test_generated_check_uses_real_discovery_and_worker_execution(self):
        create_project(str(self.destination), str(SDK))
        validate = self.project_command(
            "-m", "mondek_runner", "validate", "--consumer", "monitoring.app:app"
        )
        self.assertEqual(validate.returncode, 0, validate.stderr)
        inventory = json.loads(validate.stdout)
        self.assertEqual(inventory["checks"][0]["key"], "queue-backlog")
        for count, health in ((0, "OK"), (5, "WARN"), (10, "CRIT"), (0, "OK")):
            with self.subTest(count=count):
                (self.destination / "sample-backlog.txt").write_text(f"{count}\n")
                result = self.project_command(
                    "-m",
                    "mondek_runner",
                    "run",
                    "--consumer",
                    "monitoring.app:app",
                    "--check",
                    "queue-backlog",
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                observation = json.loads(result.stdout)
                self.assertEqual(observation["results"][0]["health"], health)
        self.assertFalse((self.destination / ".mondek-state").exists())

    def test_existing_paths_are_untouched_including_empty_and_dangling_links(self):
        for kind in ("directory", "file", "symlink"):
            with self.subTest(kind=kind):
                destination = self.root / kind
                if kind == "directory":
                    destination.mkdir()
                elif kind == "file":
                    destination.write_text("keep me")
                else:
                    destination.symlink_to(self.root / "missing")
                with self.assertRaises(FileExistsError):
                    create_project(str(destination), str(SDK))
                if kind == "directory":
                    self.assertEqual(list(destination.iterdir()), [])
                elif kind == "file":
                    self.assertEqual(destination.read_text(), "keep me")
                else:
                    self.assertEqual(destination.readlink(), self.root / "missing")

    def test_invalid_sdk_and_missing_parent_do_not_create_project(self):
        for sdk in (self.root / "missing", self.root):
            with self.subTest(sdk=sdk):
                with self.assertRaises((FileNotFoundError, ValueError)):
                    create_project(str(self.destination), str(sdk))
                self.assertFalse(self.destination.exists())
        with self.assertRaises(FileNotFoundError):
            create_project(str(self.root / "missing" / "project"), str(SDK))
        self.assertFalse((self.root / "missing").exists())

    def test_wrong_project_is_rejected_before_writing(self):
        (self.root / "pyproject.toml").write_text('[project]\nname = "elsewhere"\n')
        with self.assertRaisesRegex(ValueError, "runner directory"):
            create_project(str(self.destination), str(self.root))
        self.assertFalse(self.destination.exists())

    def test_control_characters_are_rejected(self):
        for value in ("", "project\nname", "project\x00name"):
            with self.subTest(value=value):
                with self.assertRaises(ValueError):
                    create_project(value, str(SDK))
        self.assertEqual(list(self.root.iterdir()), [])

    def test_write_failure_removes_only_the_new_project(self):
        unrelated = self.root / "preserved"
        unrelated.write_text("keep")
        original = Path.open

        def fail_sample(path, *args, **kwargs):
            if path.name == "sample-backlog.txt":
                raise OSError("disk full")
            return original(path, *args, **kwargs)

        with patch.object(Path, "open", fail_sample):
            with self.assertRaisesRegex(OSError, "disk full"):
                create_project(str(self.destination), str(SDK))
        self.assertFalse(self.destination.exists())
        self.assertEqual(unrelated.read_text(), "keep")

    def test_init_rejects_execution_flags(self):
        for arguments in (
            (
                "init",
                str(self.destination),
                "--sdk-path",
                str(SDK),
                "--consumer",
                "other:app",
            ),
        ):
            with self.subTest(arguments=arguments):
                result = self.cli(*arguments)
                self.assertEqual(result.returncode, 2)
                self.assertFalse(self.destination.exists())


if __name__ == "__main__":
    unittest.main()
