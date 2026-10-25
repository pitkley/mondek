# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Ordinary file monitoring whose logical volume can move between observers.

This consumer owns its declaration format and pending-item policy. An explicit
empty declaration withdraws monitoring; a missing or malformed data file does not.
The same installed source is used on both nodes in the durable-rule demonstration.
"""

from __future__ import annotations

import json
import os
import re
from collections.abc import Callable
from pathlib import Path
from typing import Annotated, Any

from mondek_runner import (
    App,
    Binding,
    Datasource,
    DatasourceFactory,
    Environment,
    FromFactory,
    Output,
    Parameter,
    Placement,
    Result,
    RunnerContext,
    Target,
    check,
)
from mondek_runner.api import timestamp

SOURCE_ID = "durable-volume-monitoring"
CONTRACT = "volume.pending-items.v1"
PARAMETER_UNIT = "items"
DEFAULTS = {"warning_items": 50, "critical_items": 100}
PRODUCTION = Environment("production", "Production")
MAX_SETTINGS_BYTES = 32768


class VolumeFile(Datasource):
    placement = Placement(requires=("local-files",))

    def __init__(self, path: str):
        self.path = Path(path)

    def pending(self) -> int:
        with self.path.open(encoding="utf-8") as stream:
            value = stream.read(65)
        if len(value) > 64 or not re.fullmatch(r"[0-9]+\s*", value):
            raise ValueError("expected a bounded nonnegative integer")
        count = int(value)
        if count > 1_000_000:
            raise ValueError("pending item count exceeds the sample's range")
        return count


class VolumeFiles(DatasourceFactory):
    def __init__(self, paths: dict[str, str]):
        self.paths = paths

    def new(self, volume_id: str) -> VolumeFile:
        return VolumeFile(self.paths[volume_id])


def inspect_pending(source: VolumeFile, params: dict[str, int]) -> Result:
    try:
        count = source.pending()
    except (OSError, UnicodeError, ValueError):
        return Result("pending", "UNKNOWN", "Cannot read a valid pending-item count")
    health = (
        "CRIT"
        if count >= params["critical_items"]
        else "WARN"
        if count >= params["warning_items"]
        else "OK"
    )
    return Result(
        "pending",
        health,
        f"{count} pending items on the volume",
        count,
        timestamp(),
        details="Read the declared volume's pending-item file on this observer.",
    )


def volume_check(volume_id: str, label: str) -> Callable[..., Result]:
    def probe(source: VolumeFile, params: dict[str, int]) -> Result:
        return inspect_pending(source, params)

    probe.__annotations__["source"] = Annotated[
        VolumeFile, FromFactory(VolumeFiles, volume_id)
    ]
    return check(
        id=f"volume:{volume_id}",
        name=f"{label} pending items",
        expected_keys=("pending",),
        params=dict(DEFAULTS),
        parameters={
            "warning_items": Parameter(
                "integer", "Warning at", PARAMETER_UNIT, 1, 1_000_000
            ),
            "critical_items": Parameter(
                "integer", "Critical at", PARAMETER_UNIT, 2, 1_000_000
            ),
        },
        comparisons=(("warning_items", "lt", "critical_items"),),
        parameter_contract=CONTRACT,
        interval_seconds=5,
        timeout_seconds=3,
        freshness_seconds=20,
    )(probe)


def _unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate volume declaration field")
        result[key] = value
    return result


def declarations(raw: str) -> list[dict[str, str]]:
    if not raw or len(raw.encode()) > MAX_SETTINGS_BYTES:
        raise ValueError("volume declarations must be nonempty JSON within 32 KiB")
    values = json.loads(raw, object_pairs_hook=_unique_object)
    if not isinstance(values, list) or len(values) > 16:
        raise ValueError("declare an explicit list of 0–16 volumes")
    seen: set[str] = set()
    for value in values:
        if not isinstance(value, dict) or set(value) != {"id", "label", "path"}:
            raise ValueError("each volume requires only id, label and path")
        if not all(isinstance(item, str) for item in value.values()):
            raise ValueError("volume declaration values must be strings")
        if not re.fullmatch(r"[a-z][a-z0-9-]{0,63}", value["id"]):
            raise ValueError("volume identity must be a stable lowercase identifier")
        if value["id"] in seen:
            raise ValueError("volume identities must be unique")
        seen.add(value["id"])
        if (
            not value["label"]
            or len(value["label"].encode()) > 200
            or not Path(value["path"]).is_absolute()
            or len(value["path"].encode()) > 512
            or any(ord(char) < 32 for char in value["path"])
        ):
            raise ValueError("volume label or absolute input path is invalid")
    return values


def make_app(node_id: str, raw: str) -> App:
    if node_id not in ("node-a", "node-b"):
        raise ValueError("this demonstration has node-a and node-b observers")
    volumes = declarations(raw)
    application = App(
        source_id=SOURCE_ID,
        name="Logical volume monitoring",
        environment=PRODUCTION,
        runner=RunnerContext(
            node_id,
            "Node A" if node_id == "node-a" else "Node B",
            capabilities=("local-files",),
            target=Target(f"node:{node_id}", node_id, "host"),
            local_environment=PRODUCTION,
        ),
        construction_environment={
            "MONDEK_RULES_NODE": node_id,
            # Preserve the declaration bytes, not just their mutable file path.
            "MONDEK_VOLUME_DECLARATIONS": raw,
        },
        checks=[
            Binding(
                volume_check(volume["id"], volume["label"]),
                outputs=(
                    Output(
                        "pending",
                        f"{volume['label']} pending items",
                        Target(f"volume:{volume['id']}", volume["label"], "volume"),
                    ),
                ),
            )
            for volume in volumes
        ],
    )
    application.register_datasource_factory(
        VolumeFiles, paths={volume["id"]: volume["path"] for volume in volumes}
    )
    return application


def declared_settings() -> str:
    if "MONDEK_VOLUME_DECLARATIONS" in os.environ:
        return os.environ["MONDEK_VOLUME_DECLARATIONS"]
    if path := os.environ.get("MONDEK_VOLUME_DECLARATIONS_FILE"):
        with Path(path).open(encoding="utf-8") as source:
            return source.read(MAX_SETTINGS_BYTES + 1)
    return "[]"


app = make_app(os.environ.get("MONDEK_RULES_NODE", "node-a"), declared_settings())
