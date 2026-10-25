#!/usr/bin/env python3
# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Reject partial updates of coupled build, runtime and test dependencies."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import subprocess
import sys
import tomllib

from release import version_contract

ROOT = Path(__file__).resolve().parents[1]
PYTHON_IMAGES = [
    "runner/Dockerfile",
    "examples/consumers/Dockerfile",
    "tests/fixtures/Dockerfile",
    "tests/fixtures/Dockerfile.node",
    "tests/browser/fleet/Dockerfile",
    "tests/performance/Dockerfile",
]


def one(text: str, pattern: str) -> str:
    matches = re.findall(pattern, text, re.MULTILINE)
    if len(matches) != 1:
        raise ValueError(f"Expected one pin matching {pattern!r}, found {len(matches)}")
    return matches[0]


def same(name: str, values: dict[str, str]) -> str:
    if len(set(values.values())) != 1:
        raise ValueError(f"Coordinate {name} pins: {values}")
    return next(iter(values.values()))


def check(root: Path) -> dict[str, str]:
    def read(name: str) -> str:
        return (root / name).read_text()

    runtime = json.loads(read("licensing/runtime-sources.json"))
    runner = tomllib.loads(read("runner/pyproject.toml"))
    tooling = tomllib.loads(read("licensing/pyproject.toml"))
    workflow = read(".github/workflows/ci.yml")
    minimum = one(read("devenv.yaml"), r'require_version: ">=([\d.]+)"')
    ci_devenv = one(workflow, r"github:cachix/devenv/v([\d.]+)")
    if tuple(map(int, ci_devenv.split("."))) < tuple(map(int, minimum.split("."))):
        raise ValueError(f"CI devenv {ci_devenv} is below supported minimum {minimum}")
    same(
        "Ruff",
        {
            "runner": one(
                "\n".join(runner["dependency-groups"]["dev"]), r"^ruff==(.+)$"
            ),
            "license tools": one(
                "\n".join(tooling["project"]["dependencies"]), r"^ruff==(.+)$"
            ),
        },
    )
    uv = same(
        "uv CLI",
        {
            "consumer image": one(
                read("examples/consumers/Dockerfile"),
                r"ghcr.io/astral-sh/uv:([^@]+)@sha256:",
            ),
            "CI": one(workflow, r"setup-uv@[^\n]+\n\s+with:\n\s+version: '([^']+)'"),
        },
    )
    python_image = same(
        "Python images",
        {name: one(read(name), r"^FROM (python:[^\s]+)") for name in PYTHON_IMAGES},
    )
    python = same(
        "Python runtime",
        {
            "runtime notices": runtime["python"]["version"],
            "images": one(python_image, r"python:([\d.]+)-"),
            "CI": one(workflow, r"python-version: '([^']+)'"),
        },
    )
    controller = read("controller/Dockerfile")
    for name, pattern in [
        ("elixir", r"hexpm/elixir:([\d.]+)-"),
        ("otp", r"-erlang-([\d.]+)-"),
    ]:
        same(
            name,
            {
                "image": one(controller, pattern),
                "runtime notices": runtime[name]["version"],
            },
        )
    packages = {}
    for directory in ["controller/assets", "tests/browser"]:
        package = json.loads(read(f"{directory}/package.json"))
        lock = json.loads(read(f"{directory}/package-lock.json"))
        for group in ["dependencies", "devDependencies"]:
            if package.get(group, {}) != lock["packages"][""].get(group, {}):
                raise ValueError(f"Refresh npm lock declarations: {directory}")
            for name, version in package.get(group, {}).items():
                if lock["packages"][f"node_modules/{name}"]["version"] != version:
                    raise ValueError(f"Refresh npm locked version: {directory}:{name}")
        packages[directory] = package
    same(
        "Playwright",
        {
            "npm": packages["tests/browser"]["devDependencies"]["@playwright/test"],
            "image": one(
                read("tests/browser/Dockerfile"), r"playwright:v([\d.]+)-[^@]+@sha256:"
            ),
        },
    )
    version_contract(root)
    return {
        "python": python,
        "uv": uv,
        "node": one(controller, r"^FROM node:([\d.]+)-"),
        "esbuild": packages["controller/assets"]["devDependencies"]["esbuild"],
        "elixir": runtime["elixir"]["version"],
        "otp": runtime["otp"]["version"],
    }


def toolchain(expected: dict[str, str]) -> None:
    commands = {
        "python": (["python3", "--version"], r"Python ([\d.]+)"),
        "uv": (["uv", "--version"], r"uv ([\d.]+)"),
        "node": (["node", "--version"], r"v([\d.]+)"),
        "esbuild": (["esbuild", "--version"], r"^([\d.]+)$"),
        "elixir": (["elixir", "--version"], r"^Elixir ([\d.]+)"),
        "otp": (
            [
                "erl",
                "-noshell",
                "-eval",
                'io:format("~s", [element(2, file:read_file(filename:join([code:root_dir(), "releases", erlang:system_info(otp_release), "OTP_VERSION"])))]), halt().',
            ],
            r"^([\d.]+)$",
        ),
    }
    for name, (command, pattern) in commands.items():
        actual = one(subprocess.check_output(command, text=True).strip(), pattern)
        same(name, {"resolved devenv": actual, "declared image/tool": expected[name]})


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--toolchain",
        action="store_true",
        help="Also compare resolved devenv tools with image/build pins",
    )
    args = parser.parse_args()
    expected = check(ROOT)
    if args.toolchain:
        toolchain(expected)
    print(
        "Coupled dependency pins checked"
        + (" against resolved devenv tools" if args.toolchain else "")
    )


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        print(f"Dependency pin check failed: {error}", file=sys.stderr)
        sys.exit(1)
