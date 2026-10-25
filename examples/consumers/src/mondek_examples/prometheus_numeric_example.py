# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""An ordinary queue-depth gauge with delegated thresholds and fixed targets."""

import os

from mondek_runner import Environment, Target

from .prometheus_numeric import make_numeric_app

construction = {"MONDEK_PROMETHEUS_URL": os.environ.get("MONDEK_PROMETHEUS_URL")}

app = make_numeric_app(
    source_id="numeric-threshold-example",
    name="Numeric queue monitoring",
    environment=Environment("local-monitoring", "Local monitoring"),
    construction_environment=construction,
    url=construction["MONDEK_PROMETHEUS_URL"] or "http://prometheus:9090",
    query="mondek_fixture_queue_depth[30s]",
    identity_label="service",
    targets={"primary": Target("queue:primary", "Primary queue", "queue")},
    unit="items",
    direction="above",
    warning=5,
    critical=10,
    minimum=0,
    maximum=1_000_000,
    check_id="queue-depth",
    check_name="Primary queue depth",
    interval_seconds=5,
    timeout_seconds=3,
    freshness_seconds=20,
)
