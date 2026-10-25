# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Ordinary async consumer with an injected datasource and explicit result key."""

from __future__ import annotations

import asyncio
import json
import os
import urllib.request
from dataclasses import dataclass
from typing import Any

from mondek_runner import Datasource, Result, build_result, check
from mondek_runner.api import timestamp


@dataclass(frozen=True)
class BacklogSnapshot:
    count: int
    source_at: str | None
    processing_enabled: bool = True


@dataclass(frozen=True)
class BacklogPolicy:
    """Consumer policy: queued work with processing disabled is critical.

    An empty paused queue is acceptable unless its count crosses a configured
    threshold. This application rule belongs here, not in the runner framework.
    """

    warn_count: int
    crit_count: int

    def evaluate(self, snapshot: BacklogSnapshot) -> Result:
        summary = f"{snapshot.count} queued items"
        result = build_result(
            "backlog",
            ok_summary=summary,
            fail_summary=summary,
            value=snapshot.count,
            source_at=snapshot.source_at,
            base_details=(
                f"Warning at: {self.warn_count} items\n"
                f"Critical at: {self.crit_count} items\n"
                f"Processing enabled: {snapshot.processing_enabled}"
            ),
        )
        if snapshot.count >= self.crit_count:
            result.crit("Queued count reached the critical threshold")
        elif snapshot.count >= self.warn_count:
            result.warn("Queued count reached the warning threshold")
        else:
            result.ok("Queued count is below the warning threshold")

        if not snapshot.processing_enabled:
            if snapshot.count > 0:
                result.crit("Processing is disabled while queued work remains")
            else:
                result.ok("Processing is disabled with no queued work")
        return result.finalize()


class BacklogDatasource(Datasource):
    def __init__(self, url: str):
        self.url = url

    async def collect(self) -> BacklogSnapshot:
        def fetch() -> tuple[dict[str, Any], str]:
            with urllib.request.urlopen(self.url, timeout=1.2) as response:
                raw = response.read(65537)
            if len(raw) > 65536:
                raise ValueError("datasource response exceeded 64 KiB cap")
            return json.loads(raw), timestamp()

        data, collected_at = await asyncio.to_thread(fetch)
        # Explicit local fixture faults exercise supervisor boundaries, never commands.
        if data.get("crash"):
            os._exit(17)
        if data.get("delay_seconds"):
            await asyncio.sleep(min(float(data["delay_seconds"]), 600))
        if data.get("output_bytes"):
            remaining = min(int(data["output_bytes"]), 1048576)
            while remaining > 0:
                print("x" * min(4096, remaining), flush=True)
                remaining -= 4096
        count = data["backlog"]
        if type(count) is not int or count < 0:
            raise ValueError("datasource backlog must be a nonnegative integer")
        processing_enabled = data.get("processing_enabled", True)
        if type(processing_enabled) is not bool:
            raise ValueError("datasource processing_enabled must be a boolean")
        return BacklogSnapshot(
            count, data.get("source_at", collected_at), processing_enabled
        )


@check(expected_keys=("backlog",))
async def backlog(
    *, params: dict, datasource: BacklogDatasource | None = None
) -> Result:
    snapshot = await (datasource or BacklogDatasource(params["url"])).collect()
    return BacklogPolicy(params["warn_count"], params["crit_count"]).evaluate(snapshot)
