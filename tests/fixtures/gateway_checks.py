# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""One real local measurement per independent observer in gateway acceptance."""

import os
from datetime import UTC, datetime
from mondek_runner import App, Binding, Environment, Result, Target, check


@check(
    id="local",
    name="Local file measurement",
    expected_keys=("measurement",),
    interval_seconds=2,
    timeout_seconds=2,
    freshness_seconds=10,
)
def local():
    with open("/etc/hostname") as source:
        hostname = source.read().strip()
    return Result(
        "measurement",
        "OK",
        f"Read local hostname: {hostname}",
        source_at=datetime.now(UTC).isoformat(),
    )


observer = os.environ["GATEWAY_OBSERVER"]
app = App(
    source_id="gateway-acceptance",
    environment=Environment(observer, observer),
    checks=[Binding(local, target=Target("host:" + observer, observer, "host"))],
)
