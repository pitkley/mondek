# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Opt-in Linux host checks, expressed through the ordinary authoring API."""

from __future__ import annotations

import math
import os
import re
import sys
from collections.abc import Callable
from dataclasses import dataclass
from fnmatch import fnmatchcase
from hashlib import sha256
from pathlib import Path, PurePosixPath
from typing import Any

from mondek_runner import (
    Binding,
    CheckGroup,
    Environment,
    Output,
    Parameter,
    Placement,
    PlacementContext,
    Result,
    Target,
    check,
)
from mondek_runner.api import timestamp
from mondek_runner.authoring import canonical

CAPABILITY = "linux-host"
MAX_READ = 1024 * 1024


def _display_label(value: str) -> str:
    """Keep long mount paths in resource identity/evidence, within wire label limits."""
    encoded = value.encode()
    return (
        value if len(encoded) <= 200 else encoded[:197].decode(errors="ignore") + "..."
    )


def _path(value: str) -> str:
    if (
        not isinstance(value, str)
        or not value.startswith("/")
        or str(PurePosixPath(value)) != value
        or ".." in PurePosixPath(value).parts
        or len(value.encode()) > 1024
        or any(ord(c) < 32 or ord(c) == 127 for c in value)
    ):
        raise ValueError(
            "Linux paths must be canonical absolute paths within 1024 bytes"
        )
    return value


@dataclass(frozen=True)
class Interface:
    """An expected link; explicitly allow unknown for loopback/tunnel devices."""

    name: str
    healthy_states: tuple[str, ...] = ("up",)

    def __post_init__(self) -> None:
        if (
            not isinstance(self.name, str)
            or not re.fullmatch(r"[a-zA-Z0-9_.:-]{1,15}", self.name)
            or self.name in {".", ".."}
        ):
            raise ValueError("interface name requires 1–15 safe Linux name characters")
        if (
            not isinstance(self.healthy_states, tuple)
            or not self.healthy_states
            or any(
                state not in {"up", "unknown", "dormant"}
                for state in self.healthy_states
            )
        ):
            raise ValueError("healthy_states must select up, unknown and/or dormant")


@dataclass(frozen=True)
class Selection:
    """Case-sensitive glob selection; exclusions win. Patterns are comma-separated.

    Explicit LinuxHost.filesystems/interfaces are required expectations and are
    independent of discovery selection. Includes can open an exclude-all policy.
    """

    default_include: bool = True
    include: tuple[str, ...] = ()
    exclude: tuple[str, ...] = ()

    def __post_init__(self) -> None:
        if type(self.default_include) is not bool:
            raise ValueError("default_include must be a boolean")
        for patterns in (self.include, self.exclude):
            if not isinstance(patterns, tuple):
                raise ValueError("selection patterns must be tuples")
            if any(
                not isinstance(pattern, str) or "," in pattern for pattern in patterns
            ):
                raise ValueError("patterns must be strings without comma delimiters")
            _patterns(",".join(patterns))


def _patterns(value: str) -> tuple[str, ...]:
    if not isinstance(value, str) or len(value.encode()) > 2048:
        raise ValueError("selection patterns must fit within 2048 bytes")
    patterns = tuple(line.strip() for line in value.split(",") if line.strip())
    if len(patterns) > 64 or any(
        len(pattern) > 256 or any(ord(c) < 32 or ord(c) == 127 for c in pattern)
        for pattern in patterns
    ):
        raise ValueError("select at most 64 glob patterns, each within 256 characters")
    return patterns


def _selected(value: str, default_include: bool, include: str, exclude: str) -> bool:
    return (
        default_include or any(fnmatchcase(value, p) for p in _patterns(include))
    ) and not any(fnmatchcase(value, p) for p in _patterns(exclude))


# Capacity checks for kernel pseudo filesystems and immutable images are generally
# meaningless. These are configurable defaults; overlay/CSI mounts remain eligible.
DEFAULT_FILESYSTEM_TYPES = (
    "proc",
    "sysfs",
    "devtmpfs",
    "devpts",
    "tmpfs",
    "ramfs",
    "squashfs",
    "cgroup*",
    "securityfs",
    "debugfs",
    "tracefs",
    "pstore",
    "configfs",
    "fusectl",
    "mqueue",
    "hugetlbfs",
    "rpc_pipefs",
    "autofs",
    "binfmt_misc",
    "nsfs",
    "bpf",
)


