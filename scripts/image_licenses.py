#!/usr/bin/env python3
# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Audit an immutable built image without starting it; emit per-image evidence."""

from __future__ import annotations

import argparse
import hashlib
import json
import posixpath
import re
import subprocess
import sys
import tarfile
import tempfile
from email.parser import Parser
from pathlib import Path, PurePosixPath
from typing import Any

from release import controller_version

ROOT = Path(__file__).resolve().parents[1]
OTP_APPS = {
    "asn1",
    "compiler",
    "crypto",
    "inets",
    "kernel",
    "public_key",
    "sasl",
    "ssl",
    "stdlib",
}
ELIXIR_APPS = {"eex", "elixir", "iex", "logger"}


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def normalize(name: str) -> str:
    if ".." in PurePosixPath(name).parts:
        raise ValueError(f"Unsafe filesystem path: {name}")
    return name.removeprefix("./").lstrip("/")


class Filesystem:
    def __init__(self, archive: tarfile.TarFile):
        self.archive = archive
        self.members = {normalize(m.name): m for m in archive}

    def resolve(self, name: str) -> str:
        name = normalize(name)
        for _ in range(40):
            parts = name.split("/")
            for index in range(len(parts)):
                prefix = "/".join(parts[: index + 1])
                member = self.members.get(prefix)
                if member and (member.issym() or member.islnk()):
                    target = member.linkname
                    if member.issym() and not target.startswith("/"):
                        target = posixpath.join(posixpath.dirname(prefix), target)
                    target = posixpath.normpath("/" + target.lstrip("/"))
                    name = posixpath.join(target, *parts[index + 1 :]).lstrip("/")
                    break
            else:
                return name
        raise ValueError(f"Filesystem link loop: {name}")

    def read(self, name: str, limit: int = 20_000_000) -> bytes:
        resolved = self.resolve(name)
        member = self.members.get(resolved)
        if member is None or not member.isfile() or member.size > limit:
            raise ValueError(f"Missing, unsafe or oversized image evidence: {name}")
        stream = self.archive.extractfile(member)
        assert stream is not None
        return stream.read()


def os_components(
    fs: Filesystem,
) -> tuple[list[dict[str, Any]], dict[str, str], list[str]]:
    components = []
    owners = {}
    gaps = []
    status = fs.read("var/lib/dpkg/status").decode()
    for paragraph in status.split("\n\n"):
        record = Parser().parsestr(paragraph)
        if record.get("Status") != "install ok installed":
            continue
        package, version, arch = (
            record["Package"],
            record["Version"],
            record["Architecture"],
        )
        source = record.get("Source", package)
        match = re.fullmatch(r"([^ ]+)(?: \(([^)]+)\))?", source)
        if not match:
            raise ValueError(f"Unknown dpkg source identity: {source}")
        source_name, source_version = match[1], match[2] or version
        notice_path = f"usr/share/doc/{package}/copyright"
        notice = fs.read(notice_path)
        if not notice.strip():
            raise ValueError(f"Empty OS copyright: {package}")
        digest = sha256(notice)
        references = sorted(
            {
                ref.rstrip(b".")
                for ref in re.findall(
                    rb"/usr/share/common-licenses/([A-Za-z0-9.+-]+)", notice
                )
            }
        )
        common = []
        for ref in references:
            path = "usr/share/common-licenses/" + ref.decode()
            try:
                data = fs.read(path)
                if not data.strip():
                    raise ValueError(f"Empty common license: {path}")
                common.append(
                    {"path": path, "sha256": sha256(data), "text": data.decode()}
                )
            except ValueError:
                gaps.append(f"Missing common license referenced by {package}: {path}")
        # Preserve distribution notices, including bundled-code terms.
        components.append(
            {
                "name": package,
                "version": version,
                "architecture": arch,
                "source": source_name,
                "source_version": source_version,
                "notice": {
                    "path": notice_path,
                    "sha256": digest,
                    "text": notice.decode(),
                },
                "common_licenses": common,
            }
        )
        paths = [
            f"var/lib/dpkg/info/{package}.list",
            f"var/lib/dpkg/info/{package}:{arch}.list",
        ]
        listing = next((p for p in paths if p in fs.members), None)
        if not listing:
            raise ValueError(f"Missing dpkg file ownership: {package}")
        for path in fs.read(listing).decode().splitlines():
            owners[fs.resolve(path)] = f"deb:{package}@{version}"
    if not components:
        raise ValueError("Missing installed Debian package inventory")
    return sorted(components, key=lambda c: c["name"]), owners, gaps


