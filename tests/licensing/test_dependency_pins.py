# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
import dependency_pins  # noqa: E402


class DependencyPinsTest(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        names = dependency_pins.PYTHON_IMAGES + [
            "README.md",
            "devenv.yaml",
            "DEVELOPMENT.md",
            "docs/GETTING-STARTED.md",
            "licensing/runtime-sources.json",
            "runner/pyproject.toml",
            "licensing/pyproject.toml",
            ".github/workflows/ci.yml",
            "controller/Dockerfile",
            "controller/mix.exs",
            "controller/assets/package.json",
            "controller/assets/package-lock.json",
            "tests/browser/package.json",
            "tests/browser/package-lock.json",
            "tests/browser/Dockerfile",
        ]
        for name in names:
            destination = self.root / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(dependency_pins.ROOT / name, destination)

    def replace(self, name: str, before: str, after: str) -> None:
        path = self.root / name
        self.assertIn(before, path.read_text())
        path.write_text(path.read_text().replace(before, after))

    def test_browser_image_update_requires_matching_package_and_lock(self) -> None:
        dependency_pins.check(self.root)
        self.replace("tests/browser/Dockerfile", "playwright:v", "playwright:v99.")
        with self.assertRaisesRegex(ValueError, "Coordinate Playwright"):
            dependency_pins.check(self.root)

    def test_npm_manifest_update_cannot_keep_old_lock(self) -> None:
        self.replace(
            "controller/assets/package.json", '"esbuild": "', '"esbuild": "99.'
        )
        with self.assertRaisesRegex(ValueError, "Refresh npm lock declarations"):
            dependency_pins.check(self.root)

    def test_shipped_icon_dependency_cannot_keep_old_lock(self) -> None:
        self.replace(
            "controller/assets/package.json",
            '"lucide-static": "',
            '"lucide-static": "99.',
        )
        with self.assertRaisesRegex(ValueError, "Refresh npm lock declarations"):
            dependency_pins.check(self.root)

    def test_ci_devenv_must_meet_supported_minimum(self) -> None:
        self.replace("devenv.yaml", ">=2.3.1", ">=2.3.2")
        with self.assertRaisesRegex(ValueError, "below supported minimum"):
            dependency_pins.check(self.root)

    def test_prose_and_newer_ci_devenv_do_not_define_dependency_pins(self) -> None:
        for name in ["README.md", "DEVELOPMENT.md", "docs/GETTING-STARTED.md"]:
            (self.root / name).write_text("Ordinary reworded installation guidance.")
        self.replace(".github/workflows/ci.yml", "devenv/v2.3.1", "devenv/v2.3.2")
        dependency_pins.check(self.root)

    def test_uv_cli_can_be_pinned_independently_from_build_backend(self) -> None:
        self.replace(
            ".github/workflows/ci.yml", "version: '0.12.5'", "version: '0.12.6'"
        )
        self.replace("examples/consumers/Dockerfile", "uv:0.12.5@", "uv:0.12.6@")
        self.assertEqual(dependency_pins.check(self.root)["uv"], "0.12.6")

    def test_single_python_digest_update_is_rejected(self) -> None:
        self.replace("tests/fixtures/Dockerfile.node", "@sha256:", "@sha256:00")
        with self.assertRaisesRegex(ValueError, "Coordinate Python images"):
            dependency_pins.check(self.root)

    def test_hosted_python_update_requires_image_and_notice_review(self) -> None:
        self.replace(
            ".github/workflows/ci.yml",
            "python-version: '",
            "python-version: '99.",
        )
        with self.assertRaisesRegex(ValueError, "Coordinate Python runtime"):
            dependency_pins.check(self.root)

    def test_nix_update_cannot_silently_change_resolved_python(self) -> None:
        expected = dependency_pins.check(self.root)
        with patch.object(
            dependency_pins.subprocess, "check_output", return_value="Python 99.0.0\n"
        ):
            with self.assertRaisesRegex(ValueError, "resolved devenv"):
                dependency_pins.toolchain(expected)
