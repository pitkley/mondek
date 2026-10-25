# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Bounded node inspections shared by explicit single- and multi-resource consumers."""

from __future__ import annotations

import os
import re
import shutil
import stat
import sys
import time
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from mondek_runner import Datasource, Parameter, Result
from mondek_runner.api import timestamp


def capacity_policy() -> dict[str, Any]:
    """One complete percentage policy shared by the node consumers."""
    return {
        "params": {"warn_percent": 80, "crit_percent": 90},
        "parameters": {
            "warn_percent": Parameter("number", "Warning at", "% used", 0, 100),
            "crit_percent": Parameter("number", "Critical at", "% used", 0, 100),
        },
        "parameter_contract": "root-filesystem.used-percent.v1",
        "comparisons": (("warn_percent", "lt", "crit_percent"),),
    }


def file_policy() -> dict[str, Any]:
    """One complete file size/age policy; paths remain private source settings."""
    return {
        "params": {
            "minimum_bytes": 1,
            "warn_age_seconds": 3600,
            "crit_age_seconds": 7200,
        },
        "parameters": {
            "minimum_bytes": Parameter(
                "integer", "Minimum size", "bytes", 0, 2**63 - 1
            ),
            "warn_age_seconds": Parameter(
                "integer", "Warning after", "seconds", 0, 31_536_000
            ),
            "crit_age_seconds": Parameter(
                "integer", "Critical after", "seconds", 1, 31_536_000
            ),
        },
        "parameter_contract": "regular-file.size-and-age.v1",
        "comparisons": (("warn_age_seconds", "lt", "crit_age_seconds"),),
    }


def filesystem_capacity(
    path: str,
    params: Mapping[str, float],
    *,
    description: str = "Configured filesystem",
) -> Result:
    try:
        usage = shutil.disk_usage(path)
    except OSError:
        return Result("capacity", "UNKNOWN", f"Cannot inspect {description.lower()}")
    if usage.total <= 0:
        return Result("capacity", "UNKNOWN", "Filesystem reports no usable capacity")
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
        f"{description} is {percent:.1f}% used",
        percent,
        timestamp(),
    )


class LocalFilesystem(Datasource):
    def __init__(self, path: str):
        self.path = path

    def inspect(self, params: Mapping[str, float]) -> Result:
        # Capacity belongs to the filesystem containing the configured path;
        # this does not assert that an intended mount is attached there.
        return filesystem_capacity(self.path, params)


class ChangingInput(ValueError):
    """A bounded inspection crossed an input replacement; try again next run."""


def _file_identity(value: os.stat_result) -> tuple[int, int, int, int]:
    return value.st_dev, value.st_ino, value.st_size, value.st_mtime_ns


def _read_regular(path: Path, limit: int) -> tuple[bytes, os.stat_result]:
    # Opening a FIFO or device must not wait for a producer. No whole-file read.
    descriptor = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode):
            raise ValueError("configured path is not a regular file")
        content = os.read(descriptor, limit)
        after = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    if _file_identity(before) != _file_identity(after) or _file_identity(
        after
    ) != _file_identity(path.stat()):
        raise ChangingInput("configured file changed during inspection")
    return content, after


class LocalFile(Datasource):
    def __init__(self, path: str):
        self.path = Path(path)

    def inspect(self) -> os.stat_result:
        # Reading a byte distinguishes an accessible file from stat-only access.
        _, metadata = _read_regular(self.path, 1)
        return metadata


