#!/usr/bin/env python3
# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Collect pinned package notices and enforce policy; never execute downloaded code."""

from __future__ import annotations

import argparse
import base64
import hashlib
import io
import json
import re
import subprocess
import sys
import tarfile
import urllib.request
from email.parser import Parser
from pathlib import Path
from typing import Any

import tomllib

ROOT = Path(__file__).resolve().parents[1]
NOTICE_NAME = re.compile(r"^(licen[cs]e|notice|copying|copyright)(?:$|[._-])", re.I)


class LicenseError(ValueError):
    pass


def approved(expression: str, allowed: set[str]) -> bool:
    """Evaluate SPDX AND/OR/parentheses. WITH requires explicit pair approval."""
    tokens = re.findall(r"[A-Za-z0-9.+:-]+|[()]", expression)
    if "".join(tokens) != re.sub(r"\s", "", expression) or not tokens:
        raise LicenseError(f"Invalid license expression: {expression!r}")
    position = 0

    def atom() -> bool:
        nonlocal position
        if position >= len(tokens):
            raise LicenseError(f"Incomplete license expression: {expression}")
        token = tokens[position]
        position += 1
        if token == "(":
            result = disjunction()
            if position >= len(tokens) or tokens[position] != ")":
                raise LicenseError(f"Unbalanced license expression: {expression}")
            position += 1
            return result
        if token in {"AND", "OR", "WITH", ")"}:
            raise LicenseError(f"Unexpected license operator: {expression}")
        if position < len(tokens) and tokens[position] == "WITH":
            position += 1
            if position >= len(tokens) or tokens[position] in {
                "AND",
                "OR",
                "WITH",
                "(",
                ")",
            }:
                raise LicenseError(f"Missing license exception: {expression}")
            token += " WITH " + tokens[position]
            position += 1
        return token in allowed

    def conjunction() -> bool:
        nonlocal position
        result = atom()
        while position < len(tokens) and tokens[position] == "AND":
            position += 1
            right = atom()
            result = result and right
        return result

    def disjunction() -> bool:
        nonlocal position
        result = conjunction()
        while position < len(tokens) and tokens[position] == "OR":
            position += 1
            right = conjunction()
            result = result or right
        return result

    result = disjunction()
    if position != len(tokens):
        raise LicenseError(f"Unexpected license tokens: {expression}")
    return result


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def document(path: str, data: bytes) -> dict[str, str]:
    text = data.decode("utf-8").replace("\r\n", "\n").strip()
    if not text:
        raise LicenseError(f"Empty notice: {path}")
    return {"path": path, "sha256": sha256(data), "text": text}


def archive_files(data: bytes) -> dict[str, bytes]:
    """Read notices/metadata without extracting archives or following links."""
    result = {}
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:*") as archive:
        for entry in archive:
            path = Path(entry.name)
            if path.is_absolute() or ".." in path.parts:
                raise LicenseError(f"Unsafe archive path: {entry.name}")
            if not (
                NOTICE_NAME.match(path.name)
                or path.name in {"package.json", "PKG-INFO"}
            ):
                continue
            if not entry.isfile() or entry.size > 2_000_000:
                raise LicenseError(f"Invalid notice member: {entry.name}")
            stream = archive.extractfile(entry)
            assert stream is not None
            result[entry.name] = stream.read()
    return result


def fetch(url: str, integrity: str, cache: Path, offline: bool) -> bytes:
    algorithm, expected = integrity.split(":", 1)
    path = cache / sha256(integrity.encode())
    if path.exists():
        data = path.read_bytes()
    elif offline:
        raise LicenseError(
            f"Missing cached evidence for {url}; run mondek licenses first"
        )
    else:
        if not url.startswith("https://"):
            raise LicenseError(f"Evidence URL must use HTTPS: {url}")
        with urllib.request.urlopen(url, timeout=60) as response:
            data = response.read(100_000_001)
        if len(data) > 100_000_000:
            raise LicenseError(f"Evidence archive too large: {url}")
    if hashlib.new(algorithm, data).hexdigest() != expected:
        raise LicenseError(f"Evidence checksum mismatch: {url}")
    cache.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    return data