@dataclass(frozen=True)
class LinuxHost:
    """Required expectations and optional discovery; construction never probes hosts.

    root='/' observes the native namespace. A different root explicitly opts into
    host bind-mount access: proc/1/mountinfo must describe that host and selected
    filesystem device IDs must match. Host sysfs must be visible for link checks.
    """

    target: Target
    environment: Environment
    filesystems: tuple[str, ...] = ("/",)
    interfaces: tuple[Interface, ...] = ()
    memory: bool = True
    cpu_load: bool = True
    root: str = "/"
    interval_seconds: float = 60
    timeout_seconds: float = 10
    freshness_seconds: float = 180
    discover: bool = False
    filesystem_selection: Selection = Selection()
    interface_selection: Selection = Selection(
        exclude=("lo", "veth*", "docker*", "br-*")
    )
    excluded_filesystem_types: tuple[str, ...] = DEFAULT_FILESYSTEM_TYPES
    disappearance_grace_seconds: float = 120

    def __post_init__(self) -> None:
        if not isinstance(self.target, Target) or self.target.kind != "host":
            raise ValueError("LinuxHost requires a host Target")
        self.target.to_dict()
        if not isinstance(self.environment, Environment):
            raise ValueError("LinuxHost requires an Environment")
        _path(self.root)
        if type(self.discover) is not bool:
            raise ValueError("discover must be a boolean")
        if not isinstance(self.filesystem_selection, Selection) or not isinstance(
            self.interface_selection, Selection
        ):
            raise ValueError("resource selection requires Selection")
        if not isinstance(self.excluded_filesystem_types, tuple):
            raise ValueError("excluded_filesystem_types must be a tuple")
        _patterns(",".join(self.excluded_filesystem_types))
        if (
            isinstance(self.disappearance_grace_seconds, bool)
            or not isinstance(self.disappearance_grace_seconds, (int, float))
            or not math.isfinite(self.disappearance_grace_seconds)
            or not 0 <= self.disappearance_grace_seconds <= 86400
        ):
            raise ValueError("disappearance grace must be between 0 and 86400 seconds")
        if not isinstance(self.filesystems, tuple) or len(self.filesystems) > 128:
            raise ValueError("select at most 128 filesystem paths as a tuple")
        for path in self.filesystems:
            _path(path)
        if len(set(self.filesystems)) != len(self.filesystems):
            raise ValueError("duplicate filesystem selection")
        if (
            not isinstance(self.interfaces, tuple)
            or len(self.interfaces) > 128
            or any(
                not isinstance(interface, Interface) for interface in self.interfaces
            )
        ):
            raise ValueError("select at most 128 Interface declarations as a tuple")
        if len({item.name for item in self.interfaces}) != len(self.interfaces):
            raise ValueError("duplicate interface selection")
        if type(self.memory) is not bool or type(self.cpu_load) is not bool:
            raise ValueError("memory and cpu_load must be booleans")


class EvidenceError(ValueError):
    pass


def _read(path: Path) -> str:
    with path.open("rb") as handle:
        data = handle.read(MAX_READ + 1)
    if len(data) > MAX_READ:
        raise EvidenceError("kernel evidence exceeds 1 MiB")
    return data.decode("utf-8", errors="surrogateescape")


def _percent(used: int, total: int) -> float:
    if total <= 0 or not 0 <= used <= total:
        raise EvidenceError("inconsistent kernel capacity counters")
    return 100 * used / total


def _health(value: float, warning: float, critical: float) -> str:
    return "CRIT" if value >= critical else "WARN" if value >= warning else "OK"


def _measured(
    health: str, summary: str, value: float | None = None, details: str | None = None
) -> Result:
    return Result("health", health, summary, value, timestamp(), details=details)


def _memory(root: Path, params: dict[str, Any]) -> Result:
    values: dict[str, int] = {}
    for line in _read(root / "proc/meminfo").splitlines():
        if line.split(":", 1)[0] in {"MemTotal", "MemAvailable"}:
            match = re.fullmatch(r"(MemTotal|MemAvailable):\s+(\d+) kB", line)
            if not match or match[1] in values:
                raise EvidenceError("invalid memory counters")
            values[match[1]] = int(match[2])
    if set(values) != {"MemTotal", "MemAvailable"}:
        raise EvidenceError("MemTotal/MemAvailable missing; Linux 3.14+ required")
    value = _percent(values["MemTotal"] - values["MemAvailable"], values["MemTotal"])
    return _measured(
        _health(value, params["warning"], params["critical"]),
        f"Memory {value:.1f}% used",
        value,
        f"Available: {values['MemAvailable']} KiB of {values['MemTotal']} KiB. "
        "Uses MemAvailable, including reclaimable cache; host memory, "
        "not a cgroup limit.\n"
        f"Warning at or above {params['warning']:g}%; "
        f"critical at or above {params['critical']:g}%.",
    )


