# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Real numeric Prometheus measurements through the installed runner and controller."""

from __future__ import annotations

import json
from datetime import UTC, datetime
from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:
    from consumers import ConsumerAcceptance

SERVICE = "numeric-runner"
TARGET = "queue:primary"


class NumericMetricsMixin:
    def numeric_metric(self: ConsumerAcceptance) -> dict[str, Any]:
        self.mode(backlog=2)
        self.compose(
            "--profile",
            "starters",
            "up",
            "--build",
            "--detach",
            "--wait",
            "--wait-timeout",
            "180",
            SERVICE,
        )
        initial = self.eventually(
            "installed numeric consumer measures the real queue gauge",
            lambda: self.fresh(TARGET),
            timeout=120,
        )
        assert initial["source_id"] == "numeric-threshold-example"
        assert initial["current"]["value"] == 2
        assert "items" in initial["current"]["summary"]
        assert self.overview()["runner_count"] == 4
        assert self.overview()["coverage"]["expected_count"] == 9
        original_journal = self.node_journal(SERVICE)["status"]
        all_targets = tuple(
            row["target"]["key"] for row in self.streams(page_size=100)["items"]
        )
        assert len(all_targets) == 9
        measurements = {}

        def sample_at_boundary(value: int, health: str) -> dict[str, Any]:
            self.mode(backlog=value)
            changed_at = datetime.now(UTC)

            def measured() -> dict[str, Any] | bool:
                row = self.fresh(TARGET, health)
                return (
                    row
                    if (
                        row
                        and row["current"]["value"] == value
                        and datetime.fromisoformat(row["current"]["source_at"])
                        > changed_at
                    )
                    else False
                )

            row = self.eventually(
                f"numeric boundary {value} is measured {health}", measured
            )
            assert row["id"] == initial["id"]
            source_time = datetime.fromisoformat(
                row["current"]["source_at"]
            ).timestamp()
            samples = json.loads(
                self.compose(
                    "exec",
                    "-T",
                    SERVICE,
                    "python",
                    "-c",
                    "import json,sys,urllib.parse,urllib.request; "
                    "query=urllib.parse.urlencode({'query':'mondek_fixture_queue_depth[30s]', 'time':sys.argv[1]}); "
                    "response=urllib.request.urlopen('http://prometheus:9090/api/v1/query?'+query,timeout=5); "
                    "print(json.dumps(json.load(response)))",
                    str(source_time + 0.001),
                    capture=True,
                    timeout=10,
                )
            )
            assert samples["status"] == "success"
            assert any(
                series["metric"].get("service") == "primary"
                and abs(float(sample_at) - source_time) < 0.001
                and float(sample_value) == value
                for series in samples["data"]["result"]
                for sample_at, sample_value in series["values"]
            ), "Numeric result did not retain its actual Prometheus sample and age"
            measurements[health] = {"stream": row, "prometheus_samples": samples}
            return row

        try:
            warning = sample_at_boundary(5, "WARN")
            incident = self.incident_opened(warning)
            critical = sample_at_boundary(10, "CRIT")
            assert self.incident_opened(critical)["id"] == incident["id"]
            self.eventually(
                "numeric failure delivers its immutable local notification",
                lambda: any(
                    record["payload"].get("incident_id") == incident["id"]
                    and record["payload"].get("kind") == "firing"
                    for record in self.records()
                ),
            )
            sample_at_boundary(2, "OK")
            recovered = self.measured_recovery(TARGET, critical, incident)
            assert recovered["incident"]["closure_reason"] == "measured_recovery"

            assignment = self.assignment(initial["assignment_id"])
            changed = self.request(
                "/api/v1/assignments/" + assignment["id"],
                {
                    "revision": assignment["revision"],
                    "params": {"warning": 4, "critical": 8},
                },
                method="PUT",
            )
            self.eventually(
                "numeric delegated thresholds are measured exactly",
                lambda: (
                    (current := self.assignment(assignment["id"])["current"]).get(
                        "confirmed_generation"
                    )
                    == changed["desired_generation"]
                    and current.get("confirmed_params") == changed["params"]
                    and current["knowledge"] == "fresh"
                    and current["health"] == "OK"
                ),
            )
            previous = self.stream(TARGET)
            self.compose("restart", SERVICE)
            restarted_at = datetime.now(UTC)

            def restarted() -> dict[str, Any] | bool:
                rows = self.cohort(all_targets, after_time=restarted_at)
                if not rows:
                    return False
                current = rows[TARGET]["current"]
                return (
                    rows
                    if (
                        current["session_id"] != previous["current"]["session_id"]
                        and current["confirmed_session_id"] == current["session_id"]
                        and current["confirmed_params"] == changed["params"]
                    )
                    else False
                )

            final = self.eventually(
                "nine healthy results and unchanged numeric identity after restart",
                restarted,
            )
            journal = self.node_journal(SERVICE)["status"]
            assert journal["installation_id"] == original_journal["installation_id"]
            assert journal["boot"] == original_journal["boot"] + 1
            assert journal["dropped"] == original_journal["dropped"] == 0
            assert final[TARGET]["id"] == initial["id"]
            details = {
                "initial": initial,
                "measurements": measurements,
                "incident": recovered["incident"],
                "saved_thresholds": changed["params"],
                "final": final[TARGET],
                "journal_before": original_journal,
                "journal_after": journal,
                "fresh_results": len(final),
            }
            (self.output / "11-numeric-prometheus.json").write_text(
                json.dumps(details, indent=2)
            )
            self.capture("11-final-numeric-and-node-coverage", all_targets)
            return details
        finally:
            self.mode(backlog=2)