def audit(fs: Filesystem, kind: str, root: Path) -> dict[str, Any]:
    components, owners, gaps = os_components(fs)
    app_license = fs.read("usr/share/doc/mondek/LICENSE")
    if (
        app_license != (root / "LICENSE").read_bytes()
        or fs.read("usr/share/doc/mondek/THIRD_PARTY_LICENSES.md")
        != (root / "THIRD_PARTY_LICENSES.md").read_bytes()
    ):
        raise ValueError("Image application/package notices do not match source")
    runtime_manifest = json.loads((root / "licensing/runtime-sources.json").read_text())
    if (
        fs.read("usr/share/doc/mondek/runtime-sources.json")
        != (root / "licensing/runtime-sources.json").read_bytes()
    ):
        raise ValueError("Image runtime provenance does not match source")
    runtimes = ["otp", "elixir"] if kind == "controller" else ["python"]
    runtime_notices = []
    for runtime in runtimes:
        item = runtime_manifest[runtime]
        for entry in item["notices"]:
            name = f"usr/share/doc/mondek/runtime/{runtime}/{entry['path']}"
            if sha256(fs.read(name)) != entry["sha256"]:
                raise ValueError(f"Missing or changed runtime notice: {name}")
        runtime_notices.append({"name": runtime, **item})
    packages = json.loads((root / "licensing/inventory.json").read_text())["components"]
    expected_apps = {
        c["name"]: c["version"]
        for c in packages
        if c["scope"] == "controller" and c["ecosystem"] == "hex"
    }
    release_apps = []
    if kind == "controller":
        app_dirs = sorted(
            {
                p.split("/")[2]
                for p in fs.members
                if p.startswith("app/lib/") and len(p.split("/")) > 3
            }
        )
        found = set()
        for directory in app_dirs:
            name, version = directory.split("-", 1)
            found.add(name)
            if name in expected_apps:
                if version != expected_apps[name]:
                    raise ValueError(
                        f"Unexpected release dependency version: {directory}"
                    )
                owner = f"hex:{name}@{version}"
            elif name in OTP_APPS and version == runtime_manifest["otp"][
                "release_apps"
            ].get(name):
                owner = "runtime:otp"
            elif (
                name in ELIXIR_APPS and version == runtime_manifest["elixir"]["version"]
            ):
                owner = "runtime:elixir"
            elif name == "mondek" and version == controller_version(root):
                owner = "application"
            else:
                raise ValueError(f"Unclassified release application: {directory}")
            release_apps.append({"name": name, "version": version, "owner": owner})
        if set(expected_apps) - found:
            raise ValueError("Release is missing inventoried runtime packages")
        # The release includes the exact ERTS patch from the pinned OTP build.
        erts = runtime_manifest["otp"]["erts_version"]
        if fs.read("app/releases/start_erl.data").decode().split()[0] != erts:
            raise ValueError("Review changed ERTS runtime identity")
        embedded = next(
            p
            for p in fs.members
            if re.fullmatch(r"app/lib/mondek-[^/]+/priv/licenses.json", p)
        )
        if fs.read(embedded) != (root / "controller/priv/licenses.json").read_bytes():
            raise ValueError("Release credits do not match runtime package inventory")
    else:
        header = fs.read("usr/local/include/python3.13/patchlevel.h").decode()
        if f'"{runtime_manifest["python"]["version"]}"' not in header:
            raise ValueError("Review changed Python runtime identity")
        if any(
            ".dist-info/" in p
            or "/ensurepip/" in p
            or p.startswith("usr/local/bin/pip")
            or p.endswith(".whl")
            or (
                p.startswith("usr/local/lib/python3.13/site-packages/")
                and fs.members[p].isfile()
                and p.rsplit("/", 1)[1] != "README.txt"
            )
            for p in fs.members
        ):
            raise ValueError(
                "Unexpected installed Python package or bundled installer; inventory it explicitly"
            )
    native = []
    for path, member in sorted(fs.members.items()):
        if not member.isfile() or member.size < 4:
            continue
        stream = fs.archive.extractfile(member)
        assert stream is not None
        if stream.read(4) != b"\x7fELF":
            continue
        owner = owners.get(fs.resolve(path))
        if owner is None and kind == "controller":
            if path.startswith(f"app/erts-{runtime_manifest['otp']['erts_version']}/"):
                owner = "runtime:otp"
            for app in release_apps:
                if path.startswith(f"app/lib/{app['name']}-{app['version']}/"):
                    owner = app["owner"]
        if (
            owner is None
            and kind == "runner"
            and (
                path
                in {
                    "usr/local/bin/python3.13",
                    "usr/local/lib/libpython3.so",
                    "usr/local/lib/libpython3.13.so.1.0",
                }
                or path.startswith("usr/local/lib/python3.13/lib-dynload/")
                or re.fullmatch(
                    r"usr/local/lib/python3.13/config-3\.13-[^/]+/python\.o", path
                )
            )
        ):
            owner = "runtime:python"
        if owner is None:
            gaps.append(f"Unclassified native executable/library: {path}")
        native.append(
            {
                "path": path,
                "owner": owner,
                "sha256": sha256(fs.read(path, limit=200_000_000)),
            }
        )
    return {
        "schema": 3,
        "filesystem_scope": "final_installed_filesystem",
        "kind": kind,
        "audit_scope": [
            "os_package_notices",
            "application_notices",
            "runtime_notices",
            "native_file_ownership",
        ],
        "os_components": components,
        "runtime_components": runtime_notices,
        "release_applications": release_apps,
        "native_files": native,
        "gaps": gaps,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("kind", choices=["controller", "runner"])
    parser.add_argument("image")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    inspect = json.loads(
        subprocess.check_output(["docker", "image", "inspect", args.image])
    )[0]
    # Create by immutable config digest, never by a mutable tag after inspection.
    image_id = inspect["Id"]
    container = subprocess.check_output(
        [
            "docker",
            "create",
            "--network",
            "none",
            "--entrypoint",
            "/bin/false",
            image_id,
        ],
        text=True,
    ).strip()
    try:
        with tempfile.TemporaryDirectory(prefix="mondek-image-license-") as directory:
            archive_path = Path(directory) / "rootfs.tar"
            subprocess.run(
                ["docker", "export", "--output", str(archive_path), container],
                check=True,
            )
            with tarfile.open(archive_path) as archive:
                result = audit(
                    Filesystem(archive),
                    args.kind,
                    ROOT,
                )
    finally:
        subprocess.run(
            ["docker", "rm", container], check=True, stdout=subprocess.DEVNULL
        )
    result["image"] = {
        "config_digest": image_id,
        "repository_digests": inspect.get("RepoDigests", []),
        "os": inspect["Os"],
        "architecture": inspect["Architecture"],
        "rootfs_layers": inspect["RootFS"]["Layers"],
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(
        f"{args.kind}: {image_id}, {len(result['os_components'])} OS packages, {len(result['native_files'])} native files, {len(result['gaps'])} review gaps; evidence: {args.output}"
    )
    if result["gaps"]:
        raise ValueError("\n".join(result["gaps"]))


if __name__ == "__main__":
    try:
        main()
    except (
        ValueError,
        OSError,
        KeyError,
        StopIteration,
        subprocess.CalledProcessError,
    ) as error:
        print(f"Image license check failed: {error}", file=sys.stderr)
        sys.exit(1)