def _load(root: Path, params: dict[str, Any]) -> Result:
    fields = _read(root / "proc/loadavg").split()
    if len(fields) != 5:
        raise EvidenceError("invalid load average")
    loads = [float(value) for value in fields[:3]]
    if any(not math.isfinite(value) or value < 0 for value in loads):
        raise EvidenceError("invalid load average")
    cpus = [
        line.split()[0]
        for line in _read(root / "proc/stat").splitlines()
        if re.match(r"cpu\d+\s", line)
    ]
    if not cpus or len(set(cpus)) != len(cpus):
        raise EvidenceError("online CPU counters missing or duplicated")
    value = loads[1] / len(cpus)
    return _measured(
        _health(value, params["warning"], params["critical"]),
        f"5-minute CPU load {value:.2f} per CPU",
        value,
        f"Load averages (1/5/15 min): {loads}. Online CPUs: {len(cpus)}. "
        "Includes runnable and uninterruptible tasks; this is not CPU "
        "utilization or cgroup quota usage.\n"
        f"Warning at or above {params['warning']:g} per CPU; "
        f"critical at or above {params['critical']:g} per CPU.",
    )


def _unescape(value: str) -> str:
    return re.sub(r"\\(040|011|012|134)", lambda match: chr(int(match[1], 8)), value)


def _mounts(root: Path) -> list[dict[str, str]]:
    relative = "proc/self/mountinfo" if root == Path("/") else "proc/1/mountinfo"
    lines = _read(root / relative).splitlines()
    if not lines:
        raise EvidenceError("empty mount inventory")
    if len(lines) > 4096:
        raise EvidenceError("mount inventory exceeds 4096 entries")
    result = []
    for line in lines:
        fields = line.split()
        if len(fields) < 10 or "-" not in fields[6:]:
            raise EvidenceError("invalid mount inventory")
        separator = fields.index("-", 6)
        if len(fields) != separator + 4 or not re.fullmatch(
            r"[0-9]+:[0-9]+", fields[2]
        ):
            raise EvidenceError("invalid mount inventory")
        result.append(
            {
                "path": _unescape(fields[4]),
                "device": fields[2],
                "type": fields[separator + 1],
            }
        )
    return result


def _mount_device(root: Path, mountpoint: str) -> int | None:
    matches = [item for item in _mounts(root) if item["path"] == mountpoint]
    if len(matches) > 1:
        # An automount and its mounted filesystem legitimately share a path.
        # Match the device visible through this namespace, never inventory order.
        # Same-device stacks remain ambiguous; the caller also checks visibility
        # and re-reads inventory after statvfs to reject mount changes.
        visible = (root / mountpoint.lstrip("/")).stat().st_dev
        matches = [
            item
            for item in matches
            if os.makedev(*(int(part) for part in item["device"].split(":"))) == visible
        ]
        if len(matches) != 1:
            raise EvidenceError("overmounted filesystem is ambiguous")
    if not matches:
        return None
    major, minor = matches[0]["device"].split(":")
    return os.makedev(int(major), int(minor))


def _interface_names(root: Path) -> list[str]:
    with os.scandir(root / "sys/class/net") as entries:
        names = []
        for entry in entries:
            names.append(entry.name)
            if len(names) > 4096:
                raise EvidenceError("network inventory exceeds 4096 interfaces")
    return names


def _discover(root: Path, params: dict[str, Any]) -> dict[str, dict[str, Any]]:
    """A complete bounded scan. Any failure must preserve the previous catalog."""
    if sys.platform != "linux":
        raise EvidenceError("Linux discovery requires Linux")
    resources: dict[str, dict[str, Any]] = {}
    for item in _mounts(root):
        path = item["path"]
        _path(path)
        key = "filesystem:" + path
        resource = resources.setdefault(
            key, {"kind": "filesystem", "name": path, "filesystem_types": []}
        )
        # Mount stacks are legitimate (including systemd sandbox mounts). Keep
        # all types for selection, never guess which entry is visible. Capacity
        # collection independently rejects ambiguous selected mountpoints.
        resource["filesystem_types"] = sorted(
            set(resource["filesystem_types"]) | {item["type"]}
        )
    for name in _interface_names(root):
        Interface(name)
        resources["interface:" + name] = {"kind": "interface", "name": name}
    return resources


