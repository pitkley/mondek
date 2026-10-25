# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""The original demo checks, now explicitly owned and registered by a consumer."""

import os

from mondek_runner import App, Binding, Environment, Parameter, Target, check
from .collectors import filesystem, http

from .backlog import BacklogDatasource, backlog


@check(
    id="filesystem",
    name="Runner filesystem",
    expected_keys=("capacity",),
    params={"path": "/", "warn_percent": 80, "crit_percent": 90},
    parameters={
        "path": Parameter("string", "Runner filesystem path", choices=("/",)),
        "warn_percent": Parameter(
            "number", "Warning", unit="% used", minimum=0, maximum=100
        ),
        "crit_percent": Parameter(
            "number", "Critical", unit="% used", minimum=0, maximum=100
        ),
    },
    comparisons=(("warn_percent", "lt", "crit_percent"),),
    interval_seconds=3,
    timeout_seconds=2,
    freshness_seconds=12,
)
def disk(*, params: dict):
    yield from filesystem(params=params)


TARGET = os.environ.get("MONDEK_DEMO_TARGET_URL", "http://target:8080")


@check(
    id="http",
    name="Local HTTP readiness",
    expected_keys=("readiness",),
    params={"url": TARGET + "/ready"},
    parameters={
        "url": Parameter("string", "Readiness URL", choices=(TARGET + "/ready",))
    },
    interval_seconds=3,
    timeout_seconds=2,
    freshness_seconds=12,
)
def readiness(*, params: dict):
    return http(params=params)


@check(
    id="consumer",
    name="Python consumer backlog",
    expected_keys=("backlog",),
    params={"url": TARGET + "/data", "warn_count": 5, "crit_count": 10},
    parameters={
        "url": Parameter("string", "Backlog URL", choices=(TARGET + "/data",)),
        "warn_count": Parameter(
            "integer", "Warning", unit="items", minimum=0, maximum=1000000
        ),
        "crit_count": Parameter(
            "integer", "Critical", unit="items", minimum=0, maximum=1000000
        ),
    },
    comparisons=(("warn_count", "lt", "crit_count"),),
    interval_seconds=3,
    timeout_seconds=2,
    freshness_seconds=12,
)
async def consumer(datasource: BacklogDatasource, *, params: dict):
    return await backlog(params=params, datasource=datasource)


app = App(
    source_id="mondek-demo",
    construction_environment={
        "MONDEK_DEMO_TARGET_URL": os.environ.get("MONDEK_DEMO_TARGET_URL")
    },
    environment=Environment("demo-runner", "Demo runner"),
    checks=[
        Binding(
            disk,
            target=Target("demo-runner-root", "Demo runner root filesystem"),
        ),
        Binding(
            readiness,
            target=Target("demo-readiness", "Local readiness service", "service"),
        ),
        Binding(
            consumer,
            target=Target("demo-backlog", "Local backlog service", "service"),
        ),
    ],
)
app.register_datasource(BacklogDatasource, url=TARGET + "/data")
