# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""An installed consumer discovers actual local directories for source review.

Directories stand in for logical data volumes in this deliberately small example.
This does not infer mount health or invent a general filesystem inventory policy.
"""

import hashlib
import os
from pathlib import Path

from mondek_runner import (
    App,
    Datasource,
    Discovery,
    DiscoveryCandidate,
    DiscoveryChoice,
    Environment,
    Output,
    Parameter,
    Result,
    RunnerContext,
    Target,
    check,
    ok,
    warn,
)


class LocalDirectories(Datasource):
    def __init__(self, directory: str):
        self.directory = Path(directory)

    def observe(self) -> list[Path]:
        entries = []
        with os.scandir(self.directory) as iterator:
            for entry in iterator:
                if len(entries) >= 1000:
                    raise ValueError(
                        "Directory discovery exceeds 1000 inspected entries"
                    )
                entries.append(entry)
        return sorted(
            (
                Path(entry.path)
                for entry in entries
                if entry.is_dir(follow_symlinks=False)
            ),
            key=lambda path: path.name,
        )


@check(
    id="directory-discovery",
    name="Discovered data directories",
    outputs=(Output("inventory", "Directory inventory", Target("node-a", "Node A")),),
    interval_seconds=2,
    timeout_seconds=2,
    freshness_seconds=8,
)
def directories(source: LocalDirectories) -> Result:
    observed = source.observe()
    candidates = tuple(
        DiscoveryCandidate(
            hashlib.sha256(os.fsencode(path.name)).hexdigest(),
            ascii(path.name)[1:-1][:150],
            "Observed directory: " + ascii(path.name)[:700],
        )
        for path in observed[:20]
    )
    review = Discovery(
        "Review discovered directories",
        "Add reviewed directory bindings and exclusion declarations in discovery_demo.py. "
        "Review the diff and do not deploy automatically.",
        choices=(
            DiscoveryChoice(
                "monitor",
                "Monitor capacity",
                parameters={
                    "limit": Parameter(
                        "integer", "Critical percent", minimum=1, maximum=100
                    ),
                },
                params={"limit": 90},
            ),
            DiscoveryChoice(
                "ignore", "Ignore", description="Exclude from expected directories."
            ),
        ),
        candidates=candidates,
        omitted=max(0, len(observed) - len(candidates)),
    )
    emit = warn if observed else ok
    return emit(
        "inventory",
        f"{len(observed)} directories need review",
        details=(
            "Directories requiring source review:\n"
            + (
                "\n".join("- " + ascii(path.name)[:700] for path in observed[:20])
                or "none"
            )
            + (
                f"\n{len(observed) - 20} additional directories omitted."
                if len(observed) > 20
                else ""
            )
            + "\nDirectory existence does not establish filesystem capacity or health."
        ),
        discovery=review,
    )


app = App(
    source_id="discovery-example",
    name="Filesystem discovery example",
    environment=Environment("local", "Local"),
    runner=RunnerContext("directory-observer", "Directory observer"),
    checks=[directories],
)
app.register_datasource(
    LocalDirectories,
    directory=os.environ.get(
        "MONDEK_DISCOVERY_DIRECTORY", "/discovery-fixture/volumes"
    ),
)
