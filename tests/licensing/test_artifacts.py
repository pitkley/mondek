# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
from __future__ import annotations

import hashlib
import io
import json
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
import image_licenses  # noqa: E402
import runtime_licenses  # noqa: E402


def archive(files: dict[str, bytes | tuple[str, str]]) -> tarfile.TarFile:
    stream = io.BytesIO()
    with tarfile.open(fileobj=stream, mode="w") as target:
        for name, content in files.items():
            entry = tarfile.TarInfo(name)
            if isinstance(content, tuple):
                entry.type = tarfile.SYMTYPE
                entry.linkname = content[1]
                target.addfile(entry)
            else:
                entry.size = len(content)
                target.addfile(entry, io.BytesIO(content))
    stream.seek(0)
    return tarfile.open(fileobj=stream)


class ArtifactLicenseTest(unittest.TestCase):
    def test_runtime_archive_keeps_bundled_notices_and_requires_inline_evidence(
        self,
    ) -> None:
        with archive(
            {
                "runtime/LICENSE": b"main",
                "runtime/vendor/COPYING": b"vendor",
                "runtime/vendor/zlib.h": b"embedded license",
                "runtime/code.py": b"code",
            }
        ) as source:
            source.fileobj.seek(0)
            data = source.fileobj.read()
        result = runtime_licenses.collect(data, ["vendor/zlib.h"])
        self.assertEqual(set(result), {"LICENSE", "vendor/COPYING", "vendor/zlib.h"})
        with self.assertRaisesRegex(ValueError, "Missing runtime"):
            runtime_licenses.collect(data, ["missing/header.h"])
        with archive({"runtime/../LICENSE": b"unsafe"}) as source:
            source.fileobj.seek(0)
            with self.assertRaisesRegex(ValueError, "Unsafe runtime source"):
                runtime_licenses.collect(source.fileobj.read(), [])

    def test_image_links_are_resolved_inside_archive_without_extraction(self) -> None:
        with archive(
            {
                "usr/bin/tool": b"tool",
                "bin": ("symlink", "/usr/bin"),
                "loop-a": ("symlink", "loop-b"),
                "loop-b": ("symlink", "loop-a"),
            }
        ) as source:
            fs = image_licenses.Filesystem(source)
            self.assertEqual(fs.read("/bin/tool"), b"tool")
            with self.assertRaisesRegex(ValueError, "link loop"):
                fs.read("loop-a")
            with self.assertRaisesRegex(ValueError, "Unsafe filesystem"):
                fs.read("../../host-secret")

    def fixture(self, root: Path) -> dict:
        (root / "licensing").mkdir()
        (root / "LICENSE").write_bytes(b"application license")
        (root / "THIRD_PARTY_LICENSES.md").write_bytes(b"package notices")
        notice = b"Copyright Example; see /usr/share/common-licenses/GPL-2.\n"
        runtime = {
            "python": {
                "version": "3.13.15",
                "notices": [
                    {
                        "path": "LICENSE",
                        "sha256": hashlib.sha256(b"python license").hexdigest(),
                    }
                ],
            }
        }
        (root / "licensing/runtime-sources.json").write_text(json.dumps(runtime))
        (root / "licensing/inventory.json").write_text('{"components": []}')
        files = {
            "var/lib/dpkg/status": b"Package: example\nStatus: install ok installed\nVersion: 2.0-1+b1\nArchitecture: arm64\nSource: example-source (2.0-1)\n\n",
            "var/lib/dpkg/info/example:arm64.list": b"/usr/bin/tool\n",
            "usr/share/doc/example/copyright": notice,
            "usr/share/common-licenses/GPL-2": b"GPL license",
            "usr/bin/tool": b"\x7fELF" + b"binary" * 3,
            "usr/share/doc/mondek/LICENSE": b"application license",
            "usr/share/doc/mondek/THIRD_PARTY_LICENSES.md": b"package notices",
            "usr/share/doc/mondek/runtime-sources.json": json.dumps(runtime).encode(),
            "usr/share/doc/mondek/runtime/python/LICENSE": b"python license",
            "usr/local/include/python3.13/patchlevel.h": b'#define PY_VERSION "3.13.15"',
        }
        return files

    def test_image_inventory_retains_notices_and_accepts_distribution_updates(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            files = self.fixture(root)
            with archive(files) as source:
                result = image_licenses.audit(
                    image_licenses.Filesystem(source), "runner", root
                )
            self.assertEqual(result["gaps"], [])
            self.assertEqual(result["schema"], 3)
            self.assertEqual(result["os_components"][0]["source"], "example-source")
            self.assertEqual(result["os_components"][0]["source_version"], "2.0-1")
            self.assertEqual(result["native_files"][0]["owner"], "deb:example@2.0-1+b1")
            files["usr/share/doc/example/copyright"] += b"Updated attribution\n"
            files["usr/share/common-licenses/GPL-2"] += b"Updated text\n"
            with archive(files) as source:
                updated = image_licenses.audit(
                    image_licenses.Filesystem(source), "runner", root
                )
            self.assertEqual(updated["gaps"], [])
            self.assertIn(
                "Updated attribution", updated["os_components"][0]["notice"]["text"]
            )
            del files["usr/share/common-licenses/GPL-2"]
            with archive(files) as source:
                missing = image_licenses.audit(
                    image_licenses.Filesystem(source), "runner", root
                )
            self.assertIn("Missing common license", missing["gaps"][0])
            del files["usr/share/doc/example/copyright"]
            with (
                archive(files) as source,
                self.assertRaisesRegex(ValueError, "Missing, unsafe"),
            ):
                image_licenses.audit(image_licenses.Filesystem(source), "runner", root)

    def test_controller_copied_source_credits_are_not_release_applications(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            files = self.fixture(root)
            runtime = {
                "otp": {"erts_version": "1", "release_apps": {}, "notices": []},
                "elixir": {"version": "1", "notices": []},
            }
            runtime_bytes = json.dumps(runtime).encode()
            (root / "licensing/runtime-sources.json").write_bytes(runtime_bytes)
            files["usr/share/doc/mondek/runtime-sources.json"] = runtime_bytes
            inventory = {
                "components": [
                    {
                        "name": "dep",
                        "version": "1",
                        "scope": "controller",
                        "ecosystem": "hex",
                    },
                    {
                        "name": "copied-icons",
                        "version": "1",
                        "scope": "controller",
                        "ecosystem": "source",
                    },
                ]
            }
            (root / "licensing/inventory.json").write_text(json.dumps(inventory))
            (root / "controller/priv").mkdir(parents=True)
            (root / "controller/priv/licenses.json").write_bytes(b"embedded credits")
            (root / "controller/mix.exs").write_text('version: "0.0.1-alpha.1"')
            embedded = "app/lib/mondek-0.0.1-alpha.1/priv/licenses.json"
            files[embedded] = b"embedded credits"
            files["app/lib/dep-1/ebin/dep.beam"] = b"beam"
            files["app/releases/start_erl.data"] = b"1 0.0.1-alpha.1"
            with archive(files) as source:
                result = image_licenses.audit(
                    image_licenses.Filesystem(source), "controller", root
                )
            self.assertEqual(result["gaps"], [])
            self.assertEqual(
                {app["name"] for app in result["release_applications"]},
                {"dep", "mondek"},
            )
            files[embedded] = b"old credits"
            with (
                archive(files) as source,
                self.assertRaisesRegex(ValueError, "Release credits"),
            ):
                image_licenses.audit(
                    image_licenses.Filesystem(source), "controller", root
                )
            files[embedded] = b"embedded credits"
            del files["app/lib/dep-1/ebin/dep.beam"]
            with (
                archive(files) as source,
                self.assertRaisesRegex(ValueError, "missing inventoried"),
            ):
                image_licenses.audit(
                    image_licenses.Filesystem(source), "controller", root
                )

    def test_image_unknown_native_code_missing_notices_and_python_packages_fail(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            files = self.fixture(root)
            files["opt/unmanaged/tool"] = b"\x7fELF" + b"binary" * 3
            with archive(files) as source:
                result = image_licenses.audit(
                    image_licenses.Filesystem(source), "runner", root
                )
            self.assertIn("Unclassified native", result["gaps"][0])
            del files["usr/share/doc/mondek/runtime/python/LICENSE"]
            with (
                archive(files) as source,
                self.assertRaisesRegex(ValueError, "Missing, unsafe"),
            ):
                image_licenses.audit(image_licenses.Filesystem(source), "runner", root)
            files["usr/share/doc/mondek/runtime/python/LICENSE"] = b"python license"
            files[
                "usr/local/lib/python3.13/site-packages/unknown-1.dist-info/METADATA"
            ] = b"Name: unknown"
            with (
                archive(files) as source,
                self.assertRaisesRegex(ValueError, "Unexpected installed Python"),
            ):
                image_licenses.audit(image_licenses.Filesystem(source), "runner", root)


if __name__ == "__main__":
    unittest.main()
