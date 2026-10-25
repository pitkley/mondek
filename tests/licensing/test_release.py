# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
import hashlib
import json
import sys
import tempfile
import unittest
import zipfile
from unittest.mock import patch
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
import release  # noqa: E402
from release import version_contract  # noqa: E402


class ReleaseVersionTest(unittest.TestCase):
    def contract(self, sdk, controller, tag=None):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "runner").mkdir()
            (root / "controller").mkdir()
            (root / "runner/pyproject.toml").write_text(f'[project]\nversion="{sdk}"\n')
            (root / "controller/mix.exs").write_text(f'version: "{controller}"')
            return version_contract(root, tag)

    def test_matching_stable_and_prerelease_versions(self):
        for sdk, controller in [
            ("1.2.3", "1.2.3"),
            ("0.0.1a1", "0.0.1-alpha.1"),
            ("1.2.3b2", "1.2.3-beta.2"),
            ("1.2.3rc4", "1.2.3-rc.4"),
        ]:
            with self.subTest(sdk=sdk):
                self.assertEqual(
                    self.contract(sdk, controller, f"v{sdk}")["image_tag"], sdk
                )

    def test_tag_and_controller_disagreement_rejected(self):
        with self.assertRaisesRegex(ValueError, "Controller version"):
            self.contract("0.0.1a1", "0.0.1")
        with self.assertRaisesRegex(ValueError, "Release tag"):
            self.contract("0.0.1a1", "0.0.1-alpha.1", "v0.0.1")

    def test_development_and_noncanonical_versions_are_not_release_versions(self):
        for sdk in [
            "0.0.1.dev1",
            "00.1.0",
            "1.02.3",
            "0.0.1+local",
            "0.0.1a0",
            "v0.0.1",
            "0.0.1-alpha.1",
        ]:
            with (
                self.subTest(sdk=sdk),
                self.assertRaisesRegex(ValueError, "Release version"),
            ):
                self.contract(sdk, "0.0.1-alpha.1")


class ReleaseArtifactTest(unittest.TestCase):
    def setUp(self):

        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.contract = {
            "sdk": "0.0.1a1",
            "controller": "0.0.1-alpha.1",
            "tag": "v0.0.1a1",
            "image_tag": "0.0.1a1",
        }
        self.wheel = self.root / "mondek-0.0.1a1-py3-none-any.whl"
        with zipfile.ZipFile(self.wheel, "w") as archive:
            archive.writestr(
                "mondek-0.0.1a1.dist-info/METADATA",
                "Name: mondek\nVersion: 0.0.1a1\nLicense-Expression: Apache-2.0\nRequires-Python: >=3.13\nDescription-Content-Type: text/markdown\n\nMondek\n",
            )
        sdist = self.root / "mondek-0.0.1a1.tar.gz"
        sdist.write_bytes(b"qualified source archive")
        self.hashes = {
            p.name: hashlib.sha256(p.read_bytes()).hexdigest()
            for p in (self.wheel, sdist)
        }
        (self.root / "sdk-build.json").write_text(
            json.dumps(
                {**self.contract, "artifacts": self.hashes, "sdist_wheel_matches": True}
            )
        )
        (self.root / "SHA256SUMS").write_text(
            "".join(
                f"{digest}  {name}\n" for name, digest in sorted(self.hashes.items())
            )
        )

    def image_export(self):

        directory = self.root / "image"
        directory.mkdir()
        archive = directory / "controller.tar"
        archive.write_bytes(b"qualified image archive")
        manifest = {
            **self.contract,
            "architecture": "arm64",
            "image": "mondek-release:arm64",
            "image_id": "sha256:qualified",
            "archive_sha256": hashlib.sha256(archive.read_bytes()).hexdigest(),
            "sdk_artifacts": self.hashes,
        }
        (directory / "image.json").write_text(json.dumps(manifest))
        return directory

    def test_corrupt_sdk_or_changed_checksum_manifest_is_rejected(self):

        self.assertEqual(release.verify_sdk(self.root, self.contract), self.hashes)
        self.wheel.write_bytes(b"changed wheel")
        with self.assertRaisesRegex(ValueError, "checksum mismatch"):
            release.verify_sdk(self.root, self.contract)

    def test_checksums_cannot_select_unrelated_files_or_another_release(self):

        manifest = json.loads((self.root / "sdk-build.json").read_text())
        manifest["artifacts"]["../outside"] = "0" * 64
        (self.root / "sdk-build.json").write_text(json.dumps(manifest))
        with self.assertRaisesRegex(ValueError, "wheel/sdist pair"):
            release.verify_sdk(self.root, self.contract)
        manifest["controller"] = "0.0.2"
        (self.root / "sdk-build.json").write_text(json.dumps(manifest))
        with self.assertRaisesRegex(ValueError, "release contract"):
            release.verify_sdk(self.root, self.contract)

    def test_changed_checksum_file_is_rejected(self):

        (self.root / "SHA256SUMS").write_text("inconsistent checksums")
        with self.assertRaisesRegex(ValueError, "checksum file"):
            release.verify_sdk(self.root, self.contract)

    def test_image_archive_and_architecture_are_checked_before_loading(self):

        directory = self.image_export()
        with patch.object(release.subprocess, "run") as run:
            with self.assertRaisesRegex(ValueError, "release/SDK contract"):
                release.load_image(directory, "amd64", self.root, self.contract)
            (directory / "controller.tar").write_bytes(b"corrupted image")
            with self.assertRaisesRegex(ValueError, "archive checksum mismatch"):
                release.load_image(directory, "arm64", self.root, self.contract)
            run.assert_not_called()

    def test_loading_requires_the_qualified_image_identity(self):

        directory = self.image_export()
        with (
            patch.object(release.subprocess, "run"),
            patch.object(release, "inspect_image", return_value={"Id": "sha256:other"}),
        ):
            with self.assertRaisesRegex(ValueError, "differs from the qualified image"):
                release.load_image(directory, "arm64", self.root, self.contract)
        with (
            patch.object(release.subprocess, "run"),
            patch.object(
                release, "inspect_image", return_value={"Id": "sha256:qualified"}
            ),
        ):
            self.assertEqual(
                release.load_image(directory, "arm64", self.root, self.contract),
                "sha256:qualified",
            )
