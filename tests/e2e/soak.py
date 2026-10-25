#!/usr/bin/env python3
# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Bounded source deployment and reconnect soak using real, isolated services."""

from __future__ import annotations

import json
import os
import time
from datetime import UTC, datetime
from typing import Any

from parity import ParityAcceptance


class Soak(ParityAcceptance):
    def __init__(self) -> None:
        super().__init__()
        self.duration = int(os.environ.get("MONDEK_SOAK_SECONDS", "600"))
        if not 60 <= self.duration <= 3600:
            raise ValueError("MONDEK_SOAK_SECONDS must be in 60..3600")
        self.cycles: list[dict[str, Any]] = []

    def cycle(self, number: int) -> dict[str, Any]:
        started = time.monotonic()
        consumer_id = self.stream("demo-backlog")["assignment_id"]
        consumer = self.assignment(consumer_id)
        next_warning = 5 if consumer["params"]["warn_count"] == 4 else 4
        changed = self.request(
            "/api/v1/assignments/" + consumer_id,
            {
                "revision": consumer["revision"],
                "params": consumer["params"] | {"warn_count": next_warning},
            },
            method="PUT",
        )
        assert changed["desired_generation"] > consumer["desired_generation"]
        self.eventually(
            "the delegated parameter set is measured exactly",
            lambda: (
                (current := self.assignment(consumer_id))["observed_generation"]
                == changed["desired_generation"]
                and current["current"].get("confirmed_params") == changed["params"]
                and current["current"]["knowledge"] == "fresh"
            ),
        )

        # Exercise the actual consumer deployment and transport boundaries. The
        # source owns membership; no controller-created checks are used here.
        if number % 2:
            scenario = "source rename, broken import, withdrawal and restoration"
            details = self.consumer_code_update()
        else:
            scenario = "isolated node outage, controller/runner restart and exact retry"
            details = self.multi_runner_transport()
            for name in ("transport-journal.json", "transport-retry.json"):
                path = self.output / name
                if path.exists():
                    path.rename(self.output / f"cycle-{number}-{name}")

        self.eventually(
            "all four runners restore eleven fresh healthy results",
            lambda: (
                (view := self.overview())["runner_count"] == 4
                and view["coverage"]["expected_count"] == 11
                and view["coverage"]["fresh"] == 11
                and self.streams(health="OK", freshness="fresh")["total"] == 11
            ),
        )
        journals = {
            name: self.node_journal(name)
            for name in (
                "runner",
                "node-a-runner",
                "node-b-runner",
                "monitoring-runner",
            )
        }
        for journal in journals.values():
            assert journal["status"]["queue_count"] <= 128
            assert journal["status"]["queue_bytes"] <= 524288
            assert journal["status"]["dropped"] == 0
        result = {
            "cycle": number,
            "scenario": scenario,
            "seconds": round(time.monotonic() - started, 2),
            "measured_parameter_generation": changed["desired_generation"],
            "details": details,
            "runners": {name: value["status"] for name, value in journals.items()},
        }
        (self.output / f"cycle-{number}.json").write_text(json.dumps(result, indent=2))
        print(json.dumps(result), flush=True)
        return result

    def run(self) -> None:
        success = False
        started = time.monotonic()
        self.env.update(MONDEK_SPOOL_MAX_REPORTS="128", MONDEK_SPOOL_MAX_BYTES="524288")
        print(f"Soak project: {self.project}; UI: {self.base}", flush=True)
        try:
            self.clean_start()
            started = time.monotonic()
            deadline = started + self.duration
            while time.monotonic() < deadline:
                self.cycles.append(self.cycle(len(self.cycles) + 1))
            success = True
        finally:
            try:
                for filename, read in (
                    ("overview.json", self.overview),
                    ("snapshot.json", self.snapshot),
                    ("receipts.json", self.records),
                ):
                    try:
                        (self.output / filename).write_text(
                            json.dumps(read(), indent=2)
                        )
                    except Exception:
                        pass
                (self.output / "soak-results.json").write_text(
                    json.dumps(
                        {
                            "success": success,
                            "project": self.project,
                            "requested_seconds": self.duration,
                            "elapsed_seconds": round(time.monotonic() - started, 2),
                            "finished_at": datetime.now(UTC).isoformat(),
                            "cycles": self.cycles,
                            "completed_scenarios": sorted(
                                {cycle["scenario"] for cycle in self.cycles}
                            ),
                        },
                        indent=2,
                    )
                )
            finally:
                try:
                    self.compose("logs", "--no-color", "--tail", "250")
                finally:
                    try:
                        self.compose("down", "--volumes", "--remove-orphans")
                    finally:
                        self.log.close()
            print(f"Soak evidence: {self.output}", flush=True)
        assert success


if __name__ == "__main__":
    Soak().run()
