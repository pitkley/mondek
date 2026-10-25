# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Explicit node resources with independent scheduling and private access paths."""

from __future__ import annotations

import json
import re
from collections.abc import Mapping
from dataclasses import dataclass
from typing import Annotated, Any, Callable

from mondek_runner import (
    App,
    Binding,
    Datasource,
    DatasourceFactory,
    Environment,
    FromFactory,
    Output,
    Result,
    Target,
    check,
)

from .node_common import (
    LocalFile,
    LocalFilesystem,
    LocalProcess,
    capacity_policy,
    file_policy,
    inspect_file,
)

MAX_SETTINGS_BYTES = 48 * 1024


def _identity(value: str, maximum: int) -> None:
    if not isinstance(value, str) or not re.fullmatch(
        rf"[A-Za-z0-9][A-Za-z0-9_.-]{{0,{maximum - 1}}}", value
    ):
        raise ValueError(
            f"Resource identity requires 1–{maximum} letters, digits, dots, underscores or hyphens"
        )


def _resource(id: str, label: str | None, *paths: str) -> None:
    _identity(id, 40)
    if label is not None and (
        not isinstance(label, str)
        or not label.strip()
        or len(label.encode()) > 64
        or any(ord(character) < 32 or ord(character) == 127 for character in label)
    ):
        raise ValueError("Resource label requires nonempty text within 64 bytes")
    for path in paths:
        if (
            not isinstance(path, str)
            or not path.startswith("/")
            or len(path.encode()) > 1024
            or any(ord(character) < 32 or ord(character) == 127 for character in path)
        ):
            raise ValueError(
                "Resource access paths must be absolute and within 1024 bytes"
            )


@dataclass(frozen=True)
class FileResource:
    id: str
    path: str
    label: str | None = None

    def __post_init__(self) -> None:
        _resource(self.id, self.label, self.path)


@dataclass(frozen=True)
class ProcessResource:
    id: str
    pid_file: str
    expected_executable: str
    label: str | None = None

    def __post_init__(self) -> None:
        _resource(self.id, self.label, self.pid_file, self.expected_executable)


@dataclass(frozen=True)
class MountResource:
    """The filesystem containing this path; not an assertion of mount presence."""

    id: str
    path: str
    label: str | None = None

    def __post_init__(self) -> None:
        _resource(self.id, self.label, self.path)


@dataclass(frozen=True)
class NodeResources:
    node_id: str
    node_label: str | None = None
    files: tuple[FileResource, ...] = ()
    processes: tuple[ProcessResource, ...] = ()
    mounts: tuple[MountResource, ...] = ()
    interval_seconds: int = 30

    def __post_init__(self) -> None:
        _identity(self.node_id, 64)
        Environment(self.node_id, self.node_label)
        if (
            type(self.interval_seconds) is not int
            or not 5 <= self.interval_seconds <= 3600
        ):
            raise ValueError(
                "Resource interval must be an integer from 5 to 3600 seconds"
            )
        total = 0
        for name, kind in (
            ("files", FileResource),
            ("processes", ProcessResource),
            ("mounts", MountResource),
        ):
            items = getattr(self, name)
            if not isinstance(items, (tuple, list)) or not all(
                isinstance(item, kind) for item in items
            ):
                raise ValueError("Resources require explicit typed lists")
            if len({item.id for item in items}) != len(items):
                raise ValueError(
                    "Resource IDs must be unique within each resource kind"
                )
            object.__setattr__(self, name, tuple(items))
            total += len(items)
        if not 1 <= total <= 512:
            raise ValueError("Node resources require 1–512 explicitly named checks")


class NodeResourceFactory(DatasourceFactory):
    def __init__(self, resources: dict[str, dict[str, str]]):
        self.resources = resources

    def new(self, key: str) -> Datasource:
        settings = dict(self.resources[key])
        kind = settings.pop("kind")
        if kind == "file":
            return LocalFile(**settings)
        if kind == "filesystem":
            return LocalFilesystem(**settings)
        if kind == "process":
            return LocalProcess(**settings)
        raise ValueError("Unknown prepared node resource kind")


