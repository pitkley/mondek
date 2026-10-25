#!/usr/bin/env python3
# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Exercise the packaged Linux runner, Phoenix, PostgreSQL and real local HTTP delivery."""

from __future__ import annotations

import copy
from ci_images import run_compose
import json
import os
import socket
import subprocess
import time
import urllib.error
import urllib.request
import uuid
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Callable

from text_protocol import TextProtocolMixin

ROOT = Path(__file__).resolve().parents[2]


def reconcile_spool_samples(samples: list[dict], evidence: list[dict]) -> dict:
    """Check captured payloads without assuming a full spool survives overflow."""
    assert samples, "No runner spool was sampled"
    captured: dict[str, dict] = {}
    for sample in samples:
        for report in sample["reports"]:
            previous = captured.setdefault(report["id"], report)
            assert previous == report, (
                "A buffered identity changed between journal reads"
            )

    admitted = {item["id"]: item for item in evidence if item["id"] in captured}
    assert admitted, "No captured in-spool report was observed committing"
    outage_ids = {
        report["id"]
        for sample in samples
        if sample["phase"] in {"before_controller_restart", "starting_controller"}
        for report in sample["reports"]
    }
    preserved_outage_ids = outage_ids & admitted.keys()
    assert preserved_outage_ids, (
        "No report sampled before controller readiness was observed committing"
    )
    for id_, item in admitted.items():
        assert item["payload"] == captured[id_], (
            "Reconnect changed original buffered evidence"
        )
        assert datetime.fromisoformat(item["received_at"]) > datetime.fromisoformat(
            captured[id_]["evaluated_at"]
        ), "A buffered report lost its original execution age"

    final = samples[-1]
    remaining = {report["id"] for report in final["reports"]}
    missing = set(captured) - set(admitted) - remaining
    loss_growth = final["status"]["dropped"] - samples[0]["status"]["dropped"]
    assert loss_growth >= len(missing), (
        "Captured reports disappeared without reported loss"
    )
    for id_ in missing:
        loss_at = final["status"].get("loss_at")
        assert loss_at and datetime.fromisoformat(
            captured[id_]["evaluated_at"]
        ) <= datetime.fromisoformat(loss_at), (
            "A missing captured report is newer than the reported loss"
        )

    return {
        "sampled_reports": len(captured),
        "preserved_buffered_reports": len(admitted),
        "admitted_ids": sorted(admitted),
        "admitted_ids_sampled_before_controller_ready": sorted(preserved_outage_ids),
        "still_spooled_ids": sorted(remaining - set(admitted)),
        "sampled_ids_accounted_for_by_loss": sorted(missing),
        "reported_loss_growth_during_sampling": loss_growth,
    }


def free_ports(count: int) -> list[int]:
    sockets = [socket.socket() for _ in range(count)]
    try:
        for sock in sockets:
            sock.bind(("127.0.0.1", 0))
        return [sock.getsockname()[1] for sock in sockets]
    finally:
        for sock in sockets:
            sock.close()