def inspect_file(files: LocalFile, params: Mapping[str, int]) -> Result:
    try:
        metadata = files.inspect()
    except FileNotFoundError:
        return Result("file", "CRIT", "Required file is missing", source_at=timestamp())
    except ChangingInput:
        return Result("file", "UNKNOWN", "Configured file changed during inspection")
    except ValueError:
        return Result(
            "file",
            "CRIT",
            "Configured path is not a regular file",
            source_at=timestamp(),
        )
    except OSError as error:
        return Result(
            "file",
            "UNKNOWN",
            f"Cannot read configured file: {error.strerror or type(error).__name__}",
        )

    age = (time.time_ns() - metadata.st_mtime_ns) / 1_000_000_000
    if age < -2:
        return Result(
            "file",
            "CRIT",
            "File modification time is in the future",
            source_at=timestamp(),
        )
    age = max(0.0, age)
    summary = f"File is {metadata.st_size} bytes; modified {age:.1f} seconds ago"
    if metadata.st_size < params["minimum_bytes"]:
        health = "CRIT"
        summary += f"; below minimum size {params['minimum_bytes']} bytes"
    elif age > params["crit_age_seconds"]:
        health = "CRIT"
        summary += f"; older than critical limit {params['crit_age_seconds']} seconds"
    elif age > params["warn_age_seconds"]:
        health = "WARN"
        summary += f"; older than warning limit {params['warn_age_seconds']} seconds"
    else:
        health = "OK"
    return Result("file", health, summary, age, timestamp())


@dataclass(frozen=True)
class ProcessIdentity:
    pid: int
    start_ticks: int
    state: str


class LocalProcess(Datasource):
    def __init__(self, pid_file: str, expected_executable: str):
        self.pid_file = Path(pid_file)
        self.expected_executable = expected_executable

    def available(self) -> bool:
        return sys.platform == "linux" and Path("/proc/self/stat").is_file()

    def read_pid(self) -> tuple[int, tuple[int, int, int, int]]:
        content, metadata = _read_regular(self.pid_file, 65)
        if (
            metadata.st_size > 64
            or len(content) > 64
            or not re.fullmatch(rb"[ \t]*[0-9]{1,10}[ \t]*\n?", content)
        ):
            raise ValueError("PID file must contain one positive decimal PID")
        pid = int(content)
        if not 1 <= pid <= 2_147_483_647:
            raise ValueError("PID file contains an out-of-range PID")
        return pid, _file_identity(metadata)

    def identity(self, pid: int) -> ProcessIdentity:
        with Path(f"/proc/{pid}/stat").open("rb") as source:
            raw = source.read(8193)
        if len(raw) > 8192:
            raise ValueError("process identity exceeds its read bound")
        number, separator, rest = raw.partition(b" (")
        _, end, fields = rest.rpartition(b") ")
        parts = fields.split()
        if not separator or not end or int(number) != pid or len(parts) < 20:
            raise ValueError("process identity is malformed")
        start = int(parts[19])
        if start < 0:
            raise ValueError("process birth identity is invalid")
        return ProcessIdentity(pid, start, parts[0].decode("ascii"))

    def executable(self, pid: int) -> str:
        return os.readlink(f"/proc/{pid}/exe")

    def inspect(self) -> Result:
        if not self.available():
            return Result(
                "process", "UNKNOWN", "Process inspection requires Linux /proc"
            )
        try:
            pid, pid_file_identity = self.read_pid()
        except (OSError, ValueError):
            return Result("process", "UNKNOWN", "Cannot read a stable, valid PID file")

        try:
            before = self.identity(pid)
            executable = self.executable(pid)
            after = self.identity(pid)
            if before.start_ticks != after.start_ticks:
                result = Result(
                    "process", "UNKNOWN", "PID was reused during inspection"
                )
            elif after.state in {"Z", "X", "x"}:
                result = Result(
                    "process",
                    "CRIT",
                    "Expected process has exited",
                    source_at=timestamp(),
                )
            elif executable != os.path.realpath(self.expected_executable):
                result = Result(
                    "process",
                    "CRIT",
                    "PID file points to a different executable",
                    source_at=timestamp(),
                )
            else:
                result = Result(
                    "process",
                    "OK",
                    f"Expected executable is running (PID {pid})",
                    pid,
                    timestamp(),
                )
        except FileNotFoundError:
            result = Result(
                "process",
                "CRIT",
                "Expected process is not running",
                source_at=timestamp(),
            )
        except (OSError, ValueError, UnicodeError):
            result = Result(
                "process",
                "UNKNOWN",
                "Cannot inspect the process identity or executable",
            )

        try:
            if (pid, pid_file_identity) != self.read_pid():
                return Result(
                    "process", "UNKNOWN", "PID file changed during inspection"
                )
        except (OSError, ValueError):
            return Result(
                "process",
                "UNKNOWN",
                "PID file changed or became unreadable during inspection",
            )
        return result