def component(
    ecosystem: str,
    name: str,
    version: str,
    expression: str,
    scope: str,
    sources: list[dict[str, str]],
    notices: list[dict[str, str]],
    policy: dict[str, Any],
) -> dict[str, Any]:
    if not isinstance(expression, str) or not approved(
        expression, set(policy["allowed"])
    ):
        raise LicenseError(
            f"Unapproved or missing license: {ecosystem}:{name}@{version}: {expression}"
        )
    if not notices:
        raise LicenseError(
            f"Missing license/notice evidence: {ecosystem}:{name}@{version}"
        )
    return {
        "ecosystem": ecosystem,
        "name": name,
        "version": version,
        "license": expression,
        "scope": scope,
        "sources": sorted(sources, key=lambda x: x["url"]),
        "notices": sorted(notices, key=lambda x: x["path"]),
    }


def collect_source(root: Path, policy: dict[str, Any]) -> list[dict[str, Any]]:
    """Carry reviewed copied-source notices into compiled/distributed credits."""
    reviewed = json.loads((root / "licensing/source-notices.json").read_text())
    result = []
    for name, entry in reviewed["upstream"].items():
        if not (root / name).is_file():
            raise LicenseError(f"Missing adapted source: {name}")
        identity = entry["component"]
        result.append(
            component(
                "source",
                identity["name"],
                identity["version"],
                entry["license"],
                identity["scope"],
                [{"url": entry["source"]}],
                [document(entry["notice"], (root / entry["notice"]).read_bytes())],
                policy,
            )
        )
    return result


def collect_mix(root: Path, policy: dict[str, Any]) -> list[dict[str, Any]]:
    result = subprocess.run(
        ["elixir", "scripts/licenses_mix.exs"],
        cwd=root,
        check=True,
        text=True,
        capture_output=True,
    )
    entries = json.loads(result.stdout)
    components = []
    used_supplements = set()
    for entry in entries:
        path = root / "controller" / entry["path"]
        licenses = entry["licenses"]
        if not isinstance(licenses, list) or not licenses:
            raise LicenseError(f"Missing Hex license metadata: {entry['name']}")
        # Hex's list does not encode SPDX alternative licensing; require all entries.
        expression = " AND ".join(f"({item})" for item in licenses)
        notices = []
        for candidate in sorted(path.rglob("*")):
            if NOTICE_NAME.match(candidate.name) and candidate.is_file():
                if candidate.is_symlink():
                    raise LicenseError(f"Symlink notice: {candidate}")
                notices.append(
                    document(
                        candidate.relative_to(path).as_posix(), candidate.read_bytes()
                    )
                )
        key = f"{entry['name']}@{entry['version']}"
        supplement = policy["mix_supplements"].get(key)
        if supplement:
            used_supplements.add(key)
            if supplement["license"] not in licenses or not supplement["reason"]:
                raise LicenseError(f"Invalid version-scoped supplement: {key}")
            readme = (path / "README.md").read_text()
            section = re.search(r"(?im)^## License\s*$([\s\S]*?)(?=^## |\Z)", readme)
            if not section or not section[1].strip():
                raise LicenseError(f"Missing reviewed README license section: {key}")
            notices.append(document("README.md#license", section[0].encode()))
            notices.append(
                document("supplement/Apache-2.0.txt", (root / "LICENSE").read_bytes())
            )
        components.append(
            component(
                "hex",
                entry["name"],
                entry["version"],
                expression,
                entry["scope"],
                [{"url": entry["source"], "integrity": "sha256:" + entry["checksum"]}],
                notices,
                policy,
            )
        )
    if used_supplements != set(policy["mix_supplements"]):
        raise LicenseError(
            "Stale Mix license supplement: review policy after dependency changes"
        )
    return components


