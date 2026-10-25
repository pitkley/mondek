# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Real observations of many resources organized independently of their identity."""

from __future__ import annotations

import os
from collections.abc import Iterator

from mondek_runner import (
    App,
    Binding,
    CheckGroup,
    Environment,
    Output,
    Result,
    RunnerContext,
    Target,
    check,
)

from .inventory_demo import FixtureData


def make_app(observer: str, phase: str, url: str) -> App:
    if observer not in ("a", "b") or phase not in ("initial", "renamed"):
        raise ValueError("unknown observer or publication phase")
    node = CheckGroup("node", "Node services" if phase == "renamed" else "Node")
    misc = CheckGroup("misc", "Miscellaneous")
    outputs = [
        Output(
            f"container-{index:03d}",
            f"Container {index:03d}",
            Target(f"container:{index:03d}", f"Container {index:03d}", "container"),
            group=node,
        )
        for index in range(15)
    ]
    if observer == "a":
        outputs.extend(
            Output(
                f"deadline-{index:03d}",
                f"Deadline {index:03d}",
                Target(f"deadline:{index:03d}", f"Deadline {index:03d}", "deadline"),
                group=node if phase == "renamed" and index == 0 else misc,
            )
            for index in range(5)
        )
        outputs.extend(
            Output(
                f"resource-{index:03d}",
                f"Resource {index:03d}",
                Target(f"resource:{index:03d}", f"Resource {index:03d}", "service"),
                group=CheckGroup(f"site-{index:03d}", f"Site {index:03d}"),
            )
            for index in range(105)
        )

    def batch(start: int) -> Binding:
        members = tuple(outputs[start : start + 15])

        @check(
            id=f"group-signals-{start:03d}",
            name=f"Grouped signals {start:03d}",
            expected_keys=tuple(member.key for member in members),
            interval_seconds=10,
            timeout_seconds=5,
            freshness_seconds=90,
        )
        def signals(source: FixtureData) -> Iterator[Result]:
            value, measured_at = source.backlog()
            for member in members:
                failing = member.key == "container-000" and value >= 10
                yield Result(
                    member.key,
                    "CRIT" if failing else "OK",
                    f"Measured fixture backlog {value}",
                    value,
                    measured_at,
                )

        return Binding(signals, outputs=members)

    application = App(
        source_id="check-groups-demo",
        name="Check groups example",
        environment=Environment("groups-test", "Groups test"),
        runner=RunnerContext(
            f"groups-{observer}", f"Groups observer {observer.upper()}"
        ),
        construction_environment={
            "MONDEK_GROUPS_OBSERVER": observer,
            "MONDEK_GROUPS_PHASE": phase,
            "MONDEK_GROUPS_FIXTURE_URL": url,
        },
        checks=[batch(start) for start in range(0, len(outputs), 15)],
    )
    application.register_datasource(FixtureData, url=url)
    return application


app = make_app(
    os.environ.get("MONDEK_GROUPS_OBSERVER", "a"),
    os.environ.get("MONDEK_GROUPS_PHASE", "initial"),
    os.environ.get("MONDEK_GROUPS_FIXTURE_URL", "http://target:8080"),
)
