# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Current Python registrations for worker and scheduler unit tests."""

from contextlib import contextmanager
from copy import deepcopy
from types import SimpleNamespace
from unittest.mock import patch

from demo_checks.app import app

IDS = {
    "filesystem": "10000000-0000-4000-8000-000000000001",
    "http": "10000000-0000-4000-8000-000000000002",
    "consumer": "10000000-0000-4000-8000-000000000003",
}
REVISION = "a" * 64


def assignment(kind="filesystem", generation=1, **overrides):
    key = next((key for key, value in IDS.items() if value == kind), kind)
    entry = next(row for row in app.metadata(REVISION) if row["key"] == key)
    return {
        **deepcopy(entry),
        "id": IDS[key],
        "kind": "python",
        "source_id": app.source_id,
        "source_key": key,
        "source_revision": REVISION,
        "generation": generation,
        "expected_keys": [output["key"] for output in entry["outputs"]],
        **overrides,
    }


@contextmanager
def worker_source(function, config=None):
    """Mock only snapshot loading; keep registration and parameter admission real."""
    config = config or assignment()
    entry = {**config, "key": config["source_key"]}
    source = SimpleNamespace(
        bindings={entry["key"]: SimpleNamespace(function=function)},
        arguments=lambda _key, params, **_kwargs: {"params": params},
    )
    with (
        patch.dict("os.environ", {"MONDEK_BUNDLE_DIR": "/unused-unit-snapshot"}),
        patch(
            "mondek_runner.worker.load_snapshot",
            return_value=(
                source,
                {"source_id": config["source_id"], "checks": [entry]},
            ),
        ),
    ):
        yield
