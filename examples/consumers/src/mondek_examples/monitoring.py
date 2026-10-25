# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""The original dedicated-runner demo, using the reusable Prometheus consumer."""

import os

from mondek_runner import Environment, Target

from mondek_examples.prometheus import (
    DEFAULT_QUERY,
    Prometheus as Prometheus,
    make_app as make_app,
    make_check as make_check,
)

app = make_app(
    source_id="monitoring-services",
    name="Dedicated monitoring checks",
    environment=Environment("local-demo", "Local demonstration"),
    url=os.environ.get("PROMETHEUS_URL", "http://prometheus:9090"),
    query=DEFAULT_QUERY,
    identity_label="service",
    targets={
        "primary": Target("service:primary", "Primary service", "service"),
        "secondary": Target("service:secondary", "Secondary service", "service"),
    },
    result_keys={"primary": "primary", "secondary": "secondary"},
    result_labels={
        "primary": "Primary service readiness",
        "secondary": "Secondary service readiness",
    },
)
service_readiness = app.bindings["service-readiness"].function