def _select_resource(
    key: str, resource: dict[str, Any], params: dict[str, Any]
) -> bool:
    kind = resource["kind"]
    if kind == "filesystem":
        types = resource["filesystem_types"]
        excluded = _patterns(params["filesystem_excluded_types"])
        if all(
            any(fnmatchcase(kind, pattern) for pattern in excluded) for kind in types
        ):
            return False
    return _selected(
        resource["name"],
        params[kind + "_default_include"],
        params[kind + "_include"],
        params[kind + "_exclude"],
    )


def _filesystem(
    root: Path, mountpoint: str, params: dict[str, Any], *, required: bool = True
) -> Result:
    device = _mount_device(root, mountpoint)
    if device is None:
        return (
            _measured("CRIT", f"Expected filesystem {mountpoint} is not mounted")
            if required
            else Result(
                "health",
                "UNKNOWN",
                f"Discovered filesystem {mountpoint} is no longer mounted; "
                "awaiting retirement",
            )
        )
    path = root / mountpoint.lstrip("/")
    before = path.stat()
    if before.st_dev != device:
        raise EvidenceError(
            "filesystem device does not match host mount inventory; check bind mounts"
        )
    stats = os.statvfs(path)
    # A second inventory/stat prevents common unmount races reporting root usage.
    if _mount_device(root, mountpoint) != device or path.stat().st_dev != device:
        raise EvidenceError("filesystem changed during collection")
    if (
        stats.f_frsize <= 0
        or not 0 <= stats.f_bavail <= stats.f_bfree <= stats.f_blocks
    ):
        raise EvidenceError("invalid filesystem block counters")
    used = stats.f_blocks - stats.f_bfree
    value = _percent(used, used + stats.f_bavail)
    health = _health(value, params["warning"], params["critical"])
    inode_text = "Inode counts not supplied by this filesystem."
    if stats.f_files:
        inode = _percent(stats.f_files - stats.f_ffree, stats.f_files)
        inode_health = _health(inode, params["inode_warning"], params["inode_critical"])
        health = max(
            (health, inode_health), key={"OK": 0, "WARN": 1, "CRIT": 2}.__getitem__
        )
        inode_text = f"Inodes {inode:.1f}% used."
    return _measured(
        health,
        f"Filesystem {mountpoint}: {value:.1f}% used; {inode_text}",
        value,
        f"Available to unprivileged processes: {stats.f_bavail * stats.f_frsize} "
        f"bytes. Block percentage excludes reserved free blocks. {inode_text}\n"
        f"Block usage: warning at or above {params['warning']:g}%; "
        f"critical at or above {params['critical']:g}%.\n"
        f"Inode usage (when supplied): warning at or above "
        f"{params['inode_warning']:g}%; "
        f"critical at or above {params['inode_critical']:g}%.",
    )


def _interface(root: Path, interface: Interface, *, required: bool = True) -> Result:
    directory = root / "sys/class/net"
    # Missing sysfs access is unavailable, not evidence that an expected link vanished.
    names = _interface_names(root)
    if interface.name not in names:
        return (
            _measured("CRIT", f"Expected interface {interface.name} is missing")
            if required
            else Result(
                "health",
                "UNKNOWN",
                f"Discovered interface {interface.name} is no longer present; "
                "awaiting retirement",
            )
        )
    state = _read(directory / interface.name / "operstate").strip()
    if state not in {
        "unknown",
        "notpresent",
        "down",
        "lowerlayerdown",
        "testing",
        "dormant",
        "up",
    }:
        raise EvidenceError("invalid interface operational state")
    health = "OK" if state in interface.healthy_states else "CRIT"
    return _measured(
        health,
        f"Interface {interface.name}: {state}",
        details=f"Expected states: {', '.join(interface.healthy_states)}. "
        "Link state does not establish connectivity, traffic rate or packet loss.",
    )


def linux_checks(host: LinuxHost) -> list[Binding]:
    """Declare host checks and optional discovery without performing host I/O."""
    return _linux_checks(host)


