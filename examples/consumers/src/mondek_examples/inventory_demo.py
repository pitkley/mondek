# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Two independent observers measuring one target through an owned HTTP fixture."""

from __future__ import annotations

import json
import os
import urllib.request
from collections.abc import Iterator

from mondek_runner import (
    App,
    Binding,
    Datasource,
    Environment,
    Output,
    Result,
    RunnerContext,
    Target,
    check,
)
from mondek_runner.api import timestamp

HOST = Target("host:inventory-shared", "Shared inventory host", "host")
SERVICE = Target("service:inventory-fixture", "Fixture service", "service")
ENVIRONMENT = Environment("inventory-test", "Inventory test")


class FixtureData(Datasource):
    def __init__(self, url: str):
        self.url = url.rstrip("/")

    def backlog(self) -> tuple[int, str]:
        with urllib.request.urlopen(self.url + "/data", timeout=2) as response:
            data = json.loads(response.read(4097))
        value = data["backlog"]
        if type(value) is not int or not 0 <= value <= 10000:
            raise ValueError("fixture backlog must be an integer in 0..10000")
        return value, timestamp()


def make_batch(start: int) -> Binding:
    keys = tuple(f"signal-{index:03d}" for index in range(start, start + 15))

    @check(
        id=f"signals-{start:03d}",
        name=f"Host signals {start:03d}–{start + 14:03d}",
        expected_keys=keys,
        interval_seconds=3,
        timeout_seconds=5,
        freshness_seconds=12,
    )
    def signals(source: FixtureData) -> Iterator[Result]:
        value, measured_at = source.backlog()
        for key in keys:
            # The final alphabetical result deliberately becomes the problem,
            # proving that the UI orders actual measured severity before name.
            threshold = 10 if key == "signal-059" else 1000
            yield Result(
                key,
                "CRIT" if value >= threshold else "OK",
                f"Observed backlog {value}; critical at {threshold}",
                value,
                measured_at,
            )

    return Binding(
        signals,
        outputs=tuple(Output(key, f"Host signal {key[-3:]}", HOST) for key in keys),
    )


@check(
    id="fixture-service",
    name="Fixture service availability",
    expected_keys=("availability",),
    interval_seconds=3,
    timeout_seconds=5,
    freshness_seconds=12,
)
def fixture_service(source: FixtureData) -> Result:
    value, measured_at = source.backlog()
    return Result(
        "availability", "OK", "Fixture datasource responded", value, measured_at
    )


def make_app(observer: str, url: str) -> App:
    if observer not in ("a", "b"):
        raise ValueError("inventory observer must be a or b")
    application = App(
        source_id="inventory-demo",
        name="Shared target inventory example",
        environment=ENVIRONMENT,
        runner=RunnerContext(
            f"inventory-{observer}", f"Inventory observer {observer.upper()}"
        ),
        construction_environment={
            "MONDEK_INVENTORY_OBSERVER": observer,
            "MONDEK_INVENTORY_FIXTURE_URL": url,
        },
        checks=[
            *(make_batch(start) for start in range(0, 60, 15)),
            Binding(
                fixture_service,
                outputs=(Output("availability", "Fixture availability", SERVICE),),
            ),
        ],
    )
    application.register_datasource(FixtureData, url=url)
    return application


app = make_app(
    os.environ.get("MONDEK_INVENTORY_OBSERVER", "a"),
    os.environ.get("MONDEK_INVENTORY_FIXTURE_URL", "http://target:8080"),
)
