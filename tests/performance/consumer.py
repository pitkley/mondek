# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Owned local-file measurement, or an intentionally empty idle inventory."""

import os
from datetime import UTC, datetime
from pathlib import Path

from mondek_runner import (
    App,
    Binding,
    Environment,
    Output,
    Result,
    RunnerContext,
    Target,
    check,
)

mode = os.environ.get("MONDEK_PROFILE_MODE", "idle")
index = int(os.environ.get("MONDEK_PROFILE_INDEX", "1"))
if mode not in {"idle", "active"} or not 1 <= index <= 12:
    raise ValueError("profile mode must be idle/active and index must be 1..12")


@check(
    id="owned-sample",
    name="Read owned sample",
    expected_keys=("sample",),
    interval_seconds=30,
    timeout_seconds=5,
    freshness_seconds=100,
)
def sample_file() -> Result:
    content = Path("/app/sample.txt").read_bytes()
    return Result(
        "sample",
        "OK" if content == b"profile sample\n" else "CRIT",
        f"Read {len(content)} bytes from owned sample",
        len(content),
        source_at=datetime.now(UTC)
        .isoformat(timespec="microseconds")
        .replace("+00:00", "Z"),
    )


app = App(
    source_id="profiling-checks",
    environment=Environment("profiling", "Isolated profiling"),
    runner=RunnerContext(f"profile-{index}", f"Profiling runner {index}"),
    construction_environment={
        "MONDEK_PROFILE_MODE": mode,
        "MONDEK_PROFILE_INDEX": str(index),
    },
    checks=[]
    if mode == "idle"
    else [
        Binding(
            sample_file,
            outputs=(
                Output(
                    "sample",
                    "Owned sample read",
                    Target(f"node-{index}", f"Profile node {index}", "host"),
                ),
            ),
        )
    ],
)