def collect_npm(
    root: Path, policy: dict[str, Any], cache: Path, offline: bool
) -> list[dict[str, Any]]:
    components = []
    inherited = policy["npm_inherited_notices"]
    supplements = policy.get("npm_supplements", {})
    used_supplements = set()
    for lock_path, scope in [
        ("controller/assets/package-lock.json", "asset-build"),
        ("tests/browser/package-lock.json", "browser-test"),
    ]:
        lock = json.loads((root / lock_path).read_text())
        packages = lock["packages"]
        parent = packages.get("node_modules/" + inherited["parent"])
        for path, entry in sorted(packages.items()):
            if not path:
                continue
            if entry.get("link") or "resolved" not in entry or "integrity" not in entry:
                raise LicenseError(f"Unsupported npm lock entry: {lock_path}:{path}")
            name = path.rsplit("node_modules/", 1)[1]
            source_entry = entry
            expression = entry.get("license")
            evidence_note = None
            if name.startswith(inherited["family"]):
                if (
                    not parent
                    or entry["version"] != inherited["version"]
                    or parent["version"] != inherited["version"]
                    or expression != inherited["license"]
                ):
                    raise LicenseError(f"Review esbuild inherited notices for {name}")
                source_entry = parent
                evidence_note = inherited["reason"]
            algorithm, encoded = source_entry["integrity"].split("-", 1)
            integrity = algorithm + ":" + base64.b64decode(encoded, validate=True).hex()
            files = archive_files(
                fetch(source_entry["resolved"], integrity, cache, offline)
            )
            package = json.loads(files["package/package.json"])
            expected_name = inherited["parent"] if evidence_note else name
            if (
                package["name"] != expected_name
                or package["version"] != entry["version"]
            ):
                raise LicenseError(f"npm artifact identity mismatch: {name}")
            if (
                evidence_note
                and package.get("optionalDependencies", {}).get(name)
                != entry["version"]
            ):
                raise LicenseError(f"Unrecognized esbuild platform package: {name}")
            if package.get("license") != expression:
                raise LicenseError(f"npm license metadata mismatch: {name}")
            notices = [
                document(p, data)
                for p, data in files.items()
                if NOTICE_NAME.match(Path(p).name)
            ]
            sources = [{"url": entry["resolved"], "integrity": entry["integrity"]}]
            if evidence_note:
                sources.append(
                    {
                        "url": source_entry["resolved"],
                        "integrity": source_entry["integrity"],
                    }
                )
            supplement_key = f"{name}@{entry['version']}"
            supplement = supplements.get(supplement_key)
            if supplement:
                if supplement["declared"] != expression or not supplement["reason"]:
                    raise LicenseError(
                        f"Invalid npm license supplement: {supplement_key}"
                    )
                expression = supplement["license"]
                evidence_note = supplement["reason"]
                used_supplements.add(supplement_key)
            artifact_scope = (
                "controller"
                if lock_path == "controller/assets/package-lock.json"
                and not entry.get("dev", False)
                else scope
            )
            record = component(
                "npm",
                name,
                entry["version"],
                expression,
                artifact_scope,
                sources,
                notices,
                policy,
            )
            if evidence_note:
                record["evidence_note"] = evidence_note
            components.append(record)
    if used_supplements != set(supplements):
        raise LicenseError(
            "Stale npm license supplement: review policy after dependency changes"
        )
    return components


def collect_python(
    root: Path, policy: dict[str, Any], cache: Path, offline: bool
) -> list[dict[str, Any]]:
    lock = tomllib.loads((root / "licensing/uv.lock").read_text())
    packages = {
        entry["name"].replace("_", "-"): entry
        for entry in lock["package"]
        if "registry" in entry["source"]
    }
    # Every external dependency in retained Python projects must have pinned evidence.
    for project_path in (
        "licensing",
        "runner",
        "examples/consumers",
        "examples/policy",
    ):
        other = tomllib.loads((root / project_path / "uv.lock").read_text())
        for entry in other["package"]:
            if "registry" in entry["source"]:
                known = packages.get(entry["name"].replace("_", "-"))
                if not known or known["version"] != entry["version"]:
                    raise LicenseError(
                        f"Unaccounted Python lock dependency: {project_path}:{entry['name']}"
                    )
                if (
                    known["source"] != entry["source"]
                    or known.get("sdist") != entry.get("sdist")
                    or sorted(known.get("wheels", []), key=lambda item: item["url"])
                    != sorted(entry.get("wheels", []), key=lambda item: item["url"])
                ):
                    raise LicenseError(
                        f"Python lock artifact differs from reviewed evidence: {project_path}:{entry['name']}"
                    )
            elif set(entry["source"]) in ({"editable"}, {"virtual"}):
                local = (
                    root / project_path / next(iter(entry["source"].values()))
                ).resolve()
                if (
                    not local.is_relative_to(root.resolve())
                    or not (local / "pyproject.toml").is_file()
                ):
                    raise LicenseError(
                        f"Unsupported local Python dependency: {entry['name']}"
                    )
            else:
                raise LicenseError(
                    f"Unsupported Python dependency source: {entry['name']}"
                )
        project = tomllib.loads((root / project_path / "pyproject.toml").read_text())
        for requirement in project.get("build-system", {}).get("requires", []):
            match = re.fullmatch(r"([\w-]+)==([\w.]+)", requirement)
            if (
                not match
                or packages.get(match[1].replace("_", "-"), {}).get("version")
                != match[2]
            ):
                raise LicenseError(
                    f"Unaccounted or unpinned build requirement: {requirement}"
                )
        if project["project"].get("dependencies") and project_path == "runner":
            raise LicenseError(
                "Review runner runtime dependency scope before adding Python dependencies"
            )
    components = []
    for name, entry in sorted(packages.items()):
        source = entry["sdist"]
        files = archive_files(fetch(source["url"], source["hash"], cache, offline))
        candidates = [
            data
            for path, data in files.items()
            if Path(path).name == "PKG-INFO" and len(Path(path).parts) == 2
        ]
        if len(candidates) != 1:
            raise LicenseError(f"Missing Python metadata: {name}")
        metadata = Parser().parsestr(candidates[0].decode())
        if (
            metadata["Name"].replace("_", "-") != name
            or metadata["Version"] != entry["version"]
        ):
            raise LicenseError(f"Python artifact identity mismatch: {name}")
        expression = metadata.get("License-Expression") or metadata.get("License")
        notices = [
            document(p, data)
            for p, data in files.items()
            if NOTICE_NAME.match(Path(p).name)
        ]
        components.append(
            component(
                "pypi",
                name,
                entry["version"],
                expression,
                "python-build-test",
                [{"url": source["url"], "integrity": source["hash"]}],
                notices,
                policy,
            )
        )
    return components


