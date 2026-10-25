#!/usr/bin/env python3
# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Real installed node/file/PID and Prometheus scrape-health starter acceptance."""

from __future__ import annotations

import json
from datetime import UTC, datetime
from typing import Any

from parity import ParityAcceptance
from numeric_metrics import NumericMetricsMixin

NODE_ROOT = "node:ordinary-node/root"
NODE_PROCESS = "node:ordinary-node/process:application"
PROMETHEUS_TARGET = "monitoring-target"
NODE_SERVICE = "node-local-runner"
PROMETHEUS_SERVICE = "prometheus-local-runner"

FILE_SCRIPT = """
import json, os, stat, sys, time
from pathlib import Path
path = Path('/node/ordinary-export.csv')
mode = sys.argv[1]
if mode == 'missing':
    path.unlink(missing_ok=True)
elif mode in {'healthy', 'empty', 'stale', 'unreadable'}:
    path.write_text('' if mode == 'empty' else 'id,value\\n1,42\\n')
    os.chown(path, 65532, 65532)
    path.chmod(0 if mode == 'unreadable' else 0o644)
    if mode == 'stale':
        old = time.time() - 10800
        os.utime(path, (old, old))
else:
    raise ValueError('Unknown owned file mutation')
metadata = path.stat() if path.exists() else None
print(json.dumps({'mode':mode, 'path':str(path), 'size':metadata.st_size if metadata else None,
                  'permissions':oct(stat.S_IMODE(metadata.st_mode)) if metadata else None,
                  'owner_uid':metadata.st_uid if metadata else None,
                  'owner_gid':metadata.st_gid if metadata else None,
                  'modified_at':metadata.st_mtime if metadata else None}))
"""

PID_SCRIPT = """
import json, sys
from pathlib import Path
mode = sys.argv[1]
path = Path('/node/application.pid')
identity = json.loads(Path('/node/process.json').read_text())
if mode == 'invalid':
    path.write_text('not a decimal PID\\n')
elif mode == 'healthy':
    path.write_text(str(identity['pid']) + '\\n')
else:
    raise ValueError('Unknown owned PID-file mutation')
path.chmod(0o644)
print(json.dumps({'mode':mode, 'process':identity, 'pid_file':path.read_text()}))
"""


