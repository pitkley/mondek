# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""A deployment-configured consumer of ordinary Prometheus scrape health."""

import os

from mondek_examples.prometheus import app_from_settings

app = app_from_settings(
    os.environ.get("MONDEK_PROMETHEUS_SETTINGS", ""),
    construction_environment={
        "MONDEK_PROMETHEUS_SETTINGS": os.environ.get("MONDEK_PROMETHEUS_SETTINGS")
    },
)
