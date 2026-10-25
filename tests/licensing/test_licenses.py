# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
from __future__ import annotations

import io
import json
import subprocess
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import tomllib

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
import licenses  # noqa: E402


class LicensePolicyTest(unittest.TestCase):
    def test_python_wheel_order_does_not_change_artifact_identity(self) -> None:
        root = Path(__file__).resolve().parents[2]
        original = (root / "runner/uv.lock").read_text()
        loads = tomllib.loads

        def reordered(content, *args, **kwargs):
            lock = loads(content, *args, **kwargs)
            if content == original:
                for entry in lock["package"]:
                    entry.get("wheels", []).reverse()
            return lock

        with (
            patch.object(licenses.tomllib, "loads", reordered),
            patch.object(
                licenses,
                "fetch",
                side_effect=RuntimeError("reviewed artifact collection reached"),
            ),
            self.assertRaisesRegex(
                RuntimeError, "reviewed artifact collection reached"
            ),
        ):
            licenses.collect_python(root, {}, root / ".local/licenses/cache", True)

    def test_same_version_python_artifact_drift_is_rejected_before_collection(
        self,
    ) -> None:
        root = Path(__file__).resolve().parents[2]
        path = root / "runner/uv.lock"
        original = path.read_text()
        entry = next(
            p for p in tomllib.loads(original)["package"] if "registry" in p["source"]
        )
        mutations = {
            "registry": (entry["source"]["registry"], "https://example.invalid/simple"),
            "sdist URL": (
                entry["sdist"]["url"],
                "https://example.invalid/source.tar.gz",
            ),
            "sdist hash": (entry["sdist"]["hash"], "sha256:" + "0" * 64),
            "wheel URL": (
                entry["wheels"][0]["url"],
                "https://example.invalid/package.whl",
            ),
            "wheel hash": (entry["wheels"][0]["hash"], "sha256:" + "0" * 64),
        }
        read_text = Path.read_text

        for name, (before, after) in mutations.items():
            altered = original.replace(before, after)
            self.assertNotEqual(original, altered)

            def content(current, *args, **kwargs):
                return (
                    altered if current == path else read_text(current, *args, **kwargs)
                )

            with (
                self.subTest(name=name),
                patch.object(Path, "read_text", content),
                patch.object(
                    licenses,
                    "fetch",
                    side_effect=AssertionError("unreviewed artifact reached fetch"),
                ) as fetch,
            ):
                with self.assertRaisesRegex(
                    licenses.LicenseError, "Python lock artifact"
                ):
                    licenses.collect_python(
                        root, {}, root / ".local/licenses/cache", True
                    )
                fetch.assert_not_called()

    def test_untracked_python_dependency_sources_cannot_bypass_the_registry_inventory(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "licensing").mkdir()
            (root / "licensing/uv.lock").write_text(
                '[[package]]\nname = "unknown"\nversion = "1.0"\n'
                'source = { git = "https://example.invalid/private" }\n'
            )
            with self.assertRaisesRegex(
                licenses.LicenseError, "Unsupported Python dependency source"
            ):
                licenses.collect_python(root, {}, root / "cache", True)

    def test_alternative_and_combined_obligations_are_not_flat_allowlist_matches(
        self,
    ) -> None:
        allowed = {"MIT", "Apache-2.0"}
        self.assertTrue(licenses.approved("GPL-3.0-only OR MIT", allowed))
        self.assertFalse(licenses.approved("GPL-3.0-only AND MIT", allowed))
        self.assertTrue(
            licenses.approved("(MIT OR GPL-3.0-only) AND Apache-2.0", allowed)
        )
        self.assertFalse(licenses.approved("MIT WITH Unreviewed-exception", allowed))
        for expression in [
            "MIT AND",
            "MIT MIT",
            "MIT OR (Apache-2.0",
            "MIT;GPL",
            "()",
            "MIT WITH AND",
        ]:
            with (
                self.subTest(expression=expression),
                self.assertRaises(licenses.LicenseError),
            ):
                licenses.approved(expression, allowed)

    def test_unknown_or_missing_license_and_missing_notice_block_inventory(
        self,
    ) -> None:
        policy = {"allowed": ["MIT"]}
        for expression, notices in [
            ("GPL-3.0-only", [{"path": "LICENSE", "text": "license"}]),
            ("MIT", []),
            (None, []),
        ]:
            with (
                self.subTest(expression=expression),
                self.assertRaises(licenses.LicenseError),
            ):
                licenses.component(
                    "test", "library", "1.0", expression, "runtime", [], notices, policy
                )

    def test_checksum_is_rechecked_even_for_cached_evidence(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            cache = Path(directory)
            integrity = "sha256:" + licenses.sha256(b"trusted")
            path = cache / licenses.sha256(integrity.encode())
            with self.assertRaisesRegex(licenses.LicenseError, "Missing cached"):
                licenses.fetch("https://example.invalid/source", integrity, cache, True)
            path.write_bytes(b"trusted")
            self.assertEqual(
                licenses.fetch(
                    "https://example.invalid/source", integrity, cache, True
                ),
                b"trusted",
            )
            path.write_bytes(b"corrupt")
            with self.assertRaisesRegex(licenses.LicenseError, "checksum mismatch"):
                licenses.fetch("https://example.invalid/source", integrity, cache, True)

    def test_archive_reader_preserves_extra_notices_and_rejects_traversal(self) -> None:
        def archive(names: list[str]) -> bytes:
            stream = io.BytesIO()
            with tarfile.open(fileobj=stream, mode="w:gz") as target:
                for name in names:
                    entry = tarfile.TarInfo(name)
                    entry.size = 6
                    target.addfile(entry, io.BytesIO(b"notice"))
            return stream.getvalue()

        files = licenses.archive_files(
            archive(
                [
                    "package/LICENSE",
                    "package/NOTICE",
                    "package/LICENSE-3RD-PARTY.txt",
                    "package/code.js",
                ]
            )
        )
        self.assertEqual(
            set(files),
            {"package/LICENSE", "package/NOTICE", "package/LICENSE-3RD-PARTY.txt"},
        )
        with self.assertRaisesRegex(licenses.LicenseError, "Unsafe archive path"):
            licenses.archive_files(archive(["../LICENSE"]))

    def test_missing_locked_hex_source_and_stale_supplement_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result = subprocess.CompletedProcess(
                [],
                0,
                stdout=json.dumps(
                    [
                        {
                            "name": "missing",
                            "version": "1",
                            "licenses": ["MIT"],
                            "path": "deps/missing",
                            "scope": "controller",
                            "source": "https://example.invalid/package",
                            "checksum": "abc",
                        }
                    ]
                ),
            )
            with (
                patch.object(licenses.subprocess, "run", return_value=result),
                self.assertRaisesRegex(
                    licenses.LicenseError, "Missing license/notice evidence"
                ),
            ):
                licenses.collect_mix(root, {"allowed": ["MIT"], "mix_supplements": {}})
            result.stdout = "[]"
            with (
                patch.object(licenses.subprocess, "run", return_value=result),
                self.assertRaisesRegex(licenses.LicenseError, "Stale Mix"),
            ):
                licenses.collect_mix(
                    root, {"allowed": ["MIT"], "mix_supplements": {"removed@1": {}}}
                )

    def test_check_mode_rejects_missing_or_stale_output_without_rewriting_it(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "inventory.json"
            generated = {path: b"current\n"}
            with self.assertRaises(licenses.LicenseError):
                licenses.write_outputs(generated, True)
            self.assertFalse(path.exists())
            licenses.write_outputs(generated, False)
            licenses.write_outputs(generated, True)
            path.write_bytes(b"old\n")
            with self.assertRaisesRegex(licenses.LicenseError, "Stale generated"):
                licenses.write_outputs(generated, True)
            self.assertEqual(path.read_bytes(), b"old\n")

    def test_shipped_npm_icons_include_all_terms_and_require_supplement_review(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            entry = {
                "version": "1",
                "license": "ISC",
                "resolved": "https://example.invalid/icons.tgz",
                "integrity": "sha512-YQ==",
            }
            for path in [
                "controller/assets/package-lock.json",
                "tests/browser/package-lock.json",
            ]:
                target = root / path
                target.parent.mkdir(parents=True)
                target.write_text(
                    json.dumps(
                        {
                            "packages": {"node_modules/icons": entry}
                            if path.startswith("controller")
                            else {}
                        }
                    )
                )
            files = {
                "package/package.json": json.dumps(
                    {"name": "icons", "version": "1", "license": "ISC"}
                ).encode(),
                "package/LICENSE": b"ISC terms and retained MIT terms",
            }
            policy = {
                "allowed": ["ISC", "MIT"],
                "npm_inherited_notices": {"parent": "esbuild", "family": "@esbuild/"},
                "npm_supplements": {
                    "icons@1": {
                        "declared": "ISC",
                        "license": "ISC AND MIT",
                        "reason": "Incorporated terms",
                    }
                },
            }
            with (
                patch.object(licenses, "fetch", return_value=b"archive"),
                patch.object(licenses, "archive_files", return_value=files),
            ):
                components = licenses.collect_npm(root, policy, root / "cache", True)
                self.assertEqual(components[0]["scope"], "controller")
                self.assertEqual(components[0]["license"], "ISC AND MIT")
                self.assertEqual(
                    components[0]["notices"][0]["text"],
                    "ISC terms and retained MIT terms",
                )
                policy["allowed"] = ["ISC"]
                with self.assertRaisesRegex(licenses.LicenseError, "Unapproved"):
                    licenses.collect_npm(root, policy, root / "cache", True)
                policy["allowed"] = ["ISC", "MIT"]
                policy["npm_supplements"]["icons@old"] = policy["npm_supplements"].pop(
                    "icons@1"
                )
                with self.assertRaisesRegex(licenses.LicenseError, "Stale npm"):
                    licenses.collect_npm(root, policy, root / "cache", True)

    def test_source_notices_reach_runtime_outputs_without_freezing_adapted_code(
        self,
    ) -> None:
        root = Path(__file__).resolve().parents[2]
        policy = json.loads((root / "licensing/policy.json").read_text())
        reviewed = json.loads((root / "licensing/source-notices.json").read_text())
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory)
            for name in [
                "LICENSE",
                "licensing/source-notices.json",
                *reviewed["upstream"],
                *(entry["notice"] for entry in reviewed["upstream"].values()),
            ]:
                destination = target / name
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes((root / name).read_bytes())
            components = licenses.collect_source(target, policy)
            self.assertEqual(
                {item["name"] for item in components},
                {"phoenix-scaffold"},
            )
            generated = licenses.outputs(target, components)
            for notice in [b"Chris McCord"]:
                self.assertIn(
                    notice,
                    generated[target / "controller/priv/THIRD_PARTY_LICENSES.md"],
                )
                self.assertIn(notice, generated[target / "THIRD_PARTY_LICENSES.md"])
            for name, entry in reviewed["upstream"].items():
                path = target / name
                path.write_bytes(path.read_bytes() + b"# legitimate local edit\n")
                self.assertEqual(licenses.collect_source(target, policy), components)
                path = target / entry["notice"]
                original = path.read_bytes()
                path.write_bytes(b"")
                with self.assertRaisesRegex(licenses.LicenseError, "Empty notice"):
                    licenses.collect_source(target, policy)
                path.write_bytes(original)
                path.unlink()
                with self.assertRaises(FileNotFoundError):
                    licenses.collect_source(target, policy)

    def test_every_artifact_notice_scope_rejects_drift_without_rewriting(self) -> None:
        root = Path(__file__).resolve().parents[2]
        components = json.loads((root / "licensing/inventory.json").read_text())[
            "components"
        ]
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory)
            (target / "LICENSE").write_bytes((root / "LICENSE").read_bytes())
            generated = licenses.outputs(target, components)
            self.assertEqual(len(generated), 7)
            licenses.write_outputs(generated, False)
            licenses.write_outputs(generated, True)
            for path, expected in generated.items():
                with self.subTest(artifact=str(path.relative_to(target))):
                    path.write_bytes(b"stale artifact notice\n")
                    with self.assertRaisesRegex(
                        licenses.LicenseError, "Stale generated"
                    ):
                        licenses.write_outputs(generated, True)
                    self.assertEqual(path.read_bytes(), b"stale artifact notice\n")
                    path.write_bytes(expected)
            licenses.write_outputs(generated, True)


if __name__ == "__main__":
    unittest.main()
