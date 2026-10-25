# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""A complete check works using its defaults with no controller policy file."""

import shutil

from collections.abc import Iterator
from typing import Any

from mondek_runner import (
    App,
    Environment,
    Output,
    Parameter,
    Result,
    Target,
    check,
)
from mondek_runner.api import timestamp

from settings import DISK_CONTRACT, DISK_DEFAULTS, SOURCE_ID


@check(
    id="root-disk",
    name="Root disk usage",
    outputs=(
        Output(
            "capacity",
            "Root disk usage",
            Target("example-root", "Example root", "volume"),
        ),
    ),
    params=DISK_DEFAULTS,
    parameters={
        "path": Parameter("string", "Filesystem", choices=("/",)),
        "warn_percent": Parameter("number", "Warning at", "% used", 0, 100),
        "crit_percent": Parameter("number", "Critical at", "% used", 0, 100),
    },
    comparisons=(("warn_percent", "lt", "crit_percent"),),
    parameter_contract=DISK_CONTRACT,
)
def root_disk(*, params: dict[str, Any]) -> Iterator[Result]:
    usage = shutil.disk_usage(params["path"])
    percent = usage.used / usage.total * 100
    health = (
        "CRIT"
        if percent >= params["crit_percent"]
        else "WARN"
        if percent >= params["warn_percent"]
        else "OK"
    )
    yield Result(
        "capacity", health, f"Root filesystem {percent:.1f}% used", percent, timestamp()
    )


app = App(
    source_id=SOURCE_ID,
    environment=Environment("production", "Production"),
    checks=[root_disk],
)
