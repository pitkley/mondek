# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""A node-installed consumer with optional ordinary file and PID-file checks."""

from __future__ import annotations

import os
import re
from collections.abc import Mapping
from dataclasses import dataclass

from mondek_runner import (
    App,
    Binding,
    Environment,
    Output,
    Result,
    Target,
    check,
)
from .node_common import (
    LocalFile as LocalFile,
    LocalProcess as LocalProcess,
    ProcessIdentity as ProcessIdentity,
    capacity_policy,
    file_policy,
    filesystem_capacity,
    inspect_file as inspect_file,
    time as time,
)


def _identity(value: str, name: str, maximum: int) -> str:
    if (
        not isinstance(value, str)
        or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*", value)
        or len(value) > maximum
    ):
        raise ValueError(
            f"{name} needs 1–{maximum} letters, digits, dots, underscores or hyphens"
        )
    return value


def _path(value: str | None, name: str) -> str | None:
    if value is not None and (
        not isinstance(value, str)
        or not value.startswith("/")
        or len(value.encode()) > 1024
        or any(ord(character) < 32 or ord(character) == 127 for character in value)
    ):
        raise ValueError(f"{name} must be an absolute path within 1024 bytes")
    return value


@dataclass(frozen=True)
class NodeConfiguration:
    """Deployment owns identities and access paths; thresholds are declared below."""

    node_id: str
    node_label: str | None = None
    file_path: str | None = None
    file_id: str = "application"
    pid_file: str | None = None
    expected_executable: str | None = None
    process_id: str = "application"
    interval_seconds: int = 30

    def __post_init__(self) -> None:
        _identity(self.node_id, "node ID", 64)
        _identity(self.file_id, "file ID", 40)
        _identity(self.process_id, "process ID", 40)
        Environment(self.node_id, self.node_label)
        _path(self.file_path, "file path")
        _path(self.pid_file, "PID file")
        _path(self.expected_executable, "expected executable")
        if (self.pid_file is None) != (self.expected_executable is None):
            raise ValueError(
                "PID file and expected executable must be supplied together"
            )
        if (
            type(self.interval_seconds) is not int
            or not 5 <= self.interval_seconds <= 3600
        ):
            raise ValueError("interval must be an integer from 5 to 3600 seconds")


def configuration_from_environment(values: Mapping[str, str]) -> NodeConfiguration:
    if not values.get("MONDEK_LOCAL_NODE_ID"):
        raise ValueError("Set MONDEK_LOCAL_NODE_ID to this node's stable identity")
    try:
        interval = int(values.get("MONDEK_LOCAL_INTERVAL", "30"))
    except (ValueError, TypeError):
        raise ValueError(
            "MONDEK_LOCAL_INTERVAL must be an integer from 5 to 3600"
        ) from None
    return NodeConfiguration(
        node_id=values["MONDEK_LOCAL_NODE_ID"],
        node_label=values.get("MONDEK_LOCAL_NODE_LABEL"),
        file_path=values.get("MONDEK_LOCAL_FILE"),
        file_id=values.get("MONDEK_LOCAL_FILE_ID", "application"),
        pid_file=values.get("MONDEK_LOCAL_PID_FILE"),
        expected_executable=values.get("MONDEK_LOCAL_EXPECTED_EXECUTABLE"),
        process_id=values.get("MONDEK_LOCAL_PROCESS_ID", "application"),
        interval_seconds=interval,
    )


def make_app(
    configuration: NodeConfiguration,
    *,
    construction_environment: Mapping[str, str | None] | None = None,
) -> App:
    """Create an explicit node suite without requiring demo files or processes."""
    node = configuration.node_id
    label = configuration.node_label or node
    schedule = {
        "interval_seconds": configuration.interval_seconds,
        "timeout_seconds": 5,
        "freshness_seconds": configuration.interval_seconds * 3,
    }

    @check(
        id="root-filesystem",
        name="Node root filesystem capacity",
        expected_keys=("capacity",),
        **capacity_policy(),
        **schedule,
    )
    def root_filesystem(params: dict[str, float]) -> Result:
        return filesystem_capacity("/", params, description="Node root filesystem")

    consumer = App(
        source_id="node-local",
        name=f"{label} node checks",
        environment=Environment(node, label),
        construction_environment=construction_environment,
        checks=[
            Binding(
                root_filesystem,
                outputs=(
                    Output(
                        "capacity",
                        "Root filesystem capacity",
                        Target(f"node:{node}/root", f"{label} /", "filesystem"),
                    ),
                ),
            )
        ],
    )
    if configuration.file_path is not None:

        @check(
            id="configured-file",
            name="Node configured file",
            expected_keys=("file",),
            **file_policy(),
            **schedule,
        )
        def configured_file(files: LocalFile, params: dict[str, int]) -> Result:
            return inspect_file(files, params)

        consumer.add(
            Binding(
                configured_file,
                outputs=(
                    Output(
                        "file",
                        "Configured file",
                        Target(
                            f"node:{node}/file:{configuration.file_id}",
                            f"{label} {configuration.file_id} file",
                            "file",
                        ),
                    ),
                ),
            )
        )
        consumer.register_datasource(LocalFile, path=configuration.file_path)

    if configuration.pid_file is not None:

        @check(
            id="configured-process",
            name="Node configured process",
            expected_keys=("process",),
            **schedule,
        )
        def configured_process(process: LocalProcess) -> Result:
            return process.inspect()

        consumer.add(
            Binding(
                configured_process,
                outputs=(
                    Output(
                        "process",
                        "Configured process",
                        Target(
                            f"node:{node}/process:{configuration.process_id}",
                            f"{label} {configuration.process_id} process",
                            "process",
                        ),
                    ),
                ),
            )
        )
        consumer.register_datasource(
            LocalProcess,
            pid_file=configuration.pid_file,
            expected_executable=configuration.expected_executable,
        )
    return consumer


CONSTRUCTION_ENVIRONMENT = (
    "MONDEK_LOCAL_NODE_ID",
    "MONDEK_LOCAL_NODE_LABEL",
    "MONDEK_LOCAL_FILE",
    "MONDEK_LOCAL_FILE_ID",
    "MONDEK_LOCAL_PID_FILE",
    "MONDEK_LOCAL_EXPECTED_EXECUTABLE",
    "MONDEK_LOCAL_PROCESS_ID",
    "MONDEK_LOCAL_INTERVAL",
)

app = make_app(
    configuration_from_environment(os.environ),
    construction_environment={
        name: os.environ.get(name) for name in CONSTRUCTION_ENVIRONMENT
    },
)
