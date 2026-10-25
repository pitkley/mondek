# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""One project on two observers: native Linux evidence and a controlled fixture."""

import os

from mondek_runner import App, Environment, RunnerContext, Target
from mondek_runner.packs.linux import Interface, LinuxHost, Selection, linux_checks

PRODUCTION = Environment("linux-example", "Linux example")
NATIVE = Target("host:linux-native", "Linux native")
FIXTURE = Target("host:linux-fixture", "Linux fixture")
context = os.environ.get("MONDEK_LINUX_CONTEXT", "native")
if context not in {"native", "fixture"}:
    raise ValueError("MONDEK_LINUX_CONTEXT must be native or fixture")

app = App(
    source_id="linux-pack-example",
    runner=RunnerContext(
        context,
        capabilities=("linux-host",),
        target=NATIVE if context == "native" else FIXTURE,
        local_environment=PRODUCTION,
    ),
    checks=[
        *linux_checks(
            LinuxHost(
                NATIVE,
                PRODUCTION,
                interfaces=(Interface("lo", ("unknown", "up")),),
                interval_seconds=3,
                freshness_seconds=30,
            )
        ),
        *linux_checks(
            LinuxHost(
                FIXTURE,
                PRODUCTION,
                root="/linux-fixture",
                interfaces=(Interface("eth0"),),
                discover=True,
                interface_selection=Selection(exclude=("lo", "veth*")),
                disappearance_grace_seconds=9,
                interval_seconds=3,
                freshness_seconds=30,
            )
        ),
    ],
    construction_environment={"MONDEK_LINUX_CONTEXT": context},
)
