# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""An ordinary consumer executed by each independently journalled fleet runner."""

from __future__ import annotations

import json
import os
import urllib.request

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


@check(
    id="node-signal",
    name="Node signal",
    expected_keys=("signal",),
    interval_seconds=30,
    timeout_seconds=5,
    freshness_seconds=100,
)
def node_signal() -> Result:
    index = int(os.environ["MONDEK_FLEET_INDEX"])
    with urllib.request.urlopen(
        f"http://127.0.0.1:8082/samples/{index}", timeout=2
    ) as response:
        value = json.loads(response.read(4096))
    return Result(
        "signal",
        value["health"],
        f"Node {index:03d} reports {value['health']}",
        index,
        value["source_at"],
        details="Measured independently by an isolated Python worker through the local HTTP datasource.",
    )


INDEX = int(os.environ["MONDEK_FLEET_INDEX"])
if not 1 <= INDEX <= 50:
    raise ValueError("fixture fleet index must be 1–50")
TARGET = Target(f"fleet-node-{INDEX:03d}", f"Fleet node {INDEX:03d}", "host")
ENVIRONMENT = Environment("fleet-production" if INDEX % 2 else "fleet-staging")
app = App(
    source_id="browser-fleet-checks",
    name="Real fleet browser consumer",
    environment=ENVIRONMENT,
    runner=RunnerContext(
        f"fleet-observer-{INDEX:03d}",
        "Shared observer" if INDEX in {11, 12} else f"Fleet observer {INDEX:03d}",
    ),
    construction_environment={"MONDEK_FLEET_INDEX": str(INDEX)},
    checks=[Binding(node_signal, outputs=(Output("signal", "Node signal", TARGET),))],
)
