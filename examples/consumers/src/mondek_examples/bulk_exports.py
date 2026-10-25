# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Explicitly delegated export thresholds for a representative bulk-edit workflow.

The v1 contract means minimum byte counts for the same exact valid export format.
Threshold comparisons are strict: equality meets the minimum. File paths remain
private datasource settings; the UI owns the complete pair of byte thresholds.
"""

from __future__ import annotations

import os

from mondek_runner import App, Environment

from mondek_examples.load import ExportDirectory, make_group


def make_app(
    *,
    count: int = 500,
    group_size: int = 1,
    interval_seconds: int = 120,
    directory: str = "/samples",
) -> App:
    if (
        not 1 <= count <= 512
        or not 1 <= group_size <= 16
        or not 5 <= interval_seconds <= 3600
    ):
        raise ValueError(
            "bulk exports requires 1–512 results, groups of 1–16 "
            "and interval of 5–3600 seconds"
        )
    consumer = App(
        source_id="export-policy",
        name="Export file policy",
        environment=Environment("bulk-config-test", "Configuration test"),
        checks=[
            make_group(
                start,
                min(count, start + group_size),
                delegated=True,
                interval_seconds=interval_seconds,
            )
            for start in range(0, count, group_size)
        ],
    )
    consumer.register_datasource(ExportDirectory, directory=directory)
    return consumer


app = make_app(
    count=int(os.environ.get("MONDEK_LOAD_CHECKS", "500")),
    group_size=int(os.environ.get("MONDEK_LOAD_GROUP_SIZE", "1")),
    interval_seconds=int(os.environ.get("MONDEK_LOAD_INTERVAL", "120")),
    directory=os.environ.get("MONDEK_LOAD_DIRECTORY", "/samples"),
)
