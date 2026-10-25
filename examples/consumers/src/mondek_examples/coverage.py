# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Declare a node roster and service scopes before choosing where checks run.

Every deployment publishes the same explicit Node A/Node B roster and both
service environments. Only a matching node can execute its local binding;
service observers need an environment-scoped capability. The inherited local
collection check deliberately remains unbound on a subject-less service runner.
Measurements come from the owned fixture, with independent observer/sample IDs.
"""

from __future__ import annotations

import http.client
import os

from mondek_runner import (
    App,
    Binding,
    Capability,
    Datasource,
    Environment,
    Placement,
    Result,
    RunnerContext,
    Target,
    check,
)

from mondek_examples.grouped import FixtureData, Sample

STAGING = Environment("staging", "Staging")
PRODUCTION = Environment("production", "Production")
ROSTER = {
    "node-a": Target("node:node-a", "Node A", "host"),
    "node-b": Target("node:node-b", "Node B", "host"),
}
SERVICE = Target("service:search", "Search service", "service")


class LocalSample(FixtureData):
    placement = Placement(requires=("local-files",), locality="runner-target")


class ServiceSample(Datasource):
    placement = Placement(requires=("service-query",))

    def __init__(self, observer: str, url: str):
        self.observer = observer
        self.url = url

    def read(self, environment: Environment) -> Sample:
        return FixtureData(
            f"coverage-{self.observer}-{environment.id}", "elasticsearch", self.url
        ).read()


def capacity(sample: Sample, subject: str) -> Result:
    if not sample.available:
        return Result(
            "capacity",
            "UNKNOWN",
            f"{subject} collection is unavailable",
            source_at=sample.source_at,
        )
    health = (
        "CRIT"
        if sample.used_percent >= 95
        else "WARN"
        if sample.used_percent >= 90
        else "OK"
    )
    return Result(
        "capacity",
        health,
        f"{subject} is {sample.used_percent:g}% used",
        sample.used_percent,
        sample.source_at,
        details="This observer collected an independent measurement from the owned local fixture.",
    )


@check(
    id="root-disk",
    name="Root filesystem capacity",
    expected_keys=("capacity",),
    interval_seconds=3,
    timeout_seconds=5,
    freshness_seconds=12,
)
def root_disk(source: LocalSample, runner: RunnerContext) -> Result:
    try:
        return capacity(source.read(), (runner.name or runner.id) + " root filesystem")
    except (OSError, http.client.HTTPException, UnicodeError, ValueError):
        return Result(
            "capacity", "UNKNOWN", "Cannot collect a local filesystem measurement"
        )


@check(
    id="local-collection",
    name="Node-local collection availability",
    expected_keys=("collection",),
    interval_seconds=3,
    timeout_seconds=5,
    freshness_seconds=12,
)
def local_collection(source: LocalSample) -> Result:
    try:
        sample = source.read()
    except (OSError, http.client.HTTPException, UnicodeError, ValueError):
        return Result(
            "collection", "UNKNOWN", "Node-local collection cannot be reached"
        )
    return Result(
        "collection",
        "OK" if sample.available else "UNKNOWN",
        "Node-local collection is available"
        if sample.available
        else "Node-local collection is unavailable",
        source_at=sample.source_at,
    )


@check(
    id="service-capacity",
    name="Search service capacity",
    expected_keys=("capacity",),
    environments=(STAGING, PRODUCTION),
    interval_seconds=3,
    timeout_seconds=5,
    freshness_seconds=12,
)
def service_capacity(source: ServiceSample, environment: Environment) -> Result:
    try:
        return capacity(source.read(environment), environment.name + " search service")
    except (OSError, http.client.HTTPException, UnicodeError, ValueError):
        return Result(
            "capacity", "UNKNOWN", f"Cannot collect {environment.name} service capacity"
        )


def make_app(
    observer: str,
    url: str = "http://target:8080",
    access: tuple[str, ...] = ("staging",),
) -> App:
    if observer not in (*ROSTER, "service-a", "service-b"):
        raise ValueError(
            "coverage observer must be node-a, node-b, service-a or service-b"
        )
    if any(environment not in ("staging", "production") for environment in access):
        raise ValueError("coverage access must name staging or production")
    node = observer in ROSTER
    context = RunnerContext(
        observer,
        ROSTER[observer].label if node else f"Service observer {observer[-1].upper()}",
        capabilities=("local-files",)
        if node
        else (Capability("service-query", access),),
        target=ROSTER[observer] if node else None,
        local_environment=PRODUCTION if node else None,
    )
    application = App(
        source_id="declared-coverage",
        name="Explicit node roster and service scopes",
        environment=PRODUCTION if node else None,
        runner=context,
        construction_environment={
            "MONDEK_COVERAGE_OBSERVER": observer,
            "MONDEK_COVERAGE_FIXTURE_URL": url,
            "MONDEK_COVERAGE_ACCESS": ",".join(access),
        },
        checks=[
            *(
                Binding(
                    root_disk,
                    key=f"root-disk-{key}",
                    name=target.label + " root filesystem",
                    target=target,
                    environment=PRODUCTION,
                )
                for key, target in ROSTER.items()
            ),
            Binding(service_capacity, target=SERVICE),
            local_collection,
        ],
    )
    if node:
        application.register_datasource(
            LocalSample, observer=observer, kind="volume", url=url
        )
    else:
        application.register_datasource(ServiceSample, observer=observer, url=url)
    return application


app = make_app(
    os.environ.get("MONDEK_COVERAGE_OBSERVER", "node-a"),
    os.environ.get("MONDEK_COVERAGE_FIXTURE_URL", "http://target:8080"),
    tuple(os.environ.get("MONDEK_COVERAGE_ACCESS", "staging").split(",")),
)
