#!/usr/bin/env python3
# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Validate matching release versions and prepare SDK artifacts locally; never upload."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tomllib
import zipfile
from email.parser import Parser

ROOT = Path(__file__).resolve().parents[1]


def controller_version(root: Path) -> str:
    matches = re.findall(
        r'version: "([^"]+)"', (root / "controller/mix.exs").read_text()
    )
    if len(matches) != 1:
        raise ValueError("Expected exactly one controller version")
    return matches[0]


def version_contract(root: Path, tag: str | None = None) -> dict[str, str]:
    sdk = tomllib.loads((root / "runner/pyproject.toml").read_text())["project"][
        "version"
    ]
    match = re.fullmatch(
        r"((?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*))(?:(a|b|rc)([1-9]\d*))?", sdk
    )
    if not match:
        raise ValueError("Release version must be X.Y.Z, X.Y.ZaN, X.Y.ZbN or X.Y.ZrcN")
    base, stage, number = match.groups()
    suffix = {"a": "alpha", "b": "beta", "rc": "rc"}
    expected = base + (f"-{suffix[stage]}.{number}" if stage else "")
    if controller_version(root) != expected:
        raise ValueError(f"Controller version must be {expected} to match SDK {sdk}")
    if tag is not None and tag != f"v{sdk}":
        raise ValueError(f"Release tag must be v{sdk}")
    return {"sdk": sdk, "controller": expected, "tag": f"v{sdk}", "image_tag": sdk}


def wheel_contents(path: Path) -> dict[str, bytes]:
    with zipfile.ZipFile(path) as archive:
        return {name: archive.read(name) for name in archive.namelist()}


def build_sdk(output: Path, contract: dict[str, str]) -> None:
    # A new directory avoids accidentally promoting leftovers from another build.
    output.mkdir(parents=True, exist_ok=False)
    subprocess.run(
        ["uv", "build", "--project", str(ROOT / "runner"), "--out-dir", str(output)],
        check=True,
    )
    wheel = next(output.glob("*.whl"))
    sdist = next(output.glob("*.tar.gz"))
    rebuilt = output / "rebuilt"
    subprocess.run(
        ["uv", "build", str(sdist), "--wheel", "--out-dir", str(rebuilt)], check=True
    )
    contents = wheel_contents(wheel)
    metadata = Parser().parsestr(
        next(
            data
            for name, data in contents.items()
            if name.endswith(".dist-info/METADATA")
        ).decode()
    )
    if metadata["Name"] != "mondek" or metadata["Version"] != contract["sdk"]:
        raise ValueError("SDK artifact metadata differs from the release contract")
    if wheel_contents(next(rebuilt.glob("*.whl"))) != contents:
        raise ValueError("Wheel rebuilt from the sdist differs from the original wheel")
    hashes = {
        path.name: hashlib.sha256(path.read_bytes()).hexdigest()
        for path in (wheel, sdist)
    }
    (output / "SHA256SUMS").write_text(
        "".join(f"{digest}  {name}\n" for name, digest in sorted(hashes.items()))
    )
    (output / "sdk-build.json").write_text(
        json.dumps(
            {**contract, "artifacts": hashes, "sdist_wheel_matches": True}, indent=2
        )
        + "\n"
    )

    verify_sdk(output, contract)