def resource_check(
    kind: str, key: str, label: str, interval: int
) -> Callable[..., Result]:
    if kind == "file":

        def probe(source: LocalFile, params: dict[str, int]) -> Result:
            return inspect_file(source, params)

        datasource, policy, output = LocalFile, file_policy(), "file"
    elif kind == "filesystem":

        def probe(source: LocalFilesystem, params: dict[str, float]) -> Result:
            return source.inspect(params)

        datasource, policy, output = LocalFilesystem, capacity_policy(), "capacity"
    else:

        def probe(source: LocalProcess) -> Result:
            return source.inspect()

        datasource, policy, output = LocalProcess, {}, "process"
    probe.__annotations__["source"] = Annotated[
        datasource, FromFactory(NodeResourceFactory, key)
    ]
    return check(
        id=key,
        name=label,
        expected_keys=(output,),
        interval_seconds=interval,
        timeout_seconds=5,
        freshness_seconds=interval * 3,
        **policy,
    )(probe)


def make_app(
    configuration: NodeResources,
    *,
    construction_environment: Mapping[str, str | None] | None = None,
) -> App:
    """Every configured resource is one independently scheduled check."""
    if not isinstance(configuration, NodeResources):
        raise ValueError("Node resources require a NodeResources configuration")
    node_label = configuration.node_label or configuration.node_id
    consumer = App(
        source_id="node-resources",
        name=f"{node_label} resource checks",
        environment=Environment(configuration.node_id, node_label),
        construction_environment=construction_environment,
    )
    settings = {}
    for kind, resources in (
        ("filesystem", configuration.mounts),
        ("file", configuration.files),
        ("process", configuration.processes),
    ):
        for resource in resources:
            key = f"{kind}:{resource.id}"
            label = resource.label or resource.id
            description = (
                f"Filesystem containing {label}"
                if kind == "filesystem"
                else f"{label} {kind}"
            )
            function = resource_check(
                kind, key, description, configuration.interval_seconds
            )
            consumer.add(
                Binding(
                    function,
                    outputs=(
                        Output(
                            function.expected_keys[0],
                            description,
                            Target(
                                f"node:{configuration.node_id}/{key}",
                                f"{node_label} / {label}",
                                kind,
                            ),
                        ),
                    ),
                )
            )
            settings[key] = (
                {
                    "kind": kind,
                    "pid_file": resource.pid_file,
                    "expected_executable": resource.expected_executable,
                }
                if isinstance(resource, ProcessResource)
                else {"kind": kind, "path": resource.path}
            )
    consumer.register_datasource_factory(NodeResourceFactory, resources=settings)
    return consumer


def configuration_from_settings(raw: str) -> NodeResources:
    """Strict bounded JSON; duplicate IDs/fields or partial configuration fail discovery."""
    if not isinstance(raw, str) or not raw or len(raw.encode()) > MAX_SETTINGS_BYTES:
        raise ValueError("MONDEK_NODE_RESOURCES_SETTINGS requires JSON within 48 KiB")

    def unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError("Duplicate settings field")
            result[key] = value
        return result

    try:
        settings = json.loads(raw, object_pairs_hook=unique_object)
    except (ValueError, TypeError, RecursionError):
        raise ValueError(
            "Node resource settings contain malformed or duplicate JSON fields"
        ) from None
    allowed = {
        "node_id",
        "node_label",
        "interval_seconds",
        "files",
        "processes",
        "mounts",
    }
    if (
        not isinstance(settings, dict)
        or "node_id" not in settings
        or set(settings) - allowed
    ):
        raise ValueError(
            "Node resource settings require node_id and only documented fields"
        )
    for name, kind, required in (
        ("files", FileResource, {"id", "path"}),
        ("processes", ProcessResource, {"id", "pid_file", "expected_executable"}),
        ("mounts", MountResource, {"id", "path"}),
    ):
        resources = settings.get(name, [])
        if not isinstance(resources, list) or len(resources) > 512:
            raise ValueError("Node resources require bounded explicit lists")
        if any(
            not isinstance(item, dict)
            or not required <= set(item)
            or set(item) - required - {"label"}
            for item in resources
        ):
            raise ValueError(
                "Each resource requires its ID and complete access settings"
            )
        settings[name] = tuple(kind(**item) for item in resources)
    return NodeResources(**settings)
