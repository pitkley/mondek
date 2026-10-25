# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Use digest-verified prebuilt CI images; ordinary local Compose is unchanged."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
import subprocess
from typing import Mapping, TextIO

ROOT = Path(__file__).resolve().parents[2]
_overlays: dict[tuple[str, ...], Path] = {}
_verified: set[tuple[str, str]] = set()
ACTIONS = {
    "up",
    "build",
    "run",
    "exec",
    "stop",
    "start",
    "restart",
    "kill",
    "logs",
    "down",
    "ps",
    "port",
    "config",
}


def prebuilt_command(command: list[str], env: Mapping[str, str]) -> list[str] | None:
    manifest_path = env.get("MONDEK_CI_IMAGES")
    if not manifest_path:
        return command
    index = next(i for i in range(2, len(command)) if command[i] in ACTIONS)
    prefix, arguments = command[:index], command[index:]
    key = (*prefix, manifest_path)
    if key not in _overlays:
        images = json.loads(Path(manifest_path).read_text())
        if "-f" not in prefix:
            prefix = [*prefix, "-f", str(ROOT / "compose.yaml")]
        config = json.loads(
            subprocess.check_output(
                [*prefix, "--profile", "*", "config", "--format", "json"],
                cwd=ROOT,
                env=env,
                text=True,
            )
        )
        lines = ["services:"]
        for name, service in config["services"].items():
            build = service.get("build")
            if not build:
                continue
            if (
                Path(build["context"]).resolve() != ROOT
                or build.get("args")
                or build.get("target")
            ):
                raise ValueError(f"Unsupported prebuilt context/arguments: {name}")
            dockerfile = build.get("dockerfile", "Dockerfile")
            image = images[
                dockerfile
            ]  # Missing coverage must fail, never rebuild silently.
            identity = (image["tag"], image["id"])
            if identity not in _verified:
                actual = subprocess.check_output(
                    ["docker", "image", "inspect", "--format", "{{.Id}}", image["tag"]],
                    text=True,
                ).strip()
                if actual != image["id"]:
                    raise ValueError(f"Prebuilt image identity changed: {dockerfile}")
                _verified.add(identity)
            lines.extend(
                [
                    f"  {json.dumps(name)}:",
                    f"    image: {json.dumps(image['id'])}",
                    "    pull_policy: never",
                    "    build: !reset null",
                ]
            )
        directory = ROOT / ".local/ci/compose"
        directory.mkdir(parents=True, exist_ok=True)
        overlay = directory / (hashlib.sha256(repr(key).encode()).hexdigest() + ".yaml")
        overlay.write_text("\n".join(lines) + "\n")
        _overlays[key] = overlay
    if arguments[0] == "build":
        return None
    if "-f" not in command[:index]:
        prefix = [*command[:index], "-f", str(ROOT / "compose.yaml")]
    else:
        prefix = command[:index]
    arguments = [arg for arg in arguments if arg != "--build"]
    if arguments[0] == "up":
        arguments.insert(1, "--no-build")
    return [*prefix, "-f", str(_overlays[key]), *arguments]


def run_compose(
    command: list[str],
    *,
    env: Mapping[str, str],
    log: TextIO,
    capture: bool = False,
    timeout: float = 900,
) -> str:
    command = prebuilt_command(command, env)
    if command is None:
        return ""
    result = subprocess.run(
        command,
        cwd=ROOT,
        env=env,
        text=True,
        stdout=subprocess.PIPE if capture else log,
        stderr=log,
        check=True,
        timeout=timeout,
    )
    return result.stdout or ""