def render_markdown(components: list[dict[str, Any]]) -> str:
    lines = [
        "# Third-party licenses",
        "",
        "Generated by `mondek licenses`. Do not edit by hand.",
        "",
        "This inventory covers locked application packages and Python/JavaScript build/test packages. "
        "The listed scopes distinguish shipped code from build/test tools. Container operating "
        "systems and language runtimes retain their own notices inside the images.",
        "",
    ]
    for item in components:
        lines += [
            f"## {item['ecosystem']}:{item['name']} {item['version']}",
            "",
            f"License: {item['license']}. Scope: {item['scope']}.",
            "",
        ]
        for source in item["sources"]:
            lines += [
                f"Source: {source['url']}"
                + (f" ({source['integrity']})" if source.get("integrity") else ""),
                "",
            ]
        if item.get("evidence_note"):
            lines += [item["evidence_note"], ""]
        for notice in item["notices"]:
            lines += [f"### {notice['path']}", "", "```text", notice["text"], "```", ""]
    return "\n".join(lines)


def outputs(root: Path, components: list[dict[str, Any]]) -> dict[Path, bytes]:
    metadata = {"schema": 1, "components": components}
    controller = [item for item in components if item["scope"] == "controller"]
    return {
        root / "licensing/inventory.json": (
            json.dumps(metadata, indent=2, sort_keys=True) + "\n"
        ).encode(),
        root / "THIRD_PARTY_LICENSES.md": render_markdown(components).encode(),
        root / "controller/priv/licenses.json": (
            json.dumps(
                {"schema": 1, "components": controller}, indent=2, sort_keys=True
            )
            + "\n"
        ).encode(),
        root / "controller/priv/LICENSE": (root / "LICENSE").read_bytes(),
        root / "controller/priv/THIRD_PARTY_LICENSES.md": render_markdown(
            controller
        ).encode(),
        root / "runner/LICENSE": (root / "LICENSE").read_bytes(),
        root / "runner/THIRD_PARTY_LICENSES.md": (
            "# Runner licensing\n\nThe runner/SDK has no external runtime Python package dependencies. "
            "Its source is Apache-2.0; see LICENSE. Python and container runtime components retain "
            "their own licenses. The repository's THIRD_PARTY_LICENSES.md inventories build/test packages.\n"
        ).encode(),
    }


def write_outputs(generated: dict[Path, bytes], check: bool) -> None:
    for path, data in generated.items():
        if check:
            if not path.exists() or path.read_bytes() != data:
                raise LicenseError(
                    f"Stale generated notices: {path.name}; run mondek licenses"
                )
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--offline", action="store_true")
    args = parser.parse_args()
    try:
        policy = json.loads((ROOT / "licensing/policy.json").read_text())
        cache = ROOT / ".local/licenses/cache"
        components = (
            collect_source(ROOT, policy)
            + collect_mix(ROOT, policy)
            + collect_npm(ROOT, policy, cache, args.offline)
            + collect_python(ROOT, policy, cache, args.offline)
        )
        components.sort(key=lambda x: (x["ecosystem"], x["name"], x["version"]))
        write_outputs(outputs(ROOT, components), args.check)
        print(
            f"License policy and {'generated-file check' if args.check else 'generation'} passed: {len(components)} components"
        )
    except (
        LicenseError,
        OSError,
        KeyError,
        ValueError,
        subprocess.CalledProcessError,
    ) as error:
        print(f"License check failed: {error}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
