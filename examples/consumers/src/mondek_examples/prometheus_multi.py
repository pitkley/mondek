# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Two queries against the local parity Prometheus, with independent meanings."""

import os

from mondek_runner import Environment, Target

from .prometheus_groups import CollectionGroup, make_grouped_app

construction = {"MONDEK_PROMETHEUS_URL": os.environ.get("MONDEK_PROMETHEUS_URL")}
url = construction["MONDEK_PROMETHEUS_URL"] or "http://prometheus:9090"

app = make_grouped_app(
    source_id="prometheus-groups-example",
    environment=Environment("local-monitoring", "Local monitoring"),
    construction_environment=construction,
    groups=(
        CollectionGroup(
            id="scrape-health",
            name="Prometheus scrape health",
            url=url,
            query='up{job="mondek-local-services"}[30s]',
            identity_label="instance",
            measurement="scrape",
            targets={
                "target:8080": Target(
                    "monitoring-target", "Local scrape target", "service"
                )
            },
        ),
        CollectionGroup(
            id="service-readiness",
            name="Application readiness",
            url=url,
            query="mondek_fixture_service_ready[30s]",
            identity_label="service",
            measurement="readiness",
            targets={
                "primary": Target("primary-service", "Primary service", "service"),
                "secondary": Target(
                    "secondary-service", "Secondary service", "service"
                ),
            },
        ),
    ),
)
