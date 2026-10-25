#!/usr/bin/env python3
# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Real multi-runner, datasource, local-file and source deployment acceptance."""

from __future__ import annotations

import json
import time
import urllib.parse
from datetime import UTC, datetime
from typing import Any

from acceptance import Acceptance, run_compose
from parity_transport import ParityTransportMixin, exact_buffered_evidence
from schema_evolution import SchemaEvolutionMixin


class ParityAcceptance(SchemaEvolutionMixin, ParityTransportMixin, Acceptance):
    def __init__(self, *, dynamic_ports: bool = False) -> None:
        super().__init__(dynamic_ports=dynamic_ports)
        self.env.update(
            MONDEK_CONSUMER="demo_checks.app:app",
            MONDEK_SPOOL_MAX_REPORTS="128",
            MONDEK_SPOOL_MAX_BYTES="524288",
        )
        self.saved_streams: dict[str, dict[str, Any]] = {}

    def compose(self, *args: str, capture: bool = False, timeout: float = 900) -> str:
        return run_compose(
            [
                "docker",
                "compose",
                "-p",
                self.project,
                "-f",
                "compose.yaml",
                "-f",
                "examples/compose/parity.yaml",
                *args,
            ],
            env=self.env,
            log=self.log,
            capture=capture,
            timeout=timeout,
        )

    def overview(self) -> dict[str, Any]:
        return self.request("/api/v1/overview")

    def streams(self, **filters: Any) -> dict[str, Any]:
        return self.request("/api/v1/checks?" + urllib.parse.urlencode(filters))

    def stream(self, target_key: str) -> dict[str, Any]:
        return next(
            item
            for item in self.streams(search=target_key)["items"]
            if item["target"]["key"] == target_key
        )

    def detail(self, stream: dict[str, Any]) -> dict[str, Any]:
        return self.request("/api/v1/checks/" + stream["id"])

    def fresh(self, target: str, health: str = "OK") -> dict[str, Any] | bool:
        stream = self.stream(target)
        current = stream["current"]
        return (
            stream
            if current.get("knowledge") == "fresh" and current.get("health") == health
            else False
        )

    def node_mode(self, node: str, **changes: str) -> dict[str, Any]:
        script = (
            "import json,urllib.request; "
            f"body={json.dumps(changes)!r}.encode(); "
            "r=urllib.request.Request('http://localhost:8081/mode',body,{'Content-Type':'application/json'}); "
            "print(urllib.request.urlopen(r,timeout=5).read().decode())"
        )
        return json.loads(
            self.compose(
                "exec", "-T", node + "-target", "python", "-c", script, capture=True
            )
        )

    def clean_start(self) -> dict[str, Any]:
        self.compose("up", "--build", "--detach", "--wait", "--wait-timeout", "180")
        baseline = self.eventually(
            "four runners and eleven fresh results",
            lambda: (
                view
                if (view := self.overview())["runner_count"] == 4
                and view["coverage"]["fresh"] == 11
                else False
            ),
            timeout=180,
        )
        items = self.streams()["items"]
        assert len(items) == 11
        assert len({item["id"] for item in items}) == 11
        assert (
            self.stream("node:node-a/root")["assignment_id"]
            != self.stream("node:node-b/root")["assignment_id"]
        )
        assert (
            self.stream("service:primary")["runner_id"]
            != self.stream("node:node-a/root")["runner_id"]
        )
        for item in items:
            assert item["source_id"] and item["source_revision"]
            self.saved_streams[item["target"]["key"]] = item
        return {
            "runner_count": baseline["runner_count"],
            "fresh_results": 11,
            "controller_check_kind_changes": 0,
        }

    def local_files_and_processes(self) -> dict[str, Any]:
        target = "node:node-a/export"
        stream_id = self.stream(target)["id"]
        episodes = []
        for mode in ("missing", "stale", "invalid"):
            self.node_mode("node-a", export=mode)
            failed = self.eventually(
                f"{mode} export measured failure", lambda: self.fresh(target, "CRIT")
            )
            incident = next(
                item
                for item in self.detail(failed)["incidents"]
                if item["status"] == "open"
            )
            assert self.fresh("node:node-b/export")
            self.node_mode("node-a", export="healthy")
            recovered = self.eventually(
                f"{mode} export measured recovery", lambda: self.fresh(target)
            )
            assert recovered["id"] == stream_id
            closed = self.eventually(
                "export incident closes with measured evidence",
                lambda: next(
                    (
                        item
                        for item in self.detail(recovered)["incidents"]
                        if item["id"] == incident["id"] and item["status"] == "closed"
                    ),
                    None,
                ),
            )
            assert closed["closure_reason"] == "measured_recovery"
            assert closed["closing_observation_id"]
            episodes.append(
                {
                    "mode": mode,
                    "incident_id": incident["id"],
                    "closing_observation_id": closed["closing_observation_id"],
                }
            )

        self.node_mode("node-a", export="unreadable")
        unavailable = self.eventually(
            "unreadable export is lost visibility",
            lambda: (
                item
                if (item := self.stream(target))["current"]["knowledge"]
                == "unavailable"
                else False
            ),
        )
        assert unavailable["current"]["health"] == "OK"
        assert "permission" in unavailable["current"]["execution_summary"].lower()
        assert self.overview()["coverage"]["expected_count"] == 11
        self.node_mode("node-a", export="healthy", process="stopped")
        self.eventually("readable export resumes", lambda: self.fresh(target))
        process = self.eventually(
            "local process stop is measured",
            lambda: self.fresh("node:node-a/process", "CRIT"),
        )
        assert self.fresh("node:node-b/process")
        self.node_mode("node-a", process="running")
        restarted = self.eventually(
            "new local process is independently verified",
            lambda: self.fresh("node:node-a/process"),
        )
        assert restarted["id"] == process["id"]
        return {
            "export_episodes": episodes,
            "unreadable_means_unavailable": True,
            "process_stream": process["id"],
        }

    def datasource_results(self) -> dict[str, Any]:
        self.mode(ready=False)
        primary = self.eventually(
            "Prometheus primary failure", lambda: self.fresh("service:primary", "CRIT")
        )
        siblings = {
            item["target"]["key"]: item
            for item in self.streams(search="service:")["items"]
        }
        primary, secondary = siblings["service:primary"], siblings["service:secondary"]
        assert primary["current"]["health"] == "CRIT"
        assert secondary["current"]["health"] == "OK"
        assert primary["assignment_id"] == secondary["assignment_id"]
        assert (
            primary["current"]["observation_id"]
            == secondary["current"]["observation_id"]
        )
        primary_incident = next(
            item
            for item in self.detail(primary)["incidents"]
            if item["status"] == "open"
        )
        self.mode(secondary_ready=False)
        secondary = self.eventually(
            "Prometheus secondary independently fails",
            lambda: self.fresh("service:secondary", "CRIT"),
        )
        secondary_incident = next(
            item
            for item in self.detail(secondary)["incidents"]
            if item["status"] == "open"
        )
        assert primary_incident["id"] != secondary_incident["id"]
        self.mode(ready=True)
        self.eventually(
            "primary recovers independently", lambda: self.fresh("service:primary")
        )
        assert self.fresh("service:secondary", "CRIT")

        self.compose("stop", "prometheus")
        unknown = self.eventually(
            "datasource loss retains failing target health",
            lambda: (
                item
                if (item := self.stream("service:secondary"))["current"]["knowledge"]
                == "unavailable"
                else False
            ),
        )
        assert unknown["current"]["health"] == "CRIT"
        assert self.overview()["coverage"]["expected_count"] == 11
        assert any(
            item["id"] == secondary_incident["id"] and item["status"] == "open"
            for item in self.detail(unknown)["incidents"]
        )
        self.mode(secondary_ready=True)
        self.compose("start", "prometheus")
        recovered = self.eventually(
            "datasource recovery supplies new measurement",
            lambda: self.fresh("service:secondary"),
        )
        closed = next(
            item
            for item in self.detail(recovered)["incidents"]
            if item["id"] == secondary_incident["id"]
        )
        assert closed["closure_reason"] == "measured_recovery"
        self.eventually(
            "terminal local webhook delivery",
            lambda: any(
                record["payload"].get("incident_id") == secondary_incident["id"]
                and record["payload"].get("kind") == "resolved"
                and record["payload"].get("observation_id")
                == closed["closing_observation_id"]
                for record in self.records()
            ),
        )
        return {
            "shared_assignment_id": primary["assignment_id"],
            "independent_incidents": [primary_incident["id"], secondary_incident["id"]],
            "outage_preserved_coverage": True,
        }

    def consumer_code_update(self) -> dict[str, Any]:
        original = self.compose(
            "exec",
            "-T",
            "node-a-runner",
            "python",
            "-c",
            "from pathlib import Path; import mondek_examples.node as m; print(Path(m.__file__).read_text(),end='')",
            capture=True,
        )

        def replace(source: str) -> None:
            script = (
                "from pathlib import Path; import importlib.util; p=Path(importlib.util.find_spec('mondek_examples.node').origin); "
                + f"p.write_text({source!r})"
            )
            self.compose(
                "exec", "-T", "--user", "0", "node-a-runner", "python", "-c", script
            )
            self.compose("restart", "node-a-runner")

        before = self.stream("node:node-a/export")
        renamed = original.replace(
            "Application export validity and age", "Local export validation"
        )
        replace(renamed)
        updated = self.eventually(
            "consumer code revision and label appear",
            lambda: (
                item
                if (item := self.stream("node:node-a/export"))["source_revision"]
                != before["source_revision"]
                and item["current"]["knowledge"] == "fresh"
                else False
            ),
            timeout=90,
        )
        assert updated["id"] == before["id"]
        assert updated["check_label"] == "Local export validation"
        sequence = updated["current"]["observation_id"]
        previous_session = updated["current"]["session_id"]
        replace("raise RuntimeError('intentional local broken deployment')\n")
        kept = self.eventually(
            "failed import keeps previous code collecting after restart",
            lambda: (
                item
                if (item := self.stream("node:node-a/export"))["current"]["knowledge"]
                == "fresh"
                and item["current"]["observation_id"] != sequence
                and item["current"]["session_id"] != previous_session
                else False
            ),
            timeout=90,
        )
        assert kept["source_revision"] == updated["source_revision"]
        runner = next(
            item
            for item in self.request("/api/v1/runners")["items"]
            if item["id"] == kept["runner_id"]
        )
        assert "discovery failed" in runner["status"].get("diagnostic", "")

        self.node_mode("node-a", export="missing")
        failed = self.eventually(
            "export failure before intentional withdrawal",
            lambda: self.fresh("node:node-a/export", "CRIT"),
        )
        replace(renamed + "\napp.bindings.pop('export-file')\n")
        retired = self.eventually(
            "explicit complete source removal retires monitoring",
            lambda: (
                detail
                if (detail := self.detail(failed))["stream"]["retired"]
                else False
            ),
            timeout=90,
        )
        assert retired["stream"]["id"] == before["id"]
        assert all(item["status"] == "closed" for item in retired["incidents"])
        assert any(
            item["closure_reason"] == "source_removed" for item in retired["incidents"]
        )
        self.node_mode("node-a", export="healthy")
        replace(original)
        restored = self.eventually(
            "restored source provides fresh monitoring",
            lambda: self.fresh("node:node-a/export"),
            timeout=90,
        )
        assert restored["id"] != before["id"]
        return {
            "stable_id_across_rename": before["id"],
            "failed_import_retained_revision": updated["source_revision"],
            "withdrawn_history": retired["stream"]["id"],
            "new_monitoring_after_withdrawal": restored["id"],
        }

    def capacity(self) -> dict[str, Any]:
        group_size = int(self.env.get("MONDEK_LOAD_GROUP_SIZE", "10"))
        groups = (500 + group_size - 1) // group_size
        # Keep the measured workload identical to the result metadata, even if
        # the invoking shell has overrides for an interactive capacity demo.
        self.env.update(
            MONDEK_LOAD_CHECKS="500",
            MONDEK_LOAD_INTERVAL="60",
            MONDEK_LOAD_CONCURRENCY="3",
        )
        self.compose(
            "--profile", "capacity", "up", "--build", "--detach", "capacity-runner"
        )
        ready_at = time.monotonic()
        self.eventually(
            "five hundred real file results measured",
            lambda: (
                self.streams(environment="capacity-test")["total"] == 500
                and self.streams(environment="capacity-test", freshness="fresh")[
                    "total"
                ]
                == 500
            ),
            timeout=240,
        )
        initial_seconds = time.monotonic() - ready_at
        print(
            f"  capacity: 500 fresh results from {groups} scheduled checks in {initial_seconds:.2f}s",
            flush=True,
        )
        latencies = []
        ids: set[str] = set()
        assignments: set[str] = set()
        for page in range(1, 11):
            start = time.monotonic()
            result = self.streams(environment="capacity-test", page=page, page_size=50)
            latencies.append(time.monotonic() - start)
            assert result["total"] == 500 and len(result["items"]) == 50
            assert not ids.intersection(item["id"] for item in result["items"])
            ids.update(item["id"] for item in result["items"])
            assignments.update(item["assignment_id"] for item in result["items"])
        assert len(assignments) == groups
        searched = self.streams(search="exports/export-0499.txt")
        assert searched["total"] == 1
        assert self.detail(searched["items"][0])["stream"]["current"]["health"] == "OK"
        self.compose(
            "run",
            "--rm",
            "--no-deps",
            "capacity-files",
            "python",
            "-c",
            "from pathlib import Path; Path('/samples/export-0499.txt').write_text('invalid export')",
        )
        failed = self.eventually(
            "a file among five hundred actually changes health",
            lambda: self.fresh("load:export-0499", "CRIT"),
            timeout=90,
        )
        assert self.streams(environment="capacity-test", health="CRIT")["total"] == 1
        self.compose(
            "run",
            "--rm",
            "--no-deps",
            "capacity-files",
            "python",
            "-c",
            "from pathlib import Path; Path('/samples/export-0499.txt').write_text('valid export\\n')",
        )
        self.eventually(
            "large inventory file recovery",
            lambda: self.fresh("load:export-0499"),
            timeout=90,
        )
        print("  capacity: independent file failure and recovery measured", flush=True)
        reconnect = self.capacity_reconnect(failed["runner_id"], assignments)
        return {
            "actual_file_results": 500,
            "scheduled_groups": groups,
            "results_per_group": group_size,
            "interval_seconds": 60,
            "concurrency": 3,
            "initial_measurement_seconds": round(initial_seconds, 2),
            "page_response_ms": [round(value * 1000, 2) for value in latencies],
            "independent_failure_stream": failed["id"],
            "reconnect": reconnect,
        }

    def capacity_reconnect(
        self, runner_id: str, assignments: set[str]
    ) -> dict[str, Any]:
        """Every scheduled group contributes original buffered evidence after restart."""
        from collections import deque

        queue_samples: deque[dict[str, Any]] = deque(maxlen=2048)
        sample_count = peak_reports = peak_bytes = 0
        started_at = previous_sample_at = time.monotonic()
        maximum_sample_gap = 0.0

        def journal() -> dict[str, Any]:
            nonlocal sample_count, peak_reports, peak_bytes
            nonlocal previous_sample_at, maximum_sample_gap
            sample = self.node_journal("capacity-runner")
            captured = time.monotonic()
            sample_count += 1
            peak_reports = max(peak_reports, sample["status"]["queue_count"])
            peak_bytes = max(peak_bytes, sample["status"]["queue_bytes"])
            if sample_count > 1:
                maximum_sample_gap = max(
                    maximum_sample_gap, captured - previous_sample_at
                )
            previous_sample_at = captured
            assert sample["status"]["queue_count"] <= 2048
            assert sample["status"]["queue_bytes"] <= 8_388_608
            queue_samples.append(
                {
                    "captured_at": sample["captured_at"],
                    "elapsed_seconds": round(captured - started_at, 3),
                    "status": sample["status"],
                }
            )
            return sample

        baseline = journal()
        samples = [baseline]
        expected = self.overview()["coverage"]["expected_count"]
        original: list[dict[str, Any]] = []
        fresh_measurements: list[dict[str, Any]] = []
        try:
            self.mode(offline_installations=[runner_id])
            blocked_at = datetime.now(UTC)
            print(
                "  capacity: collecting a complete offline execution cohort", flush=True
            )

            def completed_reports(sample: dict[str, Any]) -> dict[str, dict[str, Any]]:
                return {
                    report["assignment_id"]: report
                    for report in sample["reports"]
                    if datetime.fromisoformat(report["started_at"]) >= blocked_at
                    and report["session_id"] == baseline["status"]["session_id"]
                    and report["complete"]
                    and report["results"]
                }

            def complete_cohort() -> dict[str, Any] | bool:
                sample = journal()
                assert (
                    sample["status"]["session_id"] == baseline["status"]["session_id"]
                )
                collected = completed_reports(sample)
                return sample if assignments <= set(collected) else False

            queued = self.eventually(
                "every capacity check executes while disconnected",
                complete_cohort,
                timeout=240,
            )
            samples.append(queued)
            cohort = completed_reports(queued)
            original = [cohort[id_] for id_ in sorted(assignments)]
            assert sum(len(report["results"]) for report in original) == 500
            assert all(
                result["source_at"] and result["health"] == "OK"
                for report in original
                for result in report["results"]
            )
            assert queued["status"]["dropped"] == baseline["status"]["dropped"]
            assert queued["status"]["queue_count"] <= 2048
            assert queued["status"]["queue_bytes"] <= 8_388_608
            assert self.overview()["coverage"]["expected_count"] == expected

            self.compose("restart", "capacity-runner")
            restarted = self.eventually(
                "capacity runner restarts offline and resumes real execution",
                lambda: (
                    sample
                    if (sample := journal())["status"]["boot"]
                    > baseline["status"]["boot"]
                    and any(
                        report["session_id"] == sample["status"]["session_id"]
                        and report["complete"]
                        and report["results"]
                        for report in sample["reports"]
                    )
                    else False
                ),
                timeout=90,
            )
            samples.append(restarted)
            assert restarted["status"]["installation_id"] == runner_id
            assert restarted["status"]["session_id"] != baseline["status"]["session_id"]
            pending = {report["id"]: report for report in restarted["reports"]}
            assert all(pending[report["id"]] == report for report in original)
            assert restarted["status"]["dropped"] == baseline["status"]["dropped"]

            self.mode(offline_installations=[])
            resumed_at = time.monotonic()
            report_ids = [report["id"] for report in original]

            def committed_cohort() -> list[dict[str, Any]] | bool:
                journal()
                rows = self.stored_reports(report_ids)
                return rows if len(rows) == len(report_ids) else False

            committed = self.eventually(
                "the complete capacity cohort commits with original identity and age",
                committed_cohort,
                timeout=180,
            )
            evidence = exact_buffered_evidence(original, committed)
            assert evidence["historical"] == len(original)
            committed_seconds = time.monotonic() - resumed_at

            def fresh_new_session() -> list[dict[str, Any]] | bool:
                journal()
                if self.streams(runner_id=runner_id, freshness="fresh")["total"] != 500:
                    return False
                rows = [
                    row
                    for page in range(1, 6)
                    for row in self.streams(
                        runner_id=runner_id,
                        freshness="fresh",
                        page=page,
                        page_size=100,
                    )["items"]
                ]
                if (
                    len({row["id"] for row in rows}) != 500
                    or {row["assignment_id"] for row in rows} != assignments
                ):
                    return False
                session = restarted["status"]["session_id"]
                if not all(
                    row["current"].get("session_id") == session
                    and row["current"].get("confirmed_session_id") == session
                    and row["current"].get("knowledge") == "fresh"
                    and row["current"].get("health") == "OK"
                    for row in rows
                ):
                    return False
                return rows

            fresh_rows = self.eventually(
                "all five hundred results have fresh evidence from the new session",
                fresh_new_session,
                timeout=240,
            )
            fresh_seconds = time.monotonic() - resumed_at
            fresh_measurements = [
                {
                    "id": row["id"],
                    "assignment_id": row["assignment_id"],
                    "current": {
                        key: row["current"].get(key)
                        for key in (
                            "observation_id",
                            "confirmed_observation_id",
                            "session_id",
                            "confirmed_session_id",
                            "source_at",
                            "knowledge",
                            "health",
                        )
                    },
                }
                for row in fresh_rows
            ]

            def acknowledged_cohort() -> dict[str, Any] | bool:
                sample = journal()
                pending_ids = {report["id"] for report in sample["reports"]}
                return (
                    sample if not set(report_ids).intersection(pending_ids) else False
                )

            final = self.eventually(
                "the runner acknowledges every original capacity cohort report",
                acknowledged_cohort,
                timeout=60,
            )
            samples.append(final)
            assert final["status"]["dropped"] == baseline["status"]["dropped"]
            assert final["status"]["session_id"] == restarted["status"]["session_id"]
            assert self.overview()["coverage"]["expected_count"] == expected
            print(
                "  capacity: original cohort preserved and fresh coverage restored",
                flush=True,
            )
            return {
                "scheduled_checks_with_original_offline_evidence": len(original),
                "buffered_evidence": evidence,
                "original_payload_bytes": sum(
                    len(json.dumps(report, separators=(",", ":")).encode())
                    for report in original
                ),
                "cohort_commit_seconds": round(committed_seconds, 2),
                "fresh_coverage_seconds": round(fresh_seconds, 2),
                "fresh_new_session_results": len(fresh_measurements),
                "new_session_id": restarted["status"]["session_id"],
                "original_cohort_acknowledged": len(report_ids),
                "sampled_queue_peak_reports": peak_reports,
                "sampled_queue_peak_bytes": peak_bytes,
                "queue_sample_count": sample_count,
                "queue_samples_retained": len(queue_samples),
                "maximum_queue_sample_gap_seconds": round(maximum_sample_gap, 3),
                "queue_sampling": "Workflow polling; observed peaks, no guaranteed sampling cadence",
                "dropped_report_growth": final["status"]["dropped"]
                - baseline["status"]["dropped"],
            }
        finally:
            try:
                (self.output / "capacity-transport-journal.json").write_text(
                    json.dumps(
                        {
                            "samples": samples,
                            "queue_samples": list(queue_samples),
                            "queue_sample_count": sample_count,
                            "original": original,
                            "fresh_measurements": fresh_measurements,
                        },
                        indent=2,
                    )
                )
            finally:
                self.mode(offline_installations=[])

    def run(self) -> None:
        print(
            f"Parity project: {self.project}; UI: {self.base}; evidence: {self.output}",
            flush=True,
        )
        success = False
        try:
            for label, function in [
                (
                    "runner-provided inventory across dedicated and node runners",
                    self.clean_start,
                ),
                (
                    "real export files and exact local process identity",
                    self.local_files_and_processes,
                ),
                (
                    "shared Prometheus collection with independent results and outages",
                    self.datasource_results,
                ),
                (
                    "source updates, failed imports and explicit withdrawal",
                    self.consumer_code_update,
                ),
                (
                    "independent runner transport, exact retries and reconnects",
                    self.multi_runner_transport,
                ),
                (
                    "additive delegated schema, retained values and incompatible-update recovery",
                    self.additive_schema,
                ),
                (
                    "five hundred actual file evaluations and paged inspection",
                    self.capacity,
                ),
            ]:
                self.run_step(label, function)
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
                (self.output / "parity-results.json").write_text(
                    json.dumps(
                        {
                            "success": success,
                            "finished_at": datetime.now(UTC).isoformat(),
                            "project": self.project,
                            "steps": self.steps,
                        },
                        indent=2,
                    )
                )
            finally:
                try:
                    self.compose(
                        "--profile", "capacity", "logs", "--no-color", "--tail", "250"
                    )
                finally:
                    try:
                        self.compose(
                            "--profile",
                            "capacity",
                            "down",
                            "--volumes",
                            "--remove-orphans",
                        )
                    finally:
                        self.log.close()
            print(f"Evidence: {self.output}", flush=True)
        assert success
        print("All real runner-owned parity scenarios passed.", flush=True)


if __name__ == "__main__":
    ParityAcceptance().run()
