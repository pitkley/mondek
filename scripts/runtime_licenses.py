#!/usr/bin/env python3
# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Preserve reviewed runtime notices from checksum-pinned upstream sources."""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import re
import sys
import tarfile
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
NOTICE = re.compile(
    r"^(?:licen[cs]e|copying|copyright|notice)(?:$|[.-](?:txt|md|rst|Apache2|Boost)$)",
    re.I,
)


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def collect(data: bytes, extra: list[str]) -> dict[str, bytes]:
    result = {}
    with tarfile.open(fileobj=io.BytesIO(data)) as archive:
        for member in archive:
            path = Path(member.name)
            if path.is_absolute() or ".." in path.parts:
                raise ValueError(f"Unsafe runtime source path: {path}")
            name = Path(*path.parts[1:]).as_posix()
            if not (NOTICE.fullmatch(path.name) or name in extra):
                continue
            if not member.isfile() or member.size > 2_000_000:
                raise ValueError(f"Invalid runtime notice: {name}")
            stream = archive.extractfile(member)
            assert stream is not None
            result[name] = stream.read()
    if not result or set(extra) - result.keys():
        raise ValueError(
            f"Missing runtime notices or reviewed embedded-code evidence: {sorted(set(extra) - result.keys())}"
        )
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    manifest = json.loads((ROOT / "licensing/runtime-sources.json").read_text())
    expected = set()
    for name, item in manifest.items():
        # A runtime update must update the source pin as well as the image pin.
        dockerfile = (ROOT / item["dockerfile"]).read_text()
        if item["image_marker"] not in dockerfile:
            raise ValueError(
                f"Review {name} source evidence after runtime image change"
            )
        directory = ROOT / "licensing/runtime" / name
        if args.check:
            for entry in item["notices"]:
                path = directory / entry["path"]
                if digest(path.read_bytes()) != entry["sha256"]:
                    raise ValueError(f"Changed runtime notice: {path}")
                expected.add(path)
        else:
            cache = ROOT / ".local/licenses/runtime" / (name + ".tar")
            if not cache.exists():
                with urllib.request.urlopen(item["url"], timeout=60) as response:
                    data = response.read(150_000_001)
                if len(data) > 150_000_000:
                    raise ValueError("Runtime source archive exceeds limit")
                cache.parent.mkdir(parents=True, exist_ok=True)
                cache.write_bytes(data)
            data = cache.read_bytes()
            if digest(data) != item["sha256"]:
                raise ValueError(f"Runtime archive checksum mismatch: {name}")
            notices = collect(data, item["extra_files"])
            item["notices"] = []
            for relative, content in sorted(notices.items()):
                path = directory / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(content)
                expected.add(path)
                item["notices"].append({"path": relative, "sha256": digest(content)})
    actual = {p for p in (ROOT / "licensing/runtime").rglob("*") if p.is_file()}
    if actual != expected:
        raise ValueError(f"Unclassified runtime evidence: {sorted(actual ^ expected)}")
    if not args.check:
        (ROOT / "licensing/runtime-sources.json").write_text(
            json.dumps(manifest, indent=2, sort_keys=True) + "\n"
        )
    print(
        f"Runtime notices checked: {len(manifest)} pinned runtimes, {len(expected)} files"
    )


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError) as error:
        print(f"Runtime license check failed: {error}", file=sys.stderr)
        sys.exit(1)