def _linux_checks(host: LinuxHost, *, _discovered: bool = False) -> list[Binding]:
    """Return selected, stable ordinary bindings; no installation or collection I/O."""
    if not isinstance(host, LinuxHost):
        raise TypeError("linux_checks requires LinuxHost")
    bindings: list[Binding] = []
    root = Path(host.root)
    group = CheckGroup(host.target.key, host.target.label)

    def on_host(context: PlacementContext) -> str | None:
        target = context.runner.target
        if target is None or (target.key, target.kind) != (
            host.target.key,
            host.target.kind,
        ):
            return f"Requires Linux host {host.target.key}"
        return None

    def add(
        kind: str,
        resource: str,
        name: str,
        collect: Callable[[dict[str, Any]], Result],
        *,
        defaults: dict[str, Any] | None = None,
        fields: dict[str, Parameter] | None = None,
    ) -> None:
        name = _display_label(name)
        fields = fields or {}
        comparisons = tuple(
            (key, "lt", key.replace("warning", "critical"))
            for key in fields
            if "warning" in key
        )

        @check(
            id=f"linux.{kind}",
            name=name,
            outputs=(Output("health", name),),
            params=defaults,
            parameters=fields,
            parameter_contract=f"mondek.linux.{kind}.v1" if fields else None,
            comparisons=comparisons,
            interval_seconds=host.interval_seconds,
            timeout_seconds=host.timeout_seconds,
            freshness_seconds=host.freshness_seconds,
            placement=Placement(
                requires=(CAPABILITY,), locality="same-environment", policy=on_host
            ),
        )
        def collect_check(params: dict[str, Any]) -> Result:
            if sys.platform != "linux":
                return Result("health", "UNKNOWN", "Linux host evidence requires Linux")
            try:
                return collect(params)
            except (OSError, ValueError, UnicodeError, OverflowError) as error:
                reason = (
                    "permission denied"
                    if isinstance(error, PermissionError)
                    else "kernel evidence missing, inaccessible or invalid"
                )
                return Result(
                    "health",
                    "UNKNOWN",
                    f"{name}: {reason}",
                    details=str(error) if isinstance(error, EvidenceError) else None,
                )

        key = (
            "linux."
            + kind
            + ":"
            + sha256(
                canonical([host.environment.id, host.target.key, resource])
            ).hexdigest()[:32]
        )
        from mondek_runner.authoring import ManagedResource

        bindings.append(
            Binding(
                collect_check,
                key=key,
                target=Target(
                    f"linux.{kind}:"
                    + sha256(canonical([host.target.key, resource])).hexdigest()[:32],
                    _display_label(f"{host.target.label}: {resource}"),
                    "filesystem" if kind == "filesystem" else "interface",
                )
                if kind in {"filesystem", "interface"}
                else host.target,
                environment=host.environment,
                group=group,
                discovery=ManagedResource(
                    "linux.discovery:"
                    + sha256(
                        canonical([host.environment.id, host.target.key, "discovery"])
                    ).hexdigest()[:32],
                    kind,
                    resource,
                    "discovered" if _discovered else "required",
                )
                if kind in {"filesystem", "interface"}
                and (host.discover or _discovered)
                else None,
            )
        )

    percent = {
        key: Parameter("number", label, "% used", 0, 100)
        for key, label in (("warning", "Warning at"), ("critical", "Critical at"))
    }
    if host.memory:
        add(
            "memory",
            "memory",
            "Linux memory",
            lambda params: _memory(root, params),
            defaults={"warning": 80, "critical": 90},
            fields=percent,
        )
    if host.cpu_load:
        add(
            "load",
            "load",
            "Linux CPU load (5 minutes)",
            lambda params: _load(root, params),
            defaults={"warning": 1, "critical": 2},
            fields={
                key: Parameter("number", label, "load per CPU", 0, 1024)
                for key, label in (
                    ("warning", "Warning at"),
                    ("critical", "Critical at"),
                )
            },
        )
    for mountpoint in host.filesystems:
        add(
            "filesystem",
            mountpoint,
            f"Filesystem {mountpoint}",
            lambda params, mountpoint=mountpoint: _filesystem(
                root, mountpoint, params, required=not _discovered
            ),
            defaults={
                "warning": 80,
                "critical": 90,
                "inode_warning": 80,
                "inode_critical": 90,
            },
            fields=percent
            | {
                "inode_warning": Parameter(
                    "number", "Inode warning at", "% used", 0, 100
                ),
                "inode_critical": Parameter(
                    "number", "Inode critical at", "% used", 0, 100
                ),
            },
        )
    for interface in host.interfaces:
        add(
            "interface",
            interface.name,
            f"Interface {interface.name}",
            lambda params, interface=interface: _interface(
                root, interface, required=not _discovered
            ),
        )
    if host.discover:
        from dataclasses import replace

        from mondek_runner.authoring import DiscoveryCatalog

        defaults = {
            "filesystem_default_include": host.filesystem_selection.default_include,
            "filesystem_include": ",".join(host.filesystem_selection.include),
            "filesystem_exclude": ",".join(host.filesystem_selection.exclude),
            "filesystem_excluded_types": ",".join(host.excluded_filesystem_types),
            "interface_default_include": host.interface_selection.default_include,
            "interface_include": ",".join(host.interface_selection.include),
            "interface_exclude": ",".join(host.interface_selection.exclude),
        }
        fields = {
            "filesystem_default_include": Parameter(
                "boolean", "Include filesystems by default"
            ),
            "interface_default_include": Parameter(
                "boolean", "Include interfaces by default"
            ),
        }
        fields.update(
            {
                key: Parameter("string", label, max_length=2048)
                for key, label in (
                    (
                        "filesystem_include",
                        "Include mount paths (comma-separated globs)",
                    ),
                    (
                        "filesystem_exclude",
                        "Exclude mount paths (comma-separated globs)",
                    ),
                    (
                        "filesystem_excluded_types",
                        "Exclude filesystem types (comma-separated globs)",
                    ),
                    ("interface_include", "Include interfaces (comma-separated globs)"),
                    ("interface_exclude", "Exclude interfaces (comma-separated globs)"),
                )
            }
        )

        def select(key: str, resource: dict[str, Any], params: dict[str, Any]) -> bool:
            if (
                resource["kind"] == "filesystem"
                and resource["name"] in host.filesystems
            ):
                return False
            if resource["kind"] == "interface" and resource["name"] in {
                item.name for item in host.interfaces
            }:
                return False
            return _select_resource(key, resource, params)

        def scan(params: dict[str, Any]) -> dict[str, dict[str, Any]]:
            # Validate every pattern even with an empty or fully excluded inventory.
            for key, value in params.items():
                if not key.endswith("default_include"):
                    try:
                        _patterns(value)
                    except ValueError as error:
                        # These are fixed validation messages, never raw kernel
                        # contents or user-supplied pattern text.
                        raise EvidenceError(f"{key}: {error}") from None
            return _discover(root, params)

        def policy_result(params: dict[str, Any]) -> Result:
            resources = scan(params)
            if len(resources) > 4096:
                raise EvidenceError("Linux discovery exceeds 4096 observed resources")
            selected = sum(select(key, item, params) for key, item in resources.items())
            if selected > 512:
                raise EvidenceError(
                    "Linux discovery exceeds 512 selected resources; narrow selection"
                )
            return _measured(
                "OK",
                f"Linux discovery: {selected} selected resources",
                details=(
                    "Selection applies automatically to future resources. "
                    "Exclusions override includes. "
                    "Explicit filesystem and interface expectations stay required "
                    "independently of selection. "
                    "Mount identities are host-local paths; moving a CSI volume "
                    "creates a new host-local result."
                ),
            )

        add(
            "discovery",
            "discovery",
            "Linux resource discovery",
            policy_result,
            defaults=defaults,
            fields=fields,
        )

        def bind(key: str, resource: dict[str, Any], present: bool) -> Binding:
            dynamic_host = replace(
                host,
                discover=False,
                memory=False,
                cpu_load=False,
                filesystems=(resource["name"],)
                if resource["kind"] == "filesystem"
                else (),
                interfaces=(Interface(resource["name"], ("up", "unknown")),)
                if resource["kind"] == "interface"
                else (),
            )
            return _linux_checks(dynamic_host, _discovered=True)[0]

        bindings[-1].function.mondek_discovery = DiscoveryCatalog(
            scan,
            bind,
            select=select,
            interval_seconds=host.interval_seconds,
            grace_seconds=host.disappearance_grace_seconds,
            capability="linux.resources.v1",
        )
    return bindings
