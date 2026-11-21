# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Discover a bounded node roster and measure each node independently."""

import json
import os
import re
from pathlib import Path

from mondek_runner import App, Binding, Environment, Target, check, crit, ok, unknown
from mondek_runner.catalogs import DiscoveryCatalog

MAX_NODES = 32
MAX_ROSTER_BYTES = 4096
NODE_KEY = re.compile(r"[a-z0-9][a-z0-9-]{0,47}")


def make_app(directory: Path) -> App:
    @check(id="node-catalog", expected_keys=("health",))
    def manager():
        return ok("health", "Node roster discovery is configured")

    def discover(_params):
        with (directory / "nodes.json").open("rb") as roster:
            content = roster.read(MAX_ROSTER_BYTES + 1)
        if len(content) > MAX_ROSTER_BYTES:
            raise ValueError("node roster exceeds 4096 bytes")
        nodes = json.loads(content)
        if not isinstance(nodes, list) or len(nodes) > MAX_NODES:
            raise ValueError("node roster must contain at most 32 nodes")
        if any(
            not isinstance(node, str) or not NODE_KEY.fullmatch(node) for node in nodes
        ):
            raise ValueError("node roster has an invalid key")
        if len(set(nodes)) != len(nodes):
            raise ValueError("node roster has duplicate keys")
        return {node: {} for node in nodes}

    def bind(node, _descriptor, present):
        @check(
            id="node-health",
            expected_keys=("health",),
            interval_seconds=3,
            timeout_seconds=3,
            freshness_seconds=20,
        )
        def measure():
            if not present:
                return unknown("health", "Node missing from the latest complete roster")
            try:
                with (directory / f"{node}.status").open("rb") as evidence:
                    status = evidence.read(16)
            except OSError:
                return unknown("health", "Cannot read node health")
            if status == b"up\n":
                return ok("health", "Node is up")
            if status == b"down\n":
                return crit("health", "Node is down")
            return unknown("health", "Invalid node health input")

        return Binding(
            measure,
            key=f"node.{node}",
            name=f"Health of {node}",
            target=Target(f"node:{node}", node, "host"),
        )

    manager.mondek_discovery = DiscoveryCatalog(
        discover, bind, interval_seconds=1, grace_seconds=8
    )
    return App(
        source_id="node-catalog",
        environment=Environment("catalog-demo"),
        construction_environment={"MONDEK_NODE_CATALOG_DIR": str(directory)},
        checks=[manager],
    )


app = make_app(Path(os.environ.get("MONDEK_NODE_CATALOG_DIR", "/catalog")))
