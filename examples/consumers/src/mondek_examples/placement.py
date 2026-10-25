# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""One installed project, two node observers and one shared-service observer.

Each deployment declares its runner identity and capabilities. Environments are
the monitored production/staging scopes, not places where Python must execute.
The shared observer checks both environments; each node checks its own disk.
The Compose demonstration measures each runner container's own root filesystem.
"""

from __future__ import annotations

import os
import shutil
import urllib.error
import urllib.request
from dataclasses import replace
from typing import Any

from mondek_runner import (
    App,
    Capability,
    Datasource,
    Environment,
    Parameter,
    Placement,
    Result,
    RunnerContext,
    Target,
    check,
)
from mondek_runner.api import timestamp

STAGING = Environment("staging", "Staging")
PRODUCTION = Environment("production", "Production")
RUNNERS = {
    "node-a": RunnerContext(
        "node-a",
        "Node A",
        capabilities=("local-files",),
        target=Target("node:node-a", "Node A", "host"),
        local_environment=PRODUCTION,
    ),
    "node-b": RunnerContext(
        "node-b",
        "Node B",
        capabilities=("local-files",),
        target=Target("node:node-b", "Node B", "host"),
        local_environment=PRODUCTION,
    ),
    "shared-services": RunnerContext(
        "shared-services", "Shared observer", capabilities=("service-query",)
    ),
}


class LocalFilesystem(Datasource):
    # Only deployments intended to inspect their own filesystem advertise this.
    placement = Placement(requires=("local-files",), locality="runner-target")

    def used_percent(self) -> float:
        usage = shutil.disk_usage("/")
        return usage.used / usage.total * 100


class SharedHTTP(Datasource):
    # Network reachability belongs to the observer; the service remains the
    # subject of its result. No HTTP client is constructed on either node.
    placement = Placement(
        requires=("service-query",),
        monitored_environments=("staging", "production"),
    )

    def __init__(self, url: str):
        self.url = url

    def status(self, environment: Environment) -> int:
        # These are two independent readiness endpoints on our owned fixture,
        # standing in for staging and production endpoints in a real project.
        path = {STAGING.id: "/ready", PRODUCTION.id: "/ready-secondary"}[environment.id]
        try:
            with urllib.request.urlopen(
                self.url.rstrip("/") + path, timeout=2
            ) as response:
                return response.status
        except urllib.error.HTTPError as error:
            # An HTTP failure is a measured service verdict. A connection error
            # below is loss of visibility, rather than a made-up service status.
            error.close()
            return error.code


@check(
    id="root-disk",
    name="Root filesystem capacity",
    expected_keys=("capacity",),
    params={"warn_percent": 90, "crit_percent": 95},
    parameters={
        "warn_percent": Parameter("number", "Warning at", "% used", 0, 100),
        "crit_percent": Parameter("number", "Critical at", "% used", 0, 100),
    },
    comparisons=(("warn_percent", "lt", "crit_percent"),),
    interval_seconds=5,
    timeout_seconds=3,
    freshness_seconds=20,
)
def root_disk(filesystem: LocalFilesystem, params: dict[str, Any]) -> Result:
    try:
        used = filesystem.used_percent()
    except OSError:
        return Result("capacity", "UNKNOWN", "Cannot inspect the root filesystem")
    health = (
        "CRIT"
        if used >= params["crit_percent"]
        else "WARN"
        if used >= params["warn_percent"]
        else "OK"
    )
    return Result(
        "capacity",
        health,
        f"Root filesystem is {used:.1f}% used",
        used,
        timestamp(),
        details="Measured the root filesystem visible to this runner process.",
    )


@check(
    id="service-readiness",
    name="Shared service readiness",
    expected_keys=("readiness",),
    environments=(STAGING, PRODUCTION),
    interval_seconds=5,
    timeout_seconds=3,
    freshness_seconds=20,
)
def service_readiness(source: SharedHTTP, environment: Environment) -> Result:
    try:
        status = source.status(environment)
    except OSError:
        return Result("readiness", "UNKNOWN", "Cannot reach the local service")
    return Result(
        "readiness",
        "OK" if status == 200 else "CRIT",
        f"{environment.name} service returned HTTP {status}",
        status,
        timestamp(),
    )


def make_app(
    runner_id: str,
    http_url: str | None = None,
    http_environments: tuple[str, ...] = ("staging", "production"),
) -> App:
    """Use the same declarations in every deployment, with explicit local inputs."""
    if runner_id not in RUNNERS:
        raise ValueError("runner context must be node-a, node-b or shared-services")
    application = App(
        source_id="execution-placement",
        name="Shared project across node and service observers",
        environment=None if runner_id == "shared-services" else PRODUCTION,
        runner=replace(
            RUNNERS[runner_id],
            capabilities=(Capability("service-query", http_environments),),
        )
        if runner_id == "shared-services"
        else RUNNERS[runner_id],
        construction_environment={
            "MONDEK_RUNNER_CONTEXT": runner_id,
            "MONDEK_PLACEMENT_HTTP_URL": http_url,
            "MONDEK_PLACEMENT_HTTP_ENVIRONMENTS": ",".join(http_environments),
        },
        checks=[root_disk, service_readiness],
    )
    application.register_datasource(LocalFilesystem)
    if http_url is not None:
        application.register_datasource(SharedHTTP, url=http_url)
    return application


app = make_app(
    os.environ.get("MONDEK_RUNNER_CONTEXT", "node-a"),
    os.environ.get("MONDEK_PLACEMENT_HTTP_URL"),
    tuple(
        os.environ.get(
            "MONDEK_PLACEMENT_HTTP_ENVIRONMENTS", "staging,production"
        ).split(",")
    ),
)