def sha256(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def verify_sdk(directory: Path, contract: dict[str, str]) -> dict[str, str]:
    manifest = json.loads((directory / "sdk-build.json").read_text())
    if any(manifest.get(key) != value for key, value in contract.items()):
        raise ValueError("SDK manifest differs from the release contract")
    expected = {
        f"mondek-{contract['sdk']}-py3-none-any.whl",
        f"mondek-{contract['sdk']}.tar.gz",
    }
    hashes = manifest["artifacts"]
    if set(hashes) != expected or manifest.get("sdist_wheel_matches") is not True:
        raise ValueError("SDK manifest must contain the qualified wheel/sdist pair")
    for name, digest in hashes.items():
        if sha256(directory / name) != digest:
            raise ValueError(f"SDK artifact checksum mismatch: {name}")
    sums = "".join(f"{digest}  {name}\n" for name, digest in sorted(hashes.items()))
    if (directory / "SHA256SUMS").read_text() != sums:
        raise ValueError("SDK checksum file differs from its manifest")
    contents = wheel_contents(directory / f"mondek-{contract['sdk']}-py3-none-any.whl")
    metadata = Parser().parsestr(
        next(
            data
            for name, data in contents.items()
            if name.endswith(".dist-info/METADATA")
        ).decode()
    )
    if (
        metadata["Name"] != "mondek"
        or metadata["Version"] != contract["sdk"]
        or metadata["License-Expression"] != "Apache-2.0"
        or metadata["Requires-Python"] != ">=3.13"
        or metadata["Description-Content-Type"] != "text/markdown"
    ):
        raise ValueError(
            "SDK metadata does not describe the selected typed Python alpha"
        )
    return hashes


def inspect_image(image: str, architecture: str) -> dict:
    metadata = json.loads(
        subprocess.check_output(["docker", "image", "inspect", image])
    )[0]
    if metadata["Os"] != "linux" or metadata["Architecture"] != architecture:
        raise ValueError(f"Expected a Linux/{architecture} controller image")
    return metadata


def save_image(
    image: str, architecture: str, sdk: Path, output: Path, contract: dict[str, str]
) -> None:
    hashes = verify_sdk(sdk, contract)
    metadata = inspect_image(image, architecture)
    output.mkdir(parents=True, exist_ok=False)
    archive = output / "controller.tar"
    subprocess.run(["docker", "save", "--output", str(archive), image], check=True)
    manifest = {
        **contract,
        "architecture": architecture,
        "image": image,
        "image_id": metadata["Id"],
        "archive_sha256": sha256(archive),
        "sdk_artifacts": hashes,
    }
    (output / "image.json").write_text(json.dumps(manifest, indent=2) + "\n")


def load_image(
    directory: Path, architecture: str, sdk: Path, contract: dict[str, str]
) -> str:
    manifest = json.loads((directory / "image.json").read_text())
    hashes = verify_sdk(sdk, contract)
    if (
        any(manifest.get(key) != value for key, value in contract.items())
        or manifest["architecture"] != architecture
        or manifest["sdk_artifacts"] != hashes
    ):
        raise ValueError("Image export differs from the release/SDK contract")
    archive = directory / "controller.tar"
    if sha256(archive) != manifest["archive_sha256"]:
        raise ValueError("Controller archive checksum mismatch")
    subprocess.run(["docker", "load", "--input", str(archive)], check=True)
    metadata = inspect_image(manifest["image"], architecture)
    if metadata["Id"] != manifest["image_id"]:
        raise ValueError("Loaded controller differs from the qualified image")
    return manifest["image_id"]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "command",
        choices=["check", "build-sdk", "verify-sdk", "save-image", "load-image"],
    )
    parser.add_argument("--tag", help="require this exact Git release tag")
    parser.add_argument(
        "--output", type=Path, help="new local artifact output directory"
    )
    parser.add_argument(
        "--directory", type=Path, help="existing SDK/image artifact directory"
    )
    parser.add_argument(
        "--sdk-directory",
        type=Path,
        help="qualified SDK directory for image export/load",
    )
    parser.add_argument("--image", help="locally built and tested image tag")
    parser.add_argument("--architecture", choices=["amd64", "arm64"])
    args = parser.parse_args()
    contract = version_contract(ROOT, args.tag)
    if args.command == "build-sdk":
        if args.output is None:
            parser.error("build-sdk requires --output")
        build_sdk(args.output.resolve(), contract)
    elif args.command == "verify-sdk":
        if args.directory is None:
            parser.error("verify-sdk requires --directory")
        verify_sdk(args.directory, contract)
    elif args.command in {"save-image", "load-image"}:
        if args.architecture is None or args.sdk_directory is None:
            parser.error("image commands require --architecture and --sdk-directory")
        if args.command == "save-image":
            if args.image is None or args.output is None:
                parser.error("save-image requires --image and --output")
            save_image(
                args.image, args.architecture, args.sdk_directory, args.output, contract
            )
        else:
            if args.directory is None:
                parser.error("load-image requires --directory")
            print(
                load_image(
                    args.directory, args.architecture, args.sdk_directory, contract
                )
            )
    print(json.dumps(contract, indent=2))


if __name__ == "__main__":
    main()