class Acceptance(TextProtocolMixin):
    def __init__(self) -> None:
        self.project = f"mondek-acceptance-{uuid.uuid4().hex[:10]}"
        ui, fixture, postgres = free_ports(3)
        self.base = f"http://127.0.0.1:{ui}"
        self.fixture = f"http://127.0.0.1:{fixture}"
        self.env = os.environ | {
            "MONDEK_PORT": str(ui),
            "MONDEK_FIXTURE_PORT": str(fixture),
            "PGPORT": str(postgres),
            "MONDEK_SPOOL_MAX_REPORTS": "8",
            "MONDEK_SPOOL_MAX_BYTES": "65536",
        }
        self.output = ROOT / ".local" / "acceptance" / self.project
        self.output.mkdir(parents=True)
        self.steps: list[dict[str, Any]] = []
        self.log = (self.output / "compose.log").open("w")

    def compose(self, *args: str, capture: bool = False, timeout: float = 900) -> str:
        return run_compose(
            ["docker", "compose", "-p", self.project, *args],
            env=self.env,
            log=self.log,
            capture=capture,
            timeout=timeout,
        )

    def request(
        self,
        path: str,
        body: Any = None,
        *,
        method: str | None = None,
        code: int = 200,
        fixture: bool = False,
    ) -> Any:
        url = (self.fixture if fixture else self.base) + path
        raw = None if body is None else json.dumps(body).encode()
        request = urllib.request.Request(
            url,
            raw,
            {"Content-Type": "application/json"},
            method=method or ("POST" if body is not None else "GET"),
        )
        try:
            with urllib.request.urlopen(request, timeout=5) as response:
                status, payload = response.status, response.read()
        except urllib.error.HTTPError as error:
            status, payload = error.code, error.read()
        assert status == code, (
            f"{method} {path}: expected {code}, got {status}: {payload[:1000]!r}"
        )
        if code == 413:
            return {"status": status, "body": payload.decode(errors="replace")}
        return json.loads(payload)

    def reviewed_maintenance(self, assignment: str, seconds: int, reason: str) -> dict:
        windows = getattr(self, "_reviewed_windows", {})
        if seconds == 0:
            previous = windows.pop(assignment)
            window = self.request(f"/api/v1/maintenance/{previous['id']}")
            return self.request(
                f"/api/v1/maintenance/{window['id']}/cancel",
                {
                    "revision": window["revision"],
                    "reason": reason,
                },
            )
        seed = self.request(
            f"/api/v1/maintenance/seed/{self.assignment(assignment)['id']}"
        )
        proposal = seed["proposal"] | {
            "name": "Acceptance maintenance",
            "reason": reason,
            "timezone": "UTC",
            "start_mode": "now",
            "ends_local": (datetime.now(timezone.utc) + timedelta(seconds=seconds))
            .replace(tzinfo=None)
            .isoformat(timespec="seconds"),
        }
        preview = self.request("/api/v1/maintenance/preview", {"proposal": proposal})
        window = self.request(
            "/api/v1/maintenance/apply",
            {
                "proposal": preview["proposal"],
                "review_token": preview["review_token"],
            },
        )
        windows[assignment] = window
        self._reviewed_windows = windows
        return window

    def reviewed_acknowledgement(
        self, incident_id: str, seconds: int, note: str
    ) -> dict:
        incident = next(
            row for row in self.snapshot()["incidents"] if row["id"] == incident_id
        )
        options = {
            "mode": "duration" if seconds else "end",
            "revision": incident["acknowledgement_revision"],
            "attention_revision": incident["attention_revision"],
            "note": note,
        }
        if seconds:
            options["seconds"] = seconds
        return self.request(f"/api/v1/incidents/{incident_id}/acknowledge", options)

    def snapshot(self) -> dict[str, Any]:
        return self.request("/api/v1/snapshot")

    def assignment(self, id_: str, snapshot: dict | None = None) -> dict[str, Any]:
        return next(
            a
            for a in (snapshot or self.snapshot())["assignments"]
            if a["id"] == id_ or a.get("source_key") == id_
        )

    def eventually(
        self, label: str, predicate: Callable[[], Any], timeout: float = 60
    ) -> Any:
        deadline = time.monotonic() + timeout
        last: Any = None
        while time.monotonic() < deadline:
            try:
                last = predicate()
                if last:
                    return last
            except (
                OSError,
                urllib.error.URLError,
                KeyError,
                StopIteration,
                subprocess.CalledProcessError,
            ) as error:
                last = str(error)
            time.sleep(0.4)
        raise AssertionError(f"Timed out: {label}; last result: {last!r}")

    def mode(self, **values: Any) -> None:
        self.request("/mode", values, fixture=True)

    def status(self) -> dict[str, Any]:
        return json.loads(
            self.compose(
                "exec",
                "-T",
                "runner",
                "python",
                "-m",
                "mondek_runner",
                "--status",
                capture=True,
            )
        )

    def reports(self) -> list[dict[str, Any]]:
        script = (
            "import sqlite3,json; c=sqlite3.connect('/state/runner.sqlite3'); "
            "print(json.dumps([json.loads(r[0]) for r in c.execute('SELECT payload FROM spool ORDER BY sequence')]))"
        )
        return json.loads(
            self.compose("exec", "-T", "runner", "python", "-c", script, capture=True)
        )

    def journal_sample(self) -> dict:
        # One read transaction keeps loss counters and spool membership consistent.
        script = """
import json, sqlite3
from datetime import datetime, timedelta, timezone
db = sqlite3.connect('file:/state/runner.sqlite3?mode=ro', uri=True)
db.execute('BEGIN')
metadata = dict(db.execute('SELECT key,value FROM metadata'))
rows = db.execute('SELECT payload,bytes,started_at FROM spool ORDER BY sequence').fetchall()
status = metadata | {key:int(metadata.get(key,0)) for key in ('boot','sequence','dropped')}
status.update(queue_count=len(rows), queue_bytes=sum(row[1] for row in rows))
status['oldest_at'] = min((row[2] for row in rows), default=None)
print(json.dumps({'captured_at':datetime.now(timezone.utc).isoformat(),
                  'status':status,'reports':[json.loads(row[0]) for row in rows]}))
db.close()
"""
        return json.loads(
            self.compose(
                "exec", "-T", "runner", "python", "-c", script, capture=True, timeout=10
            )
        )

    def records(self) -> list[dict[str, Any]]:
        return self.request("/records", fixture=True)["records"]

    def incident(self, assignment: str, *, open_only: bool = True) -> dict | None:
        return next(
            (
                i
                for i in self.snapshot()["incidents"]
                if i["assignment_id"] == self.assignment(assignment)["id"]
                and (not open_only or i["status"] == "open")
            ),
            None,
        )

    def send_report(self, report: dict, code: int = 200) -> dict:
        runner = self.snapshot()["runners"][0]
        return self.request(
            "/api/v1/observations",
            {
                "version": 1,
                "installation_id": runner["id"],
                "session_id": runner["session_id"],
                "reports": [report],
            },
            code=code,
        )

    def run_step(self, label: str, function: Callable[[], Any]) -> None:
        print(f"RUN  {label}", flush=True)
        start = time.monotonic()
        details = function()
        self.steps.append(
            {
                "scenario": label,
                "seconds": round(time.monotonic() - start, 2),
                "details": details,
            }
        )
        print(f"PASS {label}", flush=True)

    def coverage(self) -> bool:
        assignments = self.snapshot()["assignments"]
        return len(assignments) == 3 and all(
            a["current"].get("knowledge") == "fresh"
            and a["current"].get("complete")
            and a["observed_generation"] == a["desired_generation"]
            and a["active_generation"] == a["desired_generation"]
            and a["authorized_generation"] == a["desired_generation"]
            for a in assignments
        )

    def clean_start(self) -> dict:
        self.compose("up", "--build", "--detach", "--wait", "--wait-timeout", "180")
        platform = self.platform_evidence()
        self.eventually("three real observed assignments", self.coverage)
        with urllib.request.urlopen(self.base, timeout=5) as response:
            assert b"Mondek" in response.read()
        assert self.assignment("filesystem")["current"]["value"] > 0
        return {
            "project": self.project,
            "url": self.base,
            "assignments": 3,
            "platform": platform,
        }

    def platform_evidence(self) -> dict[str, Any]:
        """Record actual service images/runtime architecture, not just a request."""

        def docker(*args: str) -> str:
            return subprocess.run(
                ["docker", *args],
                cwd=ROOT,
                env=self.env,
                capture_output=True,
                text=True,
                check=True,
                timeout=30,
            ).stdout.strip()

        engine = json.loads(
            docker(
                "info",
                "--format",
                "{{json .Architecture}}",
            )
        )
        requested = self.env.get("DOCKER_DEFAULT_PLATFORM")
        services = {}
        for service in ("controller", "runner", "target", "postgres"):
            container = self.compose("ps", "--quiet", service, capture=True).strip()
            assert container, f"No running {service} container to inspect"
            image = docker("inspect", "--format", "{{.Image}}", container)
            image_platform = docker(
                "image", "inspect", "--format", "{{.Os}}/{{.Architecture}}", image
            )
            machine = self.compose(
                "exec", "-T", service, "uname", "-m", capture=True
            ).strip()
            services[service] = {
                "container": container,
                "image": image,
                "image_platform": image_platform,
                "runtime_machine": machine,
            }
        result = {
            "requested_platform": requested,
            "engine_architecture": engine,
            "services": services,
        }
        (self.output / "platform.json").write_text(json.dumps(result, indent=2))
        if requested:
            expected = "/".join(requested.split("/")[:2])
            for service, actual in services.items():
                assert actual["image_platform"] == expected, (
                    f"{service}: requested {expected}, got {actual['image_platform']}"
                )
                expected_machine = {
                    "linux/amd64": "x86_64",
                    "linux/arm64": "aarch64",
                }.get(expected)
                if expected_machine:
                    assert actual["runtime_machine"] == expected_machine, (
                        f"{service}: runtime is {actual['runtime_machine']}, expected {expected_machine}"
                    )
        return result

    def independent(self) -> dict:
        before = self.snapshot()
        # No operator HTTP/browser requests: the runner owns its collection cadence.
        time.sleep(7)
        after = self.snapshot()
        for old in before["assignments"]:
            new = self.assignment(old["id"], after)
            assert new["last_sequence"] > old["last_sequence"]
            assert new["current"]["source_at"] > old["current"]["source_at"]
            assert new["current"]["health"] == old["current"]["health"]
            assert new["current"]["knowledge"] == "fresh"
        assert all(e["payload"]["complete"] for e in after["evidence"])
        return {"seconds_without_client_requests": 7}

    def http_cycle(self) -> dict:
        self.mode(ready=False)
        incident = self.eventually(
            "HTTP failure opens episode", lambda: self.incident("http")
        )
        self.eventually(
            "real firing webhook",
            lambda: any(
                r["payload"].get("incident_id") == incident["id"]
                and r["payload"].get("kind") == "firing"
                for r in self.records()
            ),
        )
        time.sleep(4)
        occurrences = [
            o
            for o in self.snapshot()["occurrences"]
            if o["incident_id"] == incident["id"] and o["kind"] == "firing"
        ]
        assert len(occurrences) == 1
        self.compose("stop", "runner")
        failed = self.assignment("http")
        self.eventually(
            "stale failure retains confirmed health and unresolved episode",
            lambda: self.assignment("http")["current"]["knowledge"] == "stale",
            timeout=failed["freshness_seconds"] + 10,
        )
        stale = self.assignment("http")
        assert stale["current"]["health"] == "CRIT"
        assert stale["current"]["source_at"] == failed["current"]["source_at"]
        assert self.incident("http")["id"] == incident["id"]
        self.mode(ready=True)
        # Changing the target alone cannot recover the incident without a new probe.
        assert self.incident("http")["id"] == incident["id"]
        self.compose("start", "runner")
        self.eventually(
            "measured HTTP recovery",
            lambda: any(
                i["id"] == incident["id"] and i["closure_reason"] == "measured_recovery"
                for i in self.snapshot()["incidents"]
            ),
        )
        self.eventually(
            "real terminal webhook",
            lambda: any(
                r["payload"].get("incident_id") == incident["id"]
                and r["payload"].get("kind") == "resolved"
                for r in self.records()
            ),
        )
        return {
            "incident_id": incident["id"],
            "logical_firing_occurrences": len(occurrences),
            "stale_CRIT_preserved_until_measured_recovery": True,
        }

    def thresholds(self) -> dict:
        # Hosted runners can already exceed the demo's 80% warning threshold.
        # Establish a measured healthy baseline before testing a deliberate failure.
        initial = self.assignment("filesystem")
        healthy = initial["params"] | {"warn_percent": 99, "crit_percent": 100}
        self.request(
            f"/api/v1/assignments/{self.assignment('filesystem')['id']}",
            {"revision": initial["revision"], "params": healthy},
            method="PUT",
        )
        self.eventually(
            "healthy threshold baseline is measured",
            lambda: (
                (row := self.assignment("filesystem"))["observed_generation"]
                == row["desired_generation"]
                and row["current"]["health"] == "OK"
                and row["current"]["knowledge"] == "fresh"
            ),
        )
        original = self.assignment("filesystem")
        invalid = original["params"] | {"warn_percent": 95, "crit_percent": 80}
        self.request(
            f"/api/v1/assignments/{self.assignment('filesystem')['id']}",
            {"revision": original["revision"], "params": invalid},
            method="PUT",
            code=422,
        )
        old_report = next(
            e["payload"]
            for e in self.snapshot()["evidence"]
            if e["assignment_id"] == original["id"] and e["disposition"] == "current"
        )
        self.compose("stop", "runner")
        low = original["params"] | {"warn_percent": 0, "crit_percent": 0.01}
        self.request(
            f"/api/v1/assignments/{self.assignment('filesystem')['id']}",
            {"revision": original["revision"], "params": low},
            method="PUT",
        )
        self.request(
            f"/api/v1/assignments/{self.assignment('filesystem')['id']}",
            {"revision": original["revision"], "params": original["params"]},
            method="PUT",
            code=409,
        )
        pending = self.assignment("filesystem")
        assert pending["desired_generation"] > pending["active_generation"]
        assert pending["observed_generation"] == original["observed_generation"]
        self.compose("start", "runner")
        self.eventually(
            "new threshold observed CRIT",
            lambda: (
                self.assignment("filesystem")["observed_generation"]
                == pending["desired_generation"]
                and self.assignment("filesystem")["current"]["health"] == "CRIT"
            ),
        )
        incident = self.eventually(
            "low threshold opens its own incident", lambda: self.incident("filesystem")
        )
        # Current-session transport carries deliberately late old-configuration evidence.
        old_report = copy.deepcopy(old_report)
        old_report["id"] = str(uuid.uuid4())
        old_report["session_id"] = self.snapshot()["runners"][0]["session_id"]
        old_report["sequence"] += 100000
        assert (
            self.send_report(old_report)["dispositions"][0]["disposition"]
            == "historical"
        )
        assert self.assignment("filesystem")["current"]["health"] == "CRIT"
        latest = self.assignment("filesystem")
        self.request(
            f"/api/v1/assignments/{self.assignment('filesystem')['id']}",
            {"revision": latest["revision"], "params": original["params"]},
            method="PUT",
        )
        self.eventually(
            "configuration closure is honest",
            lambda: any(
                i["id"] == incident["id"]
                and i["closure_reason"] == "configuration_changed"
                for i in self.snapshot()["incidents"]
            ),
        )
        return {
            "pending_generation": pending["desired_generation"],
            "incident_id": incident["id"],
            "late_old_OK": "historical",
            "closure": "configuration_changed",
        }

    def consumer_policy(self) -> dict:
        """Consumer classes compose findings; the controller receives ordinary results."""
        self.mode(backlog=6, processing_enabled=False)
        try:
            failed = self.eventually(
                "consumer policy combines a queue warning and stopped processing",
                lambda: (
                    row
                    if (row := self.assignment("consumer"))["current"]["knowledge"]
                    == "fresh"
                    and row["current"]["health"] == "CRIT"
                    and "[WARN]" in (row["current"].get("details") or "")
                    and "[CRIT]" in (row["current"].get("details") or "")
                    else False
                ),
            )
            incident = self.eventually(
                "custom policy opens an ordinary incident",
                lambda: self.incident("consumer"),
            )
            details = failed["current"]["details"]
            report = next(
                item["payload"]
                for item in self.snapshot()["evidence"]
                if item["id"] == failed["current"]["confirmed_observation_id"]
            )
            assert report["results"][0]["details"] == details
            assert report["results"][0]["source_at"] == failed["current"]["source_at"]
            assert (
                self.send_report(report)["dispositions"][0]["disposition"]
                == "duplicate"
            )
            altered = copy.deepcopy(report)
            altered["results"][0]["details"] += "\nChanged diagnostic context"
            assert (
                self.send_report(altered)["dispositions"][0]["disposition"]
                == "conflict"
            )
            self.eventually(
                "custom policy sends a real compact firing notification",
                lambda: any(
                    record["payload"].get("incident_id") == incident["id"]
                    and record["payload"].get("kind") == "firing"
                    and "details" not in record["payload"]
                    for record in self.records()
                ),
            )

            self.mode(data_mode="crash")
            unavailable = self.eventually(
                "collection failure retains confirmed policy findings",
                lambda: (
                    row
                    if (row := self.assignment("consumer"))["current"]["knowledge"]
                    == "unavailable"
                    else False
                ),
            )
            current = unavailable["current"]
            assert current["health"] == "CRIT" and current["details"] == details
            assert current["execution_details"] is None
            assert current["observation_id"] != current["confirmed_observation_id"]
            assert self.incident("consumer")["id"] == incident["id"]
            retained = next(
                item["payload"]
                for item in self.snapshot()["evidence"]
                if item["id"] == current["confirmed_observation_id"]
            )
            assert retained["results"][0]["source_at"] == current["source_at"]
            assert retained["results"][0]["details"] == current["details"]
            self.mode(backlog=2, processing_enabled=True, data_mode="ok")
            recovered = self.eventually(
                "a new collection recovers the custom policy",
                lambda: (
                    row
                    if (row := self.assignment("consumer"))["current"]["knowledge"]
                    == "fresh"
                    and row["current"]["health"] == "OK"
                    else False
                ),
            )
            assert (
                recovered["current"]["confirmed_observation_id"]
                != current["confirmed_observation_id"]
            )
            assert "[CRIT]" not in recovered["current"]["details"]
            assert recovered["current"]["source_at"] > current["source_at"]
            assert (
                recovered["current"]["confirmed_evaluated_at"]
                > current["confirmed_evaluated_at"]
            )
            self.eventually(
                "custom policy incident closes through measured recovery",
                lambda: any(
                    item["id"] == incident["id"]
                    and item["closure_reason"] == "measured_recovery"
                    for item in self.snapshot()["incidents"]
                ),
            )
            self.eventually(
                "custom policy recovery sends a real terminal notification",
                lambda: any(
                    record["payload"].get("incident_id") == incident["id"]
                    and record["payload"].get("kind") == "resolved"
                    for record in self.records()
                ),
            )
            return {
                "incident_id": incident["id"],
                "original_report": report,
                "unavailable": current,
                "recovered": recovered["current"],
                "exact_replay": "duplicate",
                "changed_details": "conflict",
                "new_controller_check_kinds": 0,
            }
        finally:
            self.mode(backlog=2, processing_enabled=True, data_mode="ok")

    def retry(self) -> dict:
        self.mode(ingest_reply="drop_once")
        dropped = self.eventually(
            "real committed ingestion reply is dropped",
            lambda: next(
                (
                    r
                    for r in self.request("/transport-records", fixture=True)["records"]
                    if r["dropped"]
                ),
                None,
            ),
        )
        reports = dropped["request"]["reports"]
        report_ids = {r["id"] for r in reports}
        retry = self.eventually(
            "runner retries original identity and receives duplicate disposition",
            lambda: next(
                (
                    r
                    for r in self.request("/transport-records", fixture=True)["records"]
                    if not r["dropped"]
                    and any(
                        d["id"] in report_ids and d["disposition"] == "duplicate"
                        for d in r["response"]["dispositions"]
                    )
                ),
                None,
            ),
        )
        retried = {report["id"]: report for report in retry["request"]["reports"]}
        for report in reports:
            assert retried[report["id"]] == report, "retry changed original evidence"
        self.compose("stop", "runner")
        before = self.snapshot()
        report = copy.deepcopy(reports[0])
        assert sum(e["id"] == report["id"] for e in before["evidence"]) == 1
        result = self.send_report(report)["dispositions"][0]
        assert result["disposition"] == "duplicate"
        assert len(self.snapshot()["evidence"]) == len(before["evidence"])
        assert len(self.snapshot()["occurrences"]) == len(before["occurrences"])
        report["diagnostic"] = "conflicting semantic payload under same identity"
        assert self.send_report(report)["dispositions"][0]["disposition"] == "conflict"
        self.compose("start", "runner")
        self.eventually("coverage after retry test", self.coverage)
        return {
            "report_id": report["id"],
            "real_HTTP_reply_dropped_after_commit": True,
            "exact_retry": result,
            "altered_payload": "conflict",
        }

    def disconnect(self) -> dict:
        before = self.status()
        (self.output / "disconnect-before.json").write_text(
            json.dumps(before, indent=2)
        )
        self.compose("stop", "controller")
        self.eventually(
            "offline bounded spool fills and reports loss",
            lambda: self.status()["dropped"] > before.get("dropped", 0),
            timeout=45,
        )
        samples: list[dict] = []
        observed: dict[str, dict] = {}

        def sample(phase: str) -> dict:
            assert len(samples) < 256, "Reconnect journal sampling exceeded its bound"
            current = self.journal_sample() | {"phase": phase}
            samples.append(current)
            with (self.output / "disconnect-spool-samples.jsonl").open("a") as output:
                output.write(json.dumps(current) + "\n")
            status = current["status"]
            assert status["session_id"] == before["session_id"], (
                "Reconnect restarted the runner"
            )
            assert status["queue_count"] <= 8 and status["queue_bytes"] <= 65536
            return current

        offline = sample("before_controller_restart")
        (self.output / "disconnect-offline.json").write_text(
            json.dumps(offline, indent=2)
        )
        assert offline["reports"]
        assert max(r["sequence"] for r in offline["reports"]) > before["sequence"]

        # Starting Docker can take longer than a full eight-report spool's lifetime.
        # Keep witnessing the unchanged runner while only its controller restarts.
        with ThreadPoolExecutor(max_workers=1) as executor:
            start = executor.submit(self.compose, "start", "controller", timeout=60)

            def controller_ready() -> bool:
                sample("starting_controller")
                if not start.done():
                    return False
                start.result()
                return self.request("/health").get("status") == "ok"

            self.eventually("controller ready after outage", controller_ready)

        def preserved() -> bool:
            sample("reconnecting")
            observed.update({item["id"]: item for item in self.snapshot()["evidence"]})
            captured_ids = {
                r["id"]
                for item in samples
                if item["phase"] in {"before_controller_restart", "starting_controller"}
                for r in item["reports"]
            }
            return bool(captured_ids & observed.keys())

        self.eventually(
            "captured buffered reports commit with original identity", preserved
        )

        def drained() -> bool:
            current = sample("draining")
            observed.update({item["id"]: item for item in self.snapshot()["evidence"]})
            return current["status"]["queue_count"] <= 1 and self.coverage()

        self.eventually("queue drains and current collection resumes", drained)
        reconciliation = reconcile_spool_samples(samples, list(observed.values()))
        rich_ids = {
            report["id"]
            for item in samples
            if item["phase"] in {"before_controller_restart", "starting_controller"}
            for report in item["reports"]
            if any(result.get("details") for result in report["results"])
        }
        preserved_details = rich_ids & set(reconciliation["admitted_ids"])
        assert preserved_details, "No original rich result survived the real outage"
        reconciliation["preserved_original_details_ids"] = sorted(preserved_details)
        (self.output / "disconnect-reconciliation.json").write_text(
            json.dumps(reconciliation, indent=2)
        )
        assert self.snapshot()["runners"][0]["status"]["dropped"] > 0
        return {
            "dropped": samples[-1]["status"]["dropped"],
            "maximum_spool_reports": 8,
            **reconciliation,
        }

    def failures_and_restart(self) -> dict:
        self.mode(data_mode="slow")
        self.eventually(
            "slow worker leaves explicit unavailable coverage",
            lambda: (
                self.assignment("consumer")["current"].get("knowledge") == "unavailable"
            ),
        )
        first = self.snapshot()
        time.sleep(4)
        later = self.snapshot()
        assert (
            self.assignment("http", later)["last_sequence"]
            > self.assignment("http", first)["last_sequence"]
        )
        # Stable control long-polls can wait five seconds. Keep the independent
        # execution assertion above, then require contact progress within a
        # bounded transport window instead of assuming the old two-second poll.
        self.eventually(
            "control contact advances independently of a slow check",
            lambda: (
                self.snapshot()["runners"][0]["last_seen_at"]
                > first["runners"][0]["last_seen_at"]
            ),
            timeout=8,
        )
        assert len(self.status().get("inflight", [])) <= 3
        self.mode(data_mode="crash")
        self.eventually(
            "worker crash is visible",
            lambda: (
                "crash"
                in (self.assignment("consumer")["current"].get("diagnostic") or "")
            ),
        )
        old = self.status()
        old_report = copy.deepcopy(
            next(
                e["payload"]
                for e in self.snapshot()["evidence"]
                if e["disposition"] == "current"
            )
        )
        self.mode(data_mode="slow")
        self.eventually(
            "the slow fixture mode is used by an actual new consumer run",
            lambda: (
                "timed out"
                in (self.assignment("consumer")["current"].get("diagnostic") or "")
            ),
        )
        self.eventually(
            "a slow consumer is outstanding at the process restart",
            lambda: self.assignment("consumer")["id"] in self.status()["inflight"],
        )
        self.compose("kill", "-s", "SIGKILL", "runner")
        self.mode(data_mode="ok")
        self.compose("start", "runner")
        self.eventually(
            "new session remains same installation",
            lambda: self.status()["boot"] > old["boot"],
        )
        new = self.status()
        assert new["installation_id"] == old["installation_id"]
        assert new["session_id"] != old["session_id"]
        self.eventually("new session gains actual coverage", self.coverage)
        assert any(
            e["payload"]["session_id"] == old["session_id"]
            and not e["payload"]["complete"]
            and "runner restart" in (e["payload"].get("diagnostic") or "")
            for e in self.snapshot()["evidence"]
        ), "restart lost the durable allocation of the interrupted run"
        old_report["id"] = str(uuid.uuid4())
        old_report["sequence"] += 100000
        assert (
            self.send_report(old_report)["dispositions"][0]["disposition"]
            == "historical"
        )
        return {
            "installation_id": new["installation_id"],
            "old_boot": old["boot"],
            "new_boot": new["boot"],
            "old_session": "historical",
        }

    def notification_restart(self) -> dict:
        self.mode(webhook="drop", ready=False)
        incident = self.eventually("outage episode", lambda: self.incident("http"))
        self.eventually(
            "receiver persists firing before dropped reply",
            lambda: any(
                r["payload"].get("incident_id") == incident["id"]
                for r in self.records()
            ),
        )
        occurrence = next(
            o
            for o in self.snapshot()["occurrences"]
            if o["incident_id"] == incident["id"] and o["kind"] == "firing"
        )
        self.eventually(
            "ambiguous delivery attempt visible",
            lambda: any(
                a["occurrence_id"] == occurrence["id"] and a["status"] != "started"
                for a in self.snapshot()["attempts"]
            ),
        )
        self.compose("restart", "controller")
        self.eventually(
            "controller returns", lambda: self.request("/health").get("status") == "ok"
        )
        self.mode(webhook="ok")
        self.eventually(
            "same occurrence eventually delivered",
            lambda: any(
                o["id"] == occurrence["id"] and o["status"] == "delivered"
                for o in self.snapshot()["occurrences"]
            ),
            timeout=90,
        )
        receipts = [
            r
            for r in self.records()
            if r["payload"].get("occurrence_id") == occurrence["id"]
        ]
        assert len(receipts) >= 2, (
            "at-least-once retries should expose the dropped-reply duplicate"
        )
        self.mode(ready=True)
        self.eventually(
            "recovery after ambiguous delivery", lambda: self.incident("http") is None
        )
        self.eventually(
            "terminal delivered",
            lambda: any(
                r["payload"].get("incident_id") == incident["id"]
                and r["payload"].get("kind") == "resolved"
                for r in self.records()
            ),
        )
        # A second definitely rejected occurrence must stop retrying after recovery.
        self.mode(webhook="reject", ready=False)
        rejected = self.eventually(
            "rejected notification episode", lambda: self.incident("http")
        )
        rejected_occurrence = next(
            o
            for o in self.snapshot()["occurrences"]
            if o["incident_id"] == rejected["id"] and o["kind"] == "firing"
        )
        self.eventually(
            "rejected attempt recorded",
            lambda: any(
                a["occurrence_id"] == rejected_occurrence["id"]
                and a["http_status"] == 503
                for a in self.snapshot()["attempts"]
            ),
        )
        self.mode(ready=True)
        self.eventually(
            "rejected episode closes", lambda: self.incident("http") is None
        )
        self.mode(webhook="ok")
        self.eventually(
            "obsolete firing work is terminal after measured recovery",
            lambda: any(
                o["id"] == rejected_occurrence["id"] and o["status"] == "superseded"
                for o in self.snapshot()["occurrences"]
            ),
        )
        self.eventually(
            "terminal notification eventually follows rejected firing",
            lambda: any(
                r["payload"].get("incident_id") == rejected["id"]
                and r["payload"].get("kind") == "resolved"
                for r in self.records()
            ),
        )
        assert not any(
            r["payload"].get("incident_id") == rejected["id"]
            and r["payload"].get("kind") == "firing"
            for r in self.records()
        )
        return {
            "occurrence_id": occurrence["id"],
            "external_receipts_for_same_occurrence": len(receipts),
            "obsolete_firing": "superseded",
        }

    def gates(self) -> dict:
        self.reviewed_maintenance("http", 45, "acceptance local planned work")
        self.mode(ready=False)
        incident = self.eventually(
            "failure still observed in maintenance", lambda: self.incident("http")
        )
        self.reviewed_acknowledgement(
            incident["id"], 10, "acceptance operator acknowledgement"
        )
        first_sequence = self.assignment("http")["last_sequence"]
        self.reviewed_maintenance("http", 0, "end only maintenance")
        snap = self.snapshot()
        current_incident = next(
            i for i in snap["incidents"] if i["id"] == incident["id"]
        )
        assert current_incident["acknowledged_until"] is not None
        time.sleep(4)
        assert self.assignment("http")["current"]["health"] == "CRIT"
        assert self.assignment("http")["last_sequence"] > first_sequence
        assert not any(
            r["payload"].get("incident_id") == incident["id"] for r in self.records()
        )
        self.eventually(
            "acknowledgement expiry wakes durable pending attention",
            lambda: any(
                r["payload"].get("incident_id") == incident["id"]
                for r in self.records()
            ),
            timeout=35,
        )
        self.mode(ready=True)
        self.eventually(
            "recovery ends acknowledged episode", lambda: self.incident("http") is None
        )

        self.reviewed_maintenance(
            "http", 10, "verify maintenance remains an independent gate"
        )
        self.mode(ready=False)
        second = self.eventually(
            "second maintained failure remains monitored", lambda: self.incident("http")
        )
        self.reviewed_acknowledgement(
            second["id"], 45, "second independent acknowledgement"
        )
        self.reviewed_acknowledgement(second["id"], 0, "end only acknowledgement")
        assert (
            self.request(f"/api/v1/maintenance/{self._reviewed_windows['http']['id']}")[
                "status"
            ]
            == "active"
        )
        assert not any(
            r["payload"].get("incident_id") == second["id"] for r in self.records()
        )
        self.eventually(
            "maintenance expiry releases attention after acknowledgement ended",
            lambda: any(
                r["payload"].get("incident_id") == second["id"] for r in self.records()
            ),
            timeout=35,
        )
        self.mode(ready=True)
        self.eventually(
            "second gate episode recovers", lambda: self.incident("http") is None
        )
        return {
            "incident_id": incident["id"],
            "health_preserved": "CRIT",
            "checks_continued": True,
            "expiry_delivered": True,
            "ending_acknowledgement_preserved_maintenance": True,
        }

    def bounds(self) -> dict:
        self.mode(data_mode="oversize")
        self.eventually(
            "output cap produces explicit coverage failure",
            lambda: (
                "cap"
                in (self.assignment("consumer")["current"].get("diagnostic") or "")
            ),
        )
        consumer = self.assignment("consumer")
        assert consumer["expected_keys"] == ["backlog"]
        assert consumer["current"]["knowledge"] == "unavailable"
        assert consumer["current"]["complete"] is False
        assert self.assignment("http")["current"]["knowledge"] == "fresh"
        self.request("/api/v1/observations", {"padding": "x" * 270000}, code=413)
        self.mode(data_mode="ok")
        self.eventually("coverage recovers after output limit", self.coverage)
        return {
            "worker_output_cap_bytes": 65536,
            "HTTP_payload_cap_bytes": 262144,
            "spool_overflow_tested": True,
        }

    def run(self) -> None:
        success = False
        try:
            for label, function in [
                ("clean Compose startup and observed coverage", self.clean_start),
                ("independent unchanged collection", self.independent),
                (
                    "HTTP failure, durable notification and measured recovery",
                    self.http_cycle,
                ),
                (
                    "invalid/stale/offline threshold edit and old-generation fencing",
                    self.thresholds,
                ),
                ("lost-reply exact replay and conflicting retry", self.retry),
                (
                    "consumer-defined composition, details, unavailable collection and recovery",
                    self.consumer_policy,
                ),
                (
                    "controller outage, bounded spool loss and original-age reconnect",
                    self.disconnect,
                ),
                (
                    "slow/crashed worker and persistent runner session restart",
                    self.failures_and_restart,
                ),
                (
                    "ambiguous/rejected notification retries across controller restart",
                    self.notification_restart,
                ),
                ("independent acknowledgement and bounded maintenance", self.gates),
                ("output/payload caps and coverage recovery", self.bounds),
                (
                    "valid sibling evidence survives invalid authored text",
                    self.text_protocol,
                ),
            ]:
                self.run_step(label, function)
            success = True
        finally:
            self.finish(success)
            print(f"Evidence: {self.output}", flush=True)
        assert success
        print("All real end-to-end acceptance scenarios passed.", flush=True)

    def finish(self, success: bool) -> None:
        try:
            try:
                (self.output / "snapshot.json").write_text(
                    json.dumps(self.snapshot(), indent=2)
                )
                (self.output / "receipts.json").write_text(
                    json.dumps(self.records(), indent=2)
                )
            except Exception:
                pass
            (self.output / "results.json").write_text(
                json.dumps(
                    {
                        "success": success,
                        "finished_at": datetime.now(timezone.utc).isoformat(),
                        "project": self.project,
                        "steps": self.steps,
                    },
                    indent=2,
                )
            )
        finally:
            try:
                self.compose("logs", "--no-color", "--tail", "250")
            finally:
                try:
                    # Only this invocation's randomly named project is destroyed.
                    self.compose("down", "--volumes", "--remove-orphans")
                finally:
                    self.log.close()


if __name__ == "__main__":
    Acceptance().run()
