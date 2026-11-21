# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Measure the isolated target's readiness using per-output sustain."""

from urllib.error import HTTPError
from urllib.request import urlopen

from mondek_runner import App, Environment, Output, Target, check, crit, ok


@check(
    id="sustained-link",
    outputs=(
        Output(
            "link",
            "Fixture link",
            Target("link", "Fixture link", "service"),
            sustain_seconds=30,
        ),
    ),
    interval_seconds=2,
    timeout_seconds=3,
    freshness_seconds=60,
)
def link():
    try:
        with urlopen("http://target:8080/ready", timeout=1) as response:
            response.read(256)
    except HTTPError as error:
        if error.code != 503:
            raise
        error.close()
        return crit("link", "Fixture link unavailable")
    return ok("link", "Fixture link available")


app = App(source_id="output-sustain", environment=Environment("test"), checks=[link])
