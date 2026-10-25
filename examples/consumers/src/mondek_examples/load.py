# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Bounded real filesystem evaluations for inventory and execution capacity tests."""

from __future__ import annotations

import os
from collections.abc import Iterator
from pathlib import Path

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

COUNT = int(os.environ.get("MONDEK_LOAD_CHECKS", "500"))
GROUP_SIZE = int(os.environ.get("MONDEK_LOAD_GROUP_SIZE", "10"))
INTERVAL = int(os.environ.get("MONDEK_LOAD_INTERVAL", "60"))
if not 1 <= COUNT <= 512 or not 1 <= GROUP_SIZE <= 16 or not 5 <= INTERVAL <= 3600:
    raise ValueError(
        "load requires 1–512 results, groups of 1–16 and interval of 5–3600 seconds"
    )


class ExportDirectory(Datasource):
    def __init__(self, directory: str):
        self.directory = Path(directory)


def make_group(
    start: int,
    stop: int,
    *,
    delegated: bool = False,
    interval_seconds: int = INTERVAL,
) -> Binding:
    keys = tuple(f"export-{index:04d}" for index in range(start, stop))
    defaults = {"critical_min_bytes": 1, "warn_min_bytes": 13} if delegated else {}

    @check(
        id=f"export-group-{start:04d}",
        name=(
            f"Export file export-{start:04d}.txt"
            if stop == start + 1
            else f"Export files {start:04d}–{stop - 1:04d}"
        ),
        expected_keys=keys,
        params=defaults,
        parameters={
            "critical_min_bytes": Parameter(
                "integer", "Critical below", "bytes", 0, 32
            ),
            "warn_min_bytes": Parameter("integer", "Warning below", "bytes", 0, 32),
        }
        if delegated
        else {},
        comparisons=(("critical_min_bytes", "lte", "warn_min_bytes"),)
        if delegated
        else (),
        parameter_contract="export.minimum-bytes.v1" if delegated else None,
        interval_seconds=interval_seconds,
        timeout_seconds=5,
        freshness_seconds=interval_seconds * 3,
    )
    def exports(
        files: ExportDirectory, params: dict[str, int] | None = None
    ) -> Iterator[Result]:
        thresholds = defaults if params is None else params
        for key in keys:
            path = files.directory / f"{key}.txt"
            try:
                # Real independently evaluated files, not precomputed UI rows.
                with path.open("rb") as file:
                    value = file.read(33)
                valid = value == b"valid export\n"
                health = "OK" if valid else "CRIT"
                summary = (
                    "Export contents are valid"
                    if valid
                    else "Export contents are invalid"
                )
                if valid and delegated:
                    size = len(value)
                    if size < thresholds["critical_min_bytes"]:
                        health = "CRIT"
                        summary = (
                            f"Export is {size} bytes; below critical minimum "
                            f"{thresholds['critical_min_bytes']} bytes"
                        )
                    elif size < thresholds["warn_min_bytes"]:
                        health = "WARN"
                        summary = (
                            f"Export is {size} bytes; below warning minimum "
                            f"{thresholds['warn_min_bytes']} bytes"
                        )
                    else:
                        summary = f"Export contents are valid; {size} bytes meets both minimums"
                yield Result(
                    key,
                    health,
                    summary,
                    len(value),
                    timestamp(),
                )
            except FileNotFoundError:
                yield Result(
                    key, "CRIT", "Required export is missing", None, timestamp()
                )
            except OSError as error:
                yield Result(key, "UNKNOWN", f"Cannot inspect export: {error}")

    return Binding(
        exports,
        outputs=tuple(
            Output(
                key,
                f"Export {index:04d}",
                Target(f"load:{key}", f"exports/{key}.txt", "file"),
            )
            for index, key in enumerate(keys, start)
        ),
    )


app = App(
    source_id="export-capacity",
    name="Export inventory capacity",
    environment=Environment("capacity-test", "Capacity test"),
    checks=[
        make_group(start, min(COUNT, start + GROUP_SIZE))
        for start in range(0, COUNT, GROUP_SIZE)
    ],
)
app.register_datasource(
    ExportDirectory, directory=os.environ.get("MONDEK_LOAD_DIRECTORY", "/samples")
)