class ConsumerAcceptance(NumericMetricsMixin, ParityAcceptance):
    def __init__(self) -> None:
        super().__init__()
        self.env.update(
            MONDEK_CONSUMER="",
            MONDEK_LOCAL_FILE_ID="export",
        )
        self.file_target = "node:ordinary-node/file:export"
        self.initial_ids: dict[str, str] = {}
        self.active_scenario: str | None = None

    def cohort(
        self,
        targets: tuple[str, ...] | None = None,
        after: dict[str, str] | None = None,
        after_time: datetime | None = None,
    ) -> dict[str, dict[str, Any]] | bool:
        """Require measured healthy rows, optionally a new execution from each."""
        targets = targets or (
            NODE_ROOT,
            self.file_target,
            NODE_PROCESS,
            PROMETHEUS_TARGET,
        )
        rows = {
            row["target"]["key"]: row for row in self.streams(page_size=100)["items"]
        }
        if not all(target in rows for target in targets):
            return False
        selected = {target: rows[target] for target in targets}
        for target, row in selected.items():
            current = row["current"]
            if current.get("knowledge") != "fresh" or current.get("health") != "OK":
                return False
            if after and current.get("observation_id") == after.get(target):
                return False
            if after_time:
                for key in ("evaluated_at", "confirmed_evaluated_at"):
                    try:
                        evaluated = datetime.fromisoformat(current[key])
                    except (KeyError, TypeError, ValueError):
                        return False
                    if evaluated.tzinfo is None or evaluated <= after_time:
                        return False
        return selected

    def capture(self, name: str, targets: tuple[str, ...] | None = None) -> dict:
        details = (
            {target: self.detail(self.stream(target)) for target in targets}
            if targets
            else {}
        )
        captured = {
            "captured_at": datetime.now(UTC).isoformat(),
            "overview": self.overview(),
            "streams": self.streams(page_size=100),
            "details": details,
        }
        (self.output / f"{name}.json").write_text(json.dumps(captured, indent=2))
        return captured

    def clean_start(self) -> dict[str, Any]:
        # Explicit service selection starts dependencies only, never the default
        # four-runner demonstration or the capacity/bulk consumers.
        self.compose(
            "--profile",
            "starters",
            "up",
            "--build",
            "--detach",
            "--wait",
            "--wait-timeout",
            "180",
            NODE_SERVICE,
            PROMETHEUS_SERVICE,
        )
        baseline = self.eventually(
            "the two installed starters establish four healthy measurements",
            self.cohort,
            timeout=180,
        )
        overview = self.overview()
        assert overview["runner_count"] == 2
        assert overview["coverage"]["expected_count"] == 4
        assert self.streams()["total"] == 4
        running = self.compose("ps", "--services", "--status", "running", capture=True)
        assert set(running.splitlines()) == {
            "postgres",
            "controller",
            "target",
            "prometheus",
            "node-a-target",
            NODE_SERVICE,
            PROMETHEUS_SERVICE,
        }, running
        assert baseline[NODE_ROOT]["source_id"] == "node-local"
        assert baseline[PROMETHEUS_TARGET]["source_id"] == "prometheus-local"
        assert baseline[PROMETHEUS_TARGET]["source_key"] == "prometheus-up"
        assert (
            baseline[NODE_ROOT]["runner_id"] != baseline[PROMETHEUS_TARGET]["runner_id"]
        )
        self.initial_ids = {target: row["id"] for target, row in baseline.items()}
        self.capture("01-initial", tuple(baseline))
        return {
            "runners": overview["runner_count"],
            "fresh_results": 4,
            "running_services": sorted(running.splitlines()),
            "stream_ids": self.initial_ids,
        }

    def installed_local_commands(self) -> dict[str, Any]:
        before = self.node_journal(NODE_SERVICE)["status"]
        installed = json.loads(
            self.compose(
                "exec",
                "-T",
                NODE_SERVICE,
                "python",
                "-c",
                "import importlib.metadata as m,importlib.util as u,json,sys; "
                "print(json.dumps({'python':sys.executable, 'sdk':u.find_spec('mondek_runner').origin, "
                "'consumer':u.find_spec('mondek_examples.node_local').origin, "
                "'sdk_version':m.version('mondek'), "
                "'consumer_version':m.version('mondek-local-examples')}))",
                capture=True,
            )
        )
        assert "/site-packages/" in installed["sdk"]
        assert "/site-packages/" in installed["consumer"]
        validated = json.loads(
            self.compose(
                "exec",
                "-T",
                NODE_SERVICE,
                "mondek-runner",
                "validate",
                "--consumer",
                "mondek_examples.node_local:app",
                capture=True,
                timeout=60,
            )
        )
        assert validated["source_id"] == "node-local"
        assert {row["key"] for row in validated["checks"]} == {
            "root-filesystem",
            "configured-file",
            "configured-process",
        }
        serialized = json.dumps(validated)
        assert "/node/ordinary-export.csv" not in serialized
        assert "/node/application.pid" not in serialized
        ran = json.loads(
            self.compose(
                "exec",
                "-T",
                NODE_SERVICE,
                "mondek-runner",
                "run",
                "--consumer",
                "mondek_examples.node_local:app",
                "--all",
                "--results",
                "--concurrency",
                "1",
                capture=True,
                timeout=60,
            )
        )
        assert ran["complete"] is True
        assert ran["summary"]["checks"] == 3
        assert ran["summary"]["complete_checks"] == 3
        assert ran["result_evidence"]["included_results"] == 3
        assert ran["result_evidence"]["omitted_results"] == 0
        assert all(row["results"][0]["source_at"] for row in ran["checks"])
        assert ran["summary"]["measured_health"] == {
            "OK": 3,
            "WARN": 0,
            "CRIT": 0,
            "UNKNOWN": 0,
        }
        after = self.node_journal(NODE_SERVICE)["status"]
        identity_fields = ("installation_id", "session_id", "boot")
        assert {key: before[key] for key in identity_fields} == {
            key: after[key] for key in identity_fields
        }, "One-shot commands changed the persistent runner identity/session"
        evidence = {
            "installed": installed,
            "validation": validated,
            "local_run": ran,
            "journal_before": before,
            "journal_after": after,
        }
        (self.output / "02-installed-cli.json").write_text(
            json.dumps(evidence, indent=2)
        )
        return {
            "validated_checks": 3,
            "real_local_executions": 3,
            "installed": installed,
            "persistent_identity_unchanged": True,
        }

    def file_mode(self, mode: str) -> dict[str, Any]:
        result = json.loads(
            self.compose(
                "exec",
                "-T",
                "--user",
                "0",
                "node-a-target",
                "python",
                "-c",
                FILE_SCRIPT,
                mode,
                capture=True,
                timeout=10,
            )
        )
        result["completed_at"] = datetime.now(UTC).isoformat()
        if mode != "missing":
            assert result["owner_uid"] == result["owner_gid"] == 65532
        return result

    def pid_mode(self, mode: str) -> dict[str, Any]:
        result = json.loads(
            self.compose(
                "exec",
                "-T",
                "--user",
                "0",
                "node-a-target",
                "python",
                "-c",
                PID_SCRIPT,
                mode,
                capture=True,
                timeout=10,
            )
        )
        result["completed_at"] = datetime.now(UTC).isoformat()
        return result

    @staticmethod
    def observed(rows: dict[str, dict[str, Any]]) -> dict[str, str]:
        return {
            target: row["current"]["observation_id"] for target, row in rows.items()
        }

    def new_failure(self, target: str, previous: dict, text: str) -> dict | bool:
        row = self.fresh(target, "CRIT")
        return (
            row
            if (
                row
                and row["current"]["observation_id"]
                != previous["current"]["observation_id"]
                and text.lower() in row["current"]["summary"].lower()
            )
            else False
        )

    def unknown(self, target: str, previous: dict, text: str) -> dict | bool:
        row = self.stream(target)
        current = row["current"]
        return (
            row
            if (
                current["observation_id"] != previous["current"]["observation_id"]
                and current["knowledge"] == "unavailable"
                and current["reported_health"] == "UNKNOWN"
                and current.get("reported_source_at") is None
                and text.lower() in current.get("execution_summary", "").lower()
            )
            else False
        )

    def unknown_evidence(self, row: dict) -> dict:
        """Check the newly admitted raw result, not its retained display health."""
        observation = next(
            item
            for item in self.detail(row)["evidence"]
            if item["id"] == row["current"]["observation_id"]
        )
        result = next(
            item
            for item in observation["payload"]["results"]
            if item["key"] == row["result_key"]
        )
        assert result["health"] == "UNKNOWN"
        assert result["source_at"] is None
        return observation

    def incident_opened(self, row: dict) -> dict:
        return self.eventually(
            "failure opens the affected result incident",
            lambda: next(
                (
                    incident
                    for incident in self.detail(row)["incidents"]
                    if incident["status"] == "open"
                ),
                None,
            ),
        )

    def measured_recovery(self, target: str, failed: dict, incident: dict) -> dict:
        recovered = self.eventually(
            "same result has a new healthy measurement",
            lambda: (
                row
                if (
                    (row := self.fresh(target))
                    and row["current"]["observation_id"]
                    != failed["current"]["observation_id"]
                )
                else False
            ),
        )
        assert recovered["id"] == failed["id"]
        closed = self.eventually(
            "the exact incident closes with linked measured evidence",
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
        details = self.detail(recovered)
        closing = next(
            item
            for item in details["evidence"]
            if item["id"] == closed["closing_observation_id"]
        )
        assert any(
            result["key"] == recovered["result_key"] and result["health"] == "OK"
            for result in closing["payload"]["results"]
        )
        return {"stream": recovered, "incident": closed}

    def file_failures(self) -> dict[str, Any]:
        results = []
        try:
            for mode, text in (
                ("missing", "missing"),
                ("empty", "below minimum size"),
                ("stale", "older than critical"),
            ):
                before = self.eventually(
                    "healthy node before file mutation", self.cohort
                )
                previous = before[self.file_target]
                mutation = self.file_mode(mode)
                failed = self.eventually(
                    f"ordinary file {mode} produces fresh measured failure",
                    lambda: self.new_failure(self.file_target, previous, text),
                )
                assert failed["id"] == self.initial_ids[self.file_target]
                incident = self.incident_opened(failed)
                self.eventually(
                    "unaffected root/process checks keep collecting",
                    lambda: self.cohort(
                        (NODE_ROOT, NODE_PROCESS),
                        self.observed(before),
                        datetime.fromisoformat(mutation["completed_at"]),
                    ),
                )
                if mode == "stale":
                    source = datetime.fromisoformat(
                        failed["current"]["source_at"]
                    ).timestamp()
                    assert source - mutation["modified_at"] > 7200
                self.capture(f"03-file-{mode}", (self.file_target,))
                self.file_mode("healthy")
                recovery = self.measured_recovery(self.file_target, failed, incident)
                results.append(
                    {
                        "mutation": mutation,
                        "failure": failed,
                        "closed_incident": recovery["incident"],
                    }
                )

            before = self.eventually(
                "healthy file before permission change", self.cohort
            )
            mutation = self.file_mode("unreadable")
            unavailable = self.eventually(
                "unreadable ordinary file is unknown coverage with retained health",
                lambda: self.unknown(
                    self.file_target, before[self.file_target], "cannot read"
                ),
            )
            assert unavailable["id"] == self.initial_ids[self.file_target]
            assert unavailable["current"]["health"] == "OK"
            assert (
                unavailable["current"]["confirmed_observation_id"]
                != unavailable["current"]["observation_id"]
            )
            raw_unknown = self.unknown_evidence(unavailable)
            assert self.overview()["coverage"]["expected_count"] == 4
            self.eventually(
                "permissions do not stop the other node checks",
                lambda: self.cohort(
                    (NODE_ROOT, NODE_PROCESS),
                    self.observed(before),
                    datetime.fromisoformat(mutation["completed_at"]),
                ),
            )
            self.capture("03-file-unreadable", (self.file_target,))
            self.file_mode("healthy")
            self.eventually(
                "readable ordinary file has fresh healthy evidence", self.cohort
            )
            results.append(
                {
                    "mutation": mutation,
                    "unavailable": unavailable,
                    "unknown_observation": raw_unknown,
                }
            )
            return {
                "cases": results,
                "same_logical_file_stream": self.initial_ids[self.file_target],
            }
        finally:
            self.file_mode("healthy")

    def process_failures(self) -> dict[str, Any]:
        before = self.eventually("healthy checks before process stop", self.cohort)
        original = self.pid_mode("healthy")
        try:
            self.node_mode("node-a", process="stopped")
            stopped_at = datetime.now(UTC)
            failed = self.eventually(
                "actual terminated process produces a fresh failure",
                lambda: self.new_failure(
                    NODE_PROCESS, before[NODE_PROCESS], "not running"
                ),
            )
            incident = self.incident_opened(failed)
            self.eventually(
                "file and filesystem continue while process is stopped",
                lambda: self.cohort(
                    (NODE_ROOT, self.file_target), self.observed(before), stopped_at
                ),
            )
            self.capture("04-process-stopped", (NODE_PROCESS,))
            self.node_mode("node-a", process="running")
            restarted = self.pid_mode("healthy")
            assert restarted["process"]["pid"] != original["process"]["pid"]
            recovery = self.measured_recovery(NODE_PROCESS, failed, incident)
            before = self.eventually(
                "healthy process before PID-file corruption", self.cohort
            )
            malformed = self.pid_mode("invalid")
            unknown = self.eventually(
                "invalid decimal PID file is unknown rather than process absence",
                lambda: self.unknown(NODE_PROCESS, before[NODE_PROCESS], "PID file"),
            )
            assert unknown["current"]["health"] == "OK"
            assert unknown["id"] == self.initial_ids[NODE_PROCESS]
            assert self.overview()["coverage"]["expected_count"] == 4
            raw_unknown = self.unknown_evidence(unknown)
            self.eventually(
                "malformed PID input does not stop file or filesystem collection",
                lambda: self.cohort(
                    (NODE_ROOT, self.file_target),
                    self.observed(before),
                    datetime.fromisoformat(malformed["completed_at"]),
                ),
            )
            self.capture("04-process-invalid-pid", (NODE_PROCESS,))
            restored = self.pid_mode("healthy")
            assert restored["process"] == restarted["process"]
            self.eventually(
                "the same live process is measured after PID repair", self.cohort
            )
            return {
                "stopped_at": stopped_at.isoformat(),
                "original_process": original["process"],
                "restarted_process": restarted["process"],
                "closed_incident": recovery["incident"],
                "invalid_pid_file": malformed,
                "unknown": unknown,
                "unknown_observation": raw_unknown,
                "restored_pid_file": restored,
            }
        finally:
            self.node_mode("node-a", process="running")
            self.pid_mode("healthy")

    def file_rebinding(self) -> dict[str, Any]:
        before = self.eventually(
            "healthy checks before source binding change", self.cohort
        )
        old_target = self.file_target
        try:
            self.file_mode("empty")
            failed = self.eventually(
                "the original logical file fails before rebinding",
                lambda: self.new_failure(
                    old_target, before[old_target], "below minimum size"
                ),
            )
            incident = self.incident_opened(failed)
            self.env["MONDEK_LOCAL_FILE_ID"] = "relocated-export"
            self.compose(
                "--profile", "starters", "up", "--detach", "--no-deps", NODE_SERVICE
            )
            self.file_target = "node:ordinary-node/file:relocated-export"
            new = self.eventually(
                "new source target has its own failing result",
                lambda: self.fresh(self.file_target, "CRIT"),
                timeout=90,
            )
            assert new["id"] != failed["id"]
            assert new["assignment_id"] == failed["assignment_id"]
            assert new["runner_id"] == failed["runner_id"]
            historical = self.eventually(
                "the replaced target becomes explicitly historical",
                lambda: (
                    detail
                    if (detail := self.detail(failed))["stream"]["retired"]
                    else False
                ),
            )
            assert historical["stream"]["target"]["key"] == old_target
            assert historical["stream"]["current"]["health"] == "CRIT"
            closed = next(
                row for row in historical["incidents"] if row["id"] == incident["id"]
            )
            assert (
                closed["status"] == "closed"
                and closed["closure_reason"] == "source_removed"
            )
            assert closed["closing_observation_id"] is None
            new_incident = self.incident_opened(new)
            self.file_mode("healthy")
            recovery = self.measured_recovery(self.file_target, new, new_incident)
            cohort = self.eventually(
                "all four results recover after rebinding", self.cohort
            )
            for target in (NODE_ROOT, NODE_PROCESS):
                assert cohort[target]["id"] == self.initial_ids[target]
            assert self.streams()["total"] == 4
            assert self.detail(failed)["stream"]["current"]["health"] == "CRIT"
            evidence = {"before": failed, "historical": historical, "new": recovery}
            (self.output / "05-source-rebinding.json").write_text(
                json.dumps(evidence, indent=2)
            )
            return {
                "historical_stream_id": failed["id"],
                "new_stream_id": new["id"],
                "old_incident": closed,
                "new_incident": recovery["incident"],
                "unchanged_sibling_ids": {
                    key: cohort[key]["id"] for key in (NODE_ROOT, NODE_PROCESS)
                },
            }
        finally:
            self.file_mode("healthy")

    def prometheus_outage(self) -> dict[str, Any]:
        before = self.eventually(
            "healthy starters before scrape-target outage", self.cohort
        )
        try:
            self.compose("stop", "target")
            stopped_at = datetime.now(UTC)
            failed = self.eventually(
                "a real failed Prometheus scrape is fresh CRIT",
                lambda: self.new_failure(
                    PROMETHEUS_TARGET, before[PROMETHEUS_TARGET], "scrape failed"
                ),
            )
            assert self.request("/health")["status"] == "ok"
            assert failed["id"] == self.initial_ids[PROMETHEUS_TARGET]
            assert failed["current"]["value"] == 0
            assert failed["current"]["source_at"]
            incident = self.incident_opened(failed)
            surviving = self.eventually(
                "direct controller transport keeps all node checks measuring",
                lambda: self.cohort(
                    (NODE_ROOT, self.file_target, NODE_PROCESS),
                    self.observed(before),
                    stopped_at,
                ),
            )
            # Read real Prometheus history independently of Mondek, at the
            # recorded source time. Later scrapes must not change this comparison.
            source = datetime.fromisoformat(failed["current"]["source_at"]).timestamp()
            scrape_history = json.loads(
                self.compose(
                    "exec",
                    "-T",
                    PROMETHEUS_SERVICE,
                    "python",
                    "-c",
                    "import json,sys,urllib.parse,urllib.request; "
                    "query=urllib.parse.urlencode({'query':'up{instance=\"target:8080\"}[30s]', 'time':sys.argv[1]}); "
                    "response=urllib.request.urlopen('http://prometheus:9090/api/v1/query?'+query,timeout=5); "
                    "print(json.dumps(json.load(response)))",
                    str(source + 0.001),
                    capture=True,
                    timeout=10,
                )
            )
            assert scrape_history["status"] == "success"
            assert any(
                abs(float(sample_at) - source) < 0.001 and float(value) == 0
                for series in scrape_history["data"]["result"]
                for sample_at, value in series["values"]
            ), "Mondek did not preserve the actual failed scrape's source time"
            (self.output / "06-prometheus-source-samples.json").write_text(
                json.dumps(scrape_history, indent=2)
            )
            self.capture("06-real-scrape-failure", (PROMETHEUS_TARGET,))
            self.compose("start", "target")
            recovery = self.measured_recovery(PROMETHEUS_TARGET, failed, incident)
            assert (
                "scrape succeeded" in recovery["stream"]["current"]["summary"].lower()
            )
            assert recovery["stream"]["current"]["value"] == 1
            return {
                "stopped_at": stopped_at.isoformat(),
                "failed_scrape": failed,
                "closed_incident": recovery["incident"],
                "node_measurements_during_target_outage": self.observed(surviving),
                "controller_direct_transport_stayed_available": True,
            }
        finally:
            self.compose("start", "target")

    def final_coverage(self) -> dict[str, Any]:
        rows = self.eventually("four healthy fresh results at completion", self.cohort)
        assert self.overview()["runner_count"] == 2
        assert self.overview()["coverage"]["expected_count"] == 4
        for target in (NODE_ROOT, NODE_PROCESS, PROMETHEUS_TARGET):
            assert rows[target]["id"] == self.initial_ids[target]
        self.capture("08-final", tuple(rows))
        return {
            "fresh_results": 4,
            "current_stream_ids": {key: row["id"] for key, row in rows.items()},
        }

    def restarted_prometheus(
        self, previous: dict, after_time: datetime, discovery_failed: bool
    ) -> dict | bool:
        rows = self.cohort(after_time=after_time)
        if not rows:
            return False
        row = rows[PROMETHEUS_TARGET]
        current = row["current"]
        if (
            current["session_id"] == previous["current"]["session_id"]
            or current["confirmed_session_id"] != current["session_id"]
        ):
            return False
        runner = next(
            item
            for item in self.request("/api/v1/runners")["items"]
            if item["id"] == row["runner_id"]
        )
        if runner["session_id"] != current["session_id"]:
            return False
        diagnostic = runner["status"].get("diagnostic") or ""
        if ("discovery failed" in diagnostic) != discovery_failed:
            return False
        for field in ("id", "assignment_id", "runner_id", "source_revision"):
            assert row[field] == previous[field], (
                f"Failed deployment changed accepted {field}"
            )
        assert current["generation"] == previous["current"]["generation"]
        assert self.overview()["coverage"]["expected_count"] == 4
        return {"rows": rows, "runner": runner}

    def failed_construction(self) -> dict[str, Any]:
        before = self.eventually(
            "healthy starters before invalid source settings", self.cohort
        )
        previous = before[PROMETHEUS_TARGET]
        override = self.output / "invalid-prometheus-settings.json"
        override.write_text(
            json.dumps(
                {
                    "services": {
                        PROMETHEUS_SERVICE: {
                            "environment": {"MONDEK_PROMETHEUS_SETTINGS": "{broken"}
                        }
                    }
                },
                indent=2,
            )
        )
        try:
            self.compose(
                "-f",
                str(override),
                "--profile",
                "starters",
                "up",
                "--detach",
                "--no-deps",
                PROMETHEUS_SERVICE,
            )
            failed_at = datetime.now(UTC)
            retained = self.eventually(
                "invalid source JSON is visible while frozen accepted checks collect in the new session",
                lambda: self.restarted_prometheus(previous, failed_at, True),
                timeout=90,
            )
            self.capture("07-failed-construction", (PROMETHEUS_TARGET,))
            self.compose(
                "--profile",
                "starters",
                "up",
                "--detach",
                "--no-deps",
                PROMETHEUS_SERVICE,
            )
            restored_at = datetime.now(UTC)
            restored = self.eventually(
                "restored source settings clear discovery failure and collect in another new session",
                lambda: self.restarted_prometheus(
                    retained["rows"][PROMETHEUS_TARGET], restored_at, False
                ),
                timeout=90,
            )
            evidence = {
                "failed_at": failed_at.isoformat(),
                "restored_at": restored_at.isoformat(),
                "before": previous,
                "retained": retained,
                "restored": restored,
            }
            (self.output / "07-construction-recovery.json").write_text(
                json.dumps(evidence, indent=2)
            )
            return evidence
        finally:
            self.compose(
                "--profile",
                "starters",
                "up",
                "--detach",
                "--no-deps",
                PROMETHEUS_SERVICE,
            )

    def local_query_batch(self) -> dict[str, Any]:
        outcome = json.loads(
            self.compose(
                "exec",
                "-T",
                PROMETHEUS_SERVICE,
                "mondek-runner",
                "run",
                "--consumer",
                "mondek_examples.prometheus_multi:app",
                "--all",
                "--results",
                "--concurrency",
                "1",
                capture=True,
                timeout=60,
            )
        )
        assert outcome["source_id"] == "prometheus-groups-example"
        assert outcome["complete"] and outcome["summary"]["checks"] == 2
        assert outcome["summary"]["complete_checks"] == 2
        assert {item["key"] for item in outcome["checks"]} == {
            "scrape-health",
            "service-readiness",
        }
        assert sum(item["received_results"] for item in outcome["checks"]) == 3
        assert outcome["result_evidence"]["included_results"] == 3
        assert outcome["result_evidence"]["omitted_results"] == 0
        return outcome

    def local_query_results(
        self, batch: dict, critical: bool, after_time: datetime | None = None
    ) -> dict:
        executions = {}
        results = {}
        for outcome in batch["checks"]:
            assert outcome["collection"] == "complete", outcome
            assert outcome["omitted_results"] == 0
            executions[outcome["key"]] = outcome
            for result in outcome["results"]:
                assert result["key"] not in results
                results[result["key"]] = result
                source = datetime.fromisoformat(result["source_at"])
                assert source.tzinfo is not None
                assert 0 <= (datetime.now(UTC) - source).total_seconds() < 15
                if after_time:
                    assert source > after_time
        assert {key: result["health"] for key, result in results.items()} == {
            "monitoring-target": "OK",
            "primary-service": "CRIT" if critical else "OK",
            "secondary-service": "OK",
        }
        assert "scrape succeeded" in results["monitoring-target"]["summary"]
        assert ("not ready" if critical else "is ready") in results["primary-service"][
            "summary"
        ]
        return executions

    @staticmethod
    def batch_collected_after(batch: dict, boundary: datetime) -> bool:
        # A later query in a batch can cross a scrape boundary. Require every
        # retained result from that original batch to be newer than the fault.
        results = [result for check in batch["checks"] for result in check["results"]]
        return bool(results) and all(
            result["source_at"] is not None
            and datetime.fromisoformat(result["source_at"]) > boundary
            for result in results
        )

    def multiple_queries(self) -> dict[str, Any]:
        """Real local CLI/HTTP execution; these one-shots do not register new checks."""
        before = self.node_journal(PROMETHEUS_SERVICE)["status"]
        healthy_counts = {"OK": 3, "WARN": 0, "CRIT": 0, "UNKNOWN": 0}
        failed_counts = {"OK": 2, "WARN": 0, "CRIT": 1, "UNKNOWN": 0}
        initial = self.local_query_batch()
        assert initial["summary"]["measured_health"] == healthy_counts
        initial_raw = self.local_query_results(initial, False)
        try:
            self.mode(ready=False)
            failed_at = datetime.now(UTC)
            failed = self.eventually(
                "two real query groups complete with only primary readiness critical",
                lambda: (
                    result
                    if (result := self.local_query_batch())["summary"][
                        "measured_health"
                    ]
                    == failed_counts
                    and self.batch_collected_after(result, failed_at)
                    else False
                ),
                timeout=90,
            )
            failed_raw = self.local_query_results(failed, True, failed_at)
            self.eventually(
                "one-shot failures do not interrupt registered starter coverage",
                lambda: self.cohort(after_time=failed_at),
            )
            self.mode(ready=True)
            recovered_at = datetime.now(UTC)
            recovered = self.eventually(
                "all three real local query results recover",
                lambda: (
                    result
                    if (result := self.local_query_batch())["summary"][
                        "measured_health"
                    ]
                    == healthy_counts
                    and self.batch_collected_after(result, recovered_at)
                    else False
                ),
                timeout=90,
            )
            recovered_raw = self.local_query_results(recovered, False, recovered_at)
            after = self.node_journal(PROMETHEUS_SERVICE)["status"]
            identity = ("installation_id", "session_id", "boot")
            assert {key: before[key] for key in identity} == {
                key: after[key] for key in identity
            }
            assert self.overview()["runner_count"] == 2
            assert self.overview()["coverage"]["expected_count"] == 4
            evidence = {
                "scope": "installed local CLI and real Prometheus HTTP, without controller ingestion",
                "failed_at": failed_at.isoformat(),
                "recovered_at": recovered_at.isoformat(),
                "initial": initial,
                "initial_results": initial_raw,
                "failed": failed,
                "failed_results": failed_raw,
                "recovered": recovered,
                "recovered_results": recovered_raw,
                "journal_before": before,
                "journal_after": after,
            }
            (self.output / "09-local-query-groups.json").write_text(
                json.dumps(evidence, indent=2)
            )
            return evidence
        finally:
            self.mode(ready=True)

    def multiple_node_resources(self) -> dict[str, Any]:
        service = "node-multi-runner"
        targets = (
            "node:ordinary-multi/filesystem:root",
            "node:ordinary-multi/file:primary-export",
            "node:ordinary-multi/file:secondary-export",
            "node:ordinary-multi/process:application",
        )
        all_targets = (
            NODE_ROOT,
            self.file_target,
            NODE_PROCESS,
            PROMETHEUS_TARGET,
            *targets,
        )
        self.compose(
            "--profile",
            "starters",
            "up",
            "--build",
            "--detach",
            "--wait",
            "--wait-timeout",
            "180",
            service,
        )
        baseline = self.eventually(
            "a third runner measures four explicitly named node resources",
            lambda: self.cohort(all_targets),
            timeout=180,
        )
        assert self.overview()["runner_count"] == 3
        assert self.overview()["coverage"]["expected_count"] == 8
        assert len({baseline[target]["assignment_id"] for target in targets}) == 4
        assert len({baseline[target]["runner_id"] for target in targets}) == 1
        for target in targets:
            assert baseline[target]["source_id"] == "node-resources"
        for target in (NODE_ROOT, NODE_PROCESS, PROMETHEUS_TARGET):
            assert baseline[target]["id"] == self.initial_ids[target]
        configs = {
            target: self.assignment(baseline[target]["assignment_id"])
            for target in targets
        }
        assert (
            configs[targets[0]]["parameter_contract"]
            == "root-filesystem.used-percent.v1"
        )
        assert all(
            configs[target]["parameter_contract"] == "regular-file.size-and-age.v1"
            for target in targets[1:3]
        )
        assert configs[targets[3]]["params_owner"] == "source"

        def mutate(healthy: bool) -> datetime:
            self.compose(
                "exec",
                "-T",
                "--user",
                "0",
                "node-a-target",
                "python",
                "-c",
                "import os,sys; from pathlib import Path; "
                "path=Path('/node/secondary-export.csv'); "
                "path.write_text('id,value\\n2,84\\n' if sys.argv[1]=='healthy' else ''); "
                "path.chmod(0o644); os.chown(path,65532,65532)",
                "healthy" if healthy else "empty",
            )
            return datetime.now(UTC)

        try:
            failed_at = mutate(False)
            failed = self.eventually(
                "only the second explicit file resource has a new measured size failure",
                lambda: self.new_failure(
                    targets[2], baseline[targets[2]], "below minimum size"
                ),
            )
            assert failed["id"] == baseline[targets[2]]["id"]
            incident = self.incident_opened(failed)
            peers = self.eventually(
                "the other seven resources keep measuring after the file mutation",
                lambda: self.cohort(
                    tuple(target for target in all_targets if target != targets[2]),
                    after_time=failed_at,
                ),
            )
            for target, row in peers.items():
                assert row["id"] == baseline[target]["id"]
            self.capture("10-explicit-resource-failure", targets)
            restored_at = mutate(True)
            recovery = self.measured_recovery(targets[2], failed, incident)
            recovered = self.eventually(
                "all eight resources measure healthy after file repair",
                lambda: self.cohort(all_targets, after_time=restored_at),
            )

            before_restart = self.node_journal(service)["status"]
            self.compose("restart", service)
            restarted_at = datetime.now(UTC)

            def restarted() -> dict | bool:
                rows = self.cohort(all_targets, after_time=restarted_at)
                if not rows:
                    return False
                for target in targets:
                    current = rows[target]["current"]
                    if (
                        current["session_id"]
                        == recovered[target]["current"]["session_id"]
                        or current["confirmed_session_id"] != current["session_id"]
                    ):
                        return False
                    assert rows[target]["id"] == baseline[target]["id"]
                return rows

            final = self.eventually(
                "all explicit resource identities survive runner restart",
                restarted,
                timeout=90,
            )
            after_restart = self.node_journal(service)["status"]
            assert after_restart["installation_id"] == before_restart["installation_id"]
            assert after_restart["boot"] == before_restart["boot"] + 1
            assert after_restart["dropped"] == before_restart["dropped"] == 0
            assert self.overview()["runner_count"] == 3
            assert self.overview()["coverage"]["expected_count"] == 8
            self.capture("10-explicit-resources-final", all_targets)
            return {
                "runner_count": 3,
                "fresh_results": 8,
                "failed_at": failed_at.isoformat(),
                "restored_at": restored_at.isoformat(),
                "failure": failed,
                "recovery": recovery,
                "final_ids": {target: row["id"] for target, row in final.items()},
                "journal_before": before_restart,
                "journal_after": after_restart,
            }
        finally:
            mutate(True)

    def finish(self, success: bool, failure: dict | None) -> None:
        try:
            capture_errors = []
            for name, read in (
                ("overview", self.overview),
                ("snapshot", self.snapshot),
                ("streams", lambda: self.streams(page_size=100)),
                ("receipts", self.records),
            ):
                try:
                    (self.output / f"{name}.json").write_text(
                        json.dumps(read(), indent=2)
                    )
                except Exception as error:
                    capture_errors.append({"artifact": name, "error": str(error)})
            (self.output / "consumer-results.json").write_text(
                json.dumps(
                    {
                        "success": success,
                        "finished_at": datetime.now(UTC).isoformat(),
                        "project": self.project,
                        "steps": self.steps,
                        "failure": failure,
                        "capture_errors": capture_errors,
                    },
                    indent=2,
                )
            )
        finally:
            try:
                self.compose(
                    "--profile", "starters", "logs", "--no-color", "--tail", "250"
                )
            finally:
                try:
                    self.compose(
                        "--profile", "starters", "down", "--volumes", "--remove-orphans"
                    )
                finally:
                    self.log.close()

    def run(self) -> None:
        print(
            f"Consumer project: {self.project}; UI: {self.base}; evidence: {self.output}",
            flush=True,
        )
        success = False
        failure = None
        try:
            for label, function in (
                (
                    "two installed starters and four independent measurements",
                    self.clean_start,
                ),
                (
                    "installed CLI validation and real local runs preserve runner identity",
                    self.installed_local_commands,
                ),
                (
                    "two installed query groups measure independent real Prometheus results through local CLI",
                    self.multiple_queries,
                ),
                (
                    "ordinary file missing, size, age and permission failures",
                    self.file_failures,
                ),
                (
                    "real process stop/restart and malformed ordinary PID file",
                    self.process_failures,
                ),
                (
                    "source target rebinding preserves old failure history",
                    self.file_rebinding,
                ),
                (
                    "real Prometheus scrape failure with direct controller transport",
                    self.prometheus_outage,
                ),
                (
                    "failed source construction keeps frozen monitoring through restart and recovery",
                    self.failed_construction,
                ),
                (
                    "all four current starter results finish fresh and healthy",
                    self.final_coverage,
                ),
                (
                    "multiple explicit node resources isolate failure and preserve identity through restart",
                    self.multiple_node_resources,
                ),
                (
                    "real numeric Prometheus thresholds, original sample age and measured recovery",
                    self.numeric_metric,
                ),
            ):
                self.active_scenario = label
                self.run_step(label, function)
            success = True
        except Exception as error:
            failure = {
                "scenario": self.active_scenario,
                "type": type(error).__name__,
                "message": str(error),
            }
            raise
        finally:
            self.finish(success, failure)
            print(f"Evidence: {self.output}", flush=True)
        print("All real installed-consumer starter scenarios passed.", flush=True)


if __name__ == "__main__":
    ConsumerAcceptance().run()
