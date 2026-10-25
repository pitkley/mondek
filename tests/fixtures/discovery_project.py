# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Ordinary Linux pack project for the isolated configuration acceptance journey."""

import os
from mondek_runner import App, Environment, RunnerContext, Target
from mondek_runner.packs.linux import Interface, LinuxHost, Selection, linux_checks

observer = os.environ["MONDEK_DISCOVERY_OBSERVER"]
environment = Environment("lab", "Discovery lab")
target = Target(
    "host:a" if observer.startswith("a") else "host:b",
    "Host A" if observer.startswith("a") else "Host B",
)
app = App(
    source_id="discovery-configuration-example",
    runner=RunnerContext(
        observer,
        name="Observer " + observer,
        capabilities=("linux-host",),
        target=target,
        local_environment=environment,
    ),
    checks=[
        binding
        for host in ("a", "b")
        for binding in linux_checks(
            LinuxHost(
                Target("host:" + host, "Host " + host.upper()),
                environment,
                root="/linux-evidence/" + host,
                memory=False,
                cpu_load=False,
                filesystems=(),
                interfaces=(Interface("wlan0"),),
                discover=True,
                filesystem_selection=Selection(default_include=False),
                interval_seconds=float(
                    os.environ.get("MONDEK_DISCOVERY_INTERVAL", "1")
                ),
                freshness_seconds=30,
                disappearance_grace_seconds=3,
            )
        )
    ],
    construction_environment={
        "MONDEK_DISCOVERY_OBSERVER": observer,
        "MONDEK_DISCOVERY_INTERVAL": os.environ.get("MONDEK_DISCOVERY_INTERVAL"),
    },
)
