# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Monitor the filesystem, an exact local process and an application export."""

from __future__ import annotations

import json
import os
import shutil
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from mondek_runner import (
    App,
    Binding,
    Datasource,
    Environment,
    Output,
    Parameter,
    Result,
    Target,
    check,
)
from mondek_runner.api import timestamp


class LocalFiles(Datasource):
    def __init__(self, directory: str):
        self.directory = Path(directory)

    def read_json(self, name: str) -> dict[str, Any]:
        with (self.directory / name).open("rb") as source:
            data = source.read(1024 * 1024 + 1)
        if len(data) > 1024 * 1024:
            raise ValueError("local JSON file exceeds 1 MiB")
        parsed = json.loads(data)
        if not isinstance(parsed, dict):
            raise ValueError("expected a JSON object")
        return parsed


@check(
    id="root-disk",
    name="Runner filesystem capacity",
    expected_keys=("capacity",),
    params={"warn_percent": 80, "crit_percent": 90},
    parameters={
        "warn_percent": Parameter("number", "Warning at", "% used", 0, 100),
        "crit_percent": Parameter("number", "Critical at", "% used", 0, 100),
    },
    comparisons=(("warn_percent", "lt", "crit_percent"),),
    interval_seconds=5,
    timeout_seconds=2,
    freshness_seconds=20,
)
def root_disk(params: dict[str, Any]) -> Result:
    usage = shutil.disk_usage("/")
    percent = usage.used / usage.total * 100
    health = (
        "CRIT"
        if percent >= params["crit_percent"]
        else "WARN"
        if percent >= params["warn_percent"]
        else "OK"
    )
    return Result(
        "capacity",
        health,
        f"Runner filesystem is {percent:.1f}% used",
        percent,
        timestamp(),
    )


@check(
    id="export-file",
    name="Application export validity and age",
    expected_keys=("export",),
    params={"warn_age_seconds": 60, "crit_age_seconds": 120},
    parameters={
        "warn_age_seconds": Parameter("integer", "Warning after", "seconds", 1, 86400),
        "crit_age_seconds": Parameter(
            "integer", "Critical after", "seconds", 2, 172800
        ),
    },
    comparisons=(("warn_age_seconds", "lt", "crit_age_seconds"),),
    interval_seconds=5,
    timeout_seconds=2,
    freshness_seconds=20,
)
def export_file(files: LocalFiles, params: dict[str, Any]) -> Result:
    # source_at describes this filesystem inspection. generated_at is the domain
    # timestamp being measured; an old export can be a freshly measured failure.
    try:
        exported = files.read_json("export.json")
    except FileNotFoundError:
        return Result(
            "export", "CRIT", "Required export.json is missing", None, timestamp()
        )
    except PermissionError:
        return Result("export", "UNKNOWN", "Cannot read export.json: permission denied")
    except (ValueError, UnicodeError) as error:
        return Result(
            "export", "CRIT", f"Invalid export.json: {error}", None, timestamp()
        )
    except OSError as error:
        return Result("export", "UNKNOWN", f"Cannot inspect export.json: {error}")

    try:
        generated = datetime.fromisoformat(exported["generated_at"])
        if generated.tzinfo is None:
            raise ValueError("generated_at needs a timezone")
        records = exported["records"]
        if not isinstance(records, list) or not records:
            raise ValueError("records must be a nonempty list")
        if any(
            not isinstance(record, dict) or "id" not in record for record in records
        ):
            raise ValueError("each record needs an id")
        age = (datetime.now(UTC) - generated).total_seconds()
        if age < -2:
            raise ValueError("generated_at is in the future")
    except (KeyError, TypeError, ValueError) as error:
        return Result(
            "export", "CRIT", f"Invalid export.json: {error}", None, timestamp()
        )

    health = (
        "CRIT"
        if age > params["crit_age_seconds"]
        else "WARN"
        if age > params["warn_age_seconds"]
        else "OK"
    )
    return Result(
        "export",
        health,
        f"Export contains {len(records)} records and is {max(0, age):.0f} seconds old",
        max(0, age),
        timestamp(),
    )


@check(
    id="application-process",
    name="Application process",
    expected_keys=("process",),
    interval_seconds=5,
    timeout_seconds=2,
    freshness_seconds=20,
)
def application_process(files: LocalFiles) -> Result:
    try:
        identity = files.read_json("process.json")
        pid, expected_start = identity["pid"], identity["start"]
        if type(pid) is not int or pid < 1 or not isinstance(expected_start, str):
            raise ValueError("process identity is invalid")
    except (OSError, KeyError, ValueError, TypeError) as error:
        return Result("process", "UNKNOWN", f"Cannot read process identity: {error}")
    try:
        stat = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()
        actual_start = stat[19]
        if actual_start != expected_start:
            return Result(
                "process",
                "CRIT",
                "Expected process was replaced; PID was reused",
                None,
                timestamp(),
            )
        if stat[0] == "Z":
            return Result(
                "process", "CRIT", "Expected process has exited", None, timestamp()
            )
    except FileNotFoundError:
        return Result(
            "process", "CRIT", "Expected process is not running", None, timestamp()
        )
    except (OSError, ValueError, IndexError) as error:
        return Result("process", "UNKNOWN", f"Cannot inspect local process: {error}")
    return Result(
        "process", "OK", f"Expected process is running (PID {pid})", pid, timestamp()
    )


node_id = os.environ.get("MONDEK_NODE_ID", "local-node")
node_name = os.environ.get("MONDEK_NODE_NAME", node_id)
app = App(
    source_id="node-baseline",
    name=f"{node_name} local checks",
    environment=Environment("local-demo", "Local demonstration"),
    checks=[
        Binding(
            root_disk,
            outputs=(
                Output(
                    "capacity",
                    "Runner filesystem capacity",
                    Target(
                        f"node:{node_id}/root", f"{node_name} runner /", "filesystem"
                    ),
                ),
            ),
        ),
        Binding(
            export_file,
            outputs=(
                Output(
                    "export",
                    "Application export",
                    Target(
                        f"node:{node_id}/export", f"{node_name} export.json", "file"
                    ),
                ),
            ),
        ),
        Binding(
            application_process,
            outputs=(
                Output(
                    "process",
                    "Application process",
                    Target(
                        f"node:{node_id}/process", f"{node_name} application", "process"
                    ),
                ),
            ),
        ),
    ],
)
app.register_datasource(
    LocalFiles, directory=os.environ.get("MONDEK_NODE_DIRECTORY", "/node")
)
