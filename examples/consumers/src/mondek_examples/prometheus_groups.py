# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Compose separately scheduled Prometheus queries with explicit result membership."""

from __future__ import annotations

from collections.abc import Iterable, Mapping
from dataclasses import dataclass
from typing import Annotated, Any

from mondek_runner import App, DatasourceFactory, Environment, FromFactory, Target

from .prometheus import Prometheus, make_check, validate_collection


@dataclass(frozen=True)
class CollectionGroup:
    """A stable scheduled check and its private query-to-target mapping."""

    id: str
    name: str
    url: str
    query: str
    identity_label: str
    targets: Mapping[str, Target]
    measurement: str = "readiness"


class PrometheusGroups(DatasourceFactory):
    def __init__(self, groups: dict[str, dict[str, Any]]):
        self.groups = groups

    def new(self, group: str) -> Prometheus:
        return Prometheus(**self.groups[group])


def make_grouped_app(
    *,
    source_id: str,
    environment: Environment,
    groups: Iterable[CollectionGroup],
    name: str = "Prometheus query groups",
    construction_environment: Mapping[str, str | None] | None = None,
) -> App:
    """Use stable source-defined groups; discovery never queries Prometheus."""
    consumer = App(
        source_id=source_id,
        name=name,
        environment=environment,
        construction_environment=construction_environment,
    )
    settings = {}
    for group in groups:
        if not isinstance(group, CollectionGroup):
            raise ValueError("Prometheus groups require CollectionGroup declarations")
        validate_collection(
            group.url, group.query, group.identity_label, group.measurement
        )
        function = make_check(
            targets=group.targets, check_id=group.id, check_name=group.name
        )
        # Each function selects its own private datasource through the SDK's
        # ordinary factory binding. A single type-wide provider would otherwise
        # make the final registration replace every earlier query.
        function.__annotations__["prometheus"] = Annotated[
            Prometheus, FromFactory(PrometheusGroups, group.id)
        ]
        consumer.add(function)
        settings[group.id] = {
            "url": group.url,
            "query": group.query,
            "identity_label": group.identity_label,
            "measurement": group.measurement,
            "expected_series": {
                target.key: series for series, target in group.targets.items()
            },
        }
    if not settings:
        raise ValueError("Prometheus requires at least one explicit collection group")
    consumer.register_datasource_factory(PrometheusGroups, groups=settings)
    return consumer
