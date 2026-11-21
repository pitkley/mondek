# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""One independently scheduled measurement for the dependency rollout trial."""

from urllib.error import HTTPError
from urllib.request import urlopen

from mondek_runner import App, Environment, check, ok, unknown


@check(
    id="rollout-health",
    expected_keys=("health",),
    interval_seconds=1,
    timeout_seconds=3,
    freshness_seconds=5,
)
def health():
    try:
        with urlopen("http://target:8080/ready", timeout=1) as response:
            response.read(256)
    except HTTPError as error:
        if error.code != 503:
            raise
        error.close()
        return unknown(
            "health", "Local rollout fixture withheld the measurement", source_at=None
        )
    return ok("health", "Local rollout fixture measured")


app = App(
    source_id="dependency-rollout", environment=Environment("test"), checks=[health]
)
