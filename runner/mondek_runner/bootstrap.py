# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Create an ordinary monitoring project without installation or registration."""

from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import tomllib
from importlib.metadata import version
from importlib.resources import files
from pathlib import Path

# Preserve notices in copied app/test templates, but do not assign a new
# project's metadata or empty initializer to the template author's copyright.
LICENSE_HEADER = "# SPDX-License-Identifier: Apache-2.0\n"


def _template(name: str) -> str:
    return (files("mondek_runner") / "bootstrap_templates" / name).read_text(
        encoding="utf-8"
    )


def _path(value: str, label: str) -> Path:
    if not value or any(
        ord(character) < 32 or ord(character) == 127 for character in value
    ):
        raise ValueError(f"{label} must be a nonempty path without control characters")
    return Path(value).expanduser().absolute()


def project_files(
    destination: Path, sdk: Path | None, sdk_version: str
) -> dict[str, str]:
    """Return the small source project; dependency resolution stays an explicit step."""
    paths = {
        "__PROJECT__": shlex.quote(str(destination)),
        "__SDK_MODE__": (
            f"Contributor override: the SDK is editable at {sdk}."
            if sdk
            else (
                "The SDK is installed from the package registry; "
                "no Mondek checkout is required."
            )
        ),
    }
    readme = re.sub(
        r"__PROJECT__|__SDK_MODE__",
        lambda match: paths[match.group()],
        _template("README.md"),
    )
    return {
        "pyproject.toml": LICENSE_HEADER
        + f"""[project]
name = "mondek-monitoring"
version = "0.1.0"
description = "My code-defined monitoring"
requires-python = ">=3.13"
dependencies = ["mondek=={sdk_version}"]
{source_override(sdk)}

[build-system]
requires = ["uv_build==0.12.5"]
build-backend = "uv_build"

[tool.uv.build-backend]
module-name = "monitoring"
""",
        "src/monitoring/__init__.py": LICENSE_HEADER,
        "src/monitoring/app.py": _template("app.py.tmpl"),
        "tests/test_backlog.py": _template("test_backlog.py.tmpl"),
        "sample-backlog.txt": "0\n",
        ".gitignore": ".venv/\n__pycache__/\n*.pyc\n.mondek-state/\n",
        "README.md": readme,
        "AGENTS.md": _template("AGENTS.md"),
    }


def source_override(sdk: Path | None) -> str:
    if sdk is None:
        return ""
    return (
        "\n[tool.uv.sources.mondek]\npath = "
        + json.dumps(str(sdk), ensure_ascii=False)
        + "\neditable = true\n"
    )


def create_project(directory: str, sdk_path: str | None = None) -> Path:
    """Create a new directory exclusively, with rollback on ordinary write errors."""
    requested = _path(directory, "project directory")
    destination = requested.parent.resolve(strict=True) / requested.name
    if os.path.lexists(destination):
        raise FileExistsError(f"project path already exists: {destination}")
    sdk = None
    if sdk_path is None:
        sdk_version = version("mondek")
    else:
        sdk = _path(sdk_path, "SDK path").resolve(strict=True)
        with (sdk / "pyproject.toml").open("rb") as stream:
            project = tomllib.load(stream).get("project", {})
        if (
            project.get("name") != "mondek"
            or not (sdk / "mondek_runner/__init__.py").is_file()
        ):
            raise ValueError("SDK path must be a Mondek runner directory")
        sdk_version = project["version"]
    files = project_files(destination, sdk, sdk_version)
    # mkdir is the no-overwrite reservation. rename alone could replace an empty
    # directory created concurrently on POSIX, violating the same guarantee.
    destination.mkdir()
    created: list[Path] = []
    directories = [destination]
    try:
        for relative, content in files.items():
            target = destination / relative
            for parent in reversed(target.parents):
                if parent != destination and destination in parent.parents:
                    if not parent.exists():
                        parent.mkdir()
                        directories.append(parent)
            with target.open("x", encoding="utf-8") as stream:
                created.append(target)
                stream.write(content)
    except BaseException:
        for target in reversed(created):
            target.unlink(missing_ok=True)
        for parent in reversed(directories):
            parent.rmdir()
        raise
    return destination


def initialize(arguments: list[str]) -> None:
    """CLI boundary kept separate from commands that execute or register checks."""
    parser = argparse.ArgumentParser(
        prog="mondek-runner init",
        description="Create a code-defined monitoring project in a new directory.",
    )
    parser.add_argument("directory", help="new project directory; parent must exist")
    parser.add_argument(
        "--sdk-path", help="optional editable local SDK directory for contributors"
    )
    args = parser.parse_args(arguments)
    try:
        destination = create_project(args.directory, args.sdk_path)
    except (OSError, ValueError) as error:
        parser.exit(1, f"{type(error).__name__}: {error}\n")
    print(f"Created monitoring project: {destination}")
    print("No dependencies installed, services started or checks registered.")
    print("Next, use Python 3.13+ and uv to install explicitly:\n")
    print(f"uv sync --project {shlex.quote(str(destination))}")
    print(f"cd {shlex.quote(str(destination))}")
    print("uv run --locked python -m unittest discover -s tests")
    print("uv run --locked mondek-runner validate --consumer monitoring.app:app")
    print(
        "uv run --locked mondek-runner run --consumer monitoring.app:app "
        "--check queue-backlog"
    )
    print(
        "\nCommit the resulting uv.lock. "
        "README.md explains connection and failure/recovery."
    )
