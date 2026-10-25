#!/usr/bin/env python3
# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Two real observers through a local TLS gateway, PostgreSQL and journal restart."""

from __future__ import annotations

import json
import subprocess
from datetime import UTC, datetime

from acceptance import ROOT, run_compose
from parity import ParityAcceptance
from parity_transport import exact_buffered_evidence


class GatewayAcceptance(ParityAcceptance):
    def __init__(self):
        super().__init__(dynamic_ports=True)
        self.overlay = self.output / "compose.gateway.json"
        self.certs = self.output / "certs"
        self.certs.mkdir()
        services = {
            "gateway": {
                "build": {
                    "context": str(ROOT),
                    "dockerfile": "tests/fixtures/Dockerfile",
                },
                "user": "0:0",
                "command": ["python", "/gateway.py"],
                "volumes": [
                    f"{ROOT}/tests/fixtures/gateway.py:/gateway.py:ro",
                    f"{self.certs}:/certs:ro",
                    "gateway_data:/gateway",
                ],
                "depends_on": {"controller": {"condition": "service_healthy"}},
            }
        }
        for observer in ("observer-a", "observer-b"):
            services[observer] = {
                "build": {"context": str(ROOT), "dockerfile": "runner/Dockerfile"},
                "environment": {
                    "MONDEK_CONSUMER": "gateway_checks:app",
                    "MONDEK_STATE_DIR": "/state",
                    "GATEWAY_OBSERVER": observer,
                    "MONDEK_RUNNER_LABEL": observer + " acceptance observer",
                    "MONDEK_CONTROLLER_URL": "https://gateway:8443",
                    "MONDEK_CONTROLLER_HEADERS_FILE": f"/gateway/{observer}.json",
                    "SSL_CERT_FILE": "/certs/cert.pem",
                },
                "volumes": [
                    f"{observer}_data:/state",
                    "gateway_data:/gateway:ro",
                    f"{self.certs}:/certs:ro",
                    f"{ROOT}/tests/fixtures/gateway_checks.py:/app/examples/gateway_checks.py:ro",
                ],
                "init": True,
            }
        self.overlay.write_text(
            json.dumps(
                {
                    "services": services,
                    "volumes": {
                        "gateway_data": {},
                        "observer-a_data": {},
                        "observer-b_data": {},
                    },
                }
            )
        )

    def compose(self, *args, capture=False, timeout=900):
        return run_compose(
            [
                "docker",
                "compose",
                "-p",
                self.project,
                "-f",
                str(ROOT / "compose.yaml"),
                "-f",
                str(self.overlay),
                *args,
            ],
            env=self.env,
            log=self.log,
            capture=capture,
            timeout=timeout,
        )

    def configure(self, observer=None, token=None):
        # Fixed disposable test credentials, not operator credentials. Atomic replace
        # exercises the same private-file reload as a real credential rotation.
        script = """
import json, os
from pathlib import Path
p=Path('/gateway')
"""
        if observer:
            data = {
                "origin": "https://gateway:8443",
                "headers": {"X-Test-Observer": observer, "Authorization": token},
            }
            script += f"f=p/{observer!r}; f=f.with_suffix('.tmp'); f.write_text({json.dumps(data)!r}); f.chmod(0o600); os.chown(f,65532,65532); f.replace(p/{(observer + '.json')!r})"
        else:
            mode = {
                "observer-a": "observer-a-test",
                "observer-b": token or "observer-b-initial",
            }
            script += f"(p/'mode.tmp').write_text({json.dumps(mode)!r}); (p/'mode.tmp').replace(p/'mode.json')"
        self.compose("exec", "-T", "gateway", "python", "-c", script)

    def coverage_counts(self, fresh, stale):
        listing = self.request("/api/v1/coverage?source_id=gateway-acceptance")
        assert listing["total"] == 2
        counts = [scope["counts"] for scope in listing["items"]]
        return (
            sum(row["fresh"] for row in counts) == fresh
            and sum(row["stale"] for row in counts) == stale
        )

    def events(self, observer, *, current_session=False):
        raw = self.compose("logs", "--no-log-prefix", observer, capture=True)
        events = []
        for line in raw.splitlines():
            try:
                events.append(json.loads(line))
            except ValueError:
                pass
        if current_session:
            starts = [
                i
                for i, event in enumerate(events)
                if event.get("event") == "runner_started"
            ]
            return events[starts[-1] :] if starts else []
        return events

    def exercise(self):
        subprocess.run(
            [
                "openssl",
                "req",
                "-x509",
                "-newkey",
                "rsa:2048",
                "-nodes",
                "-keyout",
                str(self.certs / "key.pem"),
                "-out",
                str(self.certs / "cert.pem"),
                "-days",
                "1",
                "-subj",
                "/CN=gateway",
                "-addext",
                "subjectAltName=DNS:gateway",
            ],
            check=True,
            stdout=self.log,
            stderr=self.log,
        )
        self.compose("up", "--build", "-d", "--wait", "gateway")
        self.resolve_host_ports()
        self.configure()
        self.configure("observer-a", "observer-a-test")
        self.configure("observer-b", "observer-b-initial")
        self.compose("up", "--build", "-d", "observer-a", "observer-b")
        self.eventually(
            "two registered fresh observers",
            lambda: (
                len(self.streams()["items"]) == 2
                and all(
                    self.fresh("host:" + key) for key in ("observer-a", "observer-b")
                )
            ),
            timeout=120,
        )
        baseline = {
            key: self.stream("host:" + key) for key in ("observer-a", "observer-b")
        }
        assert (
            baseline["observer-a"]["runner_id"] != baseline["observer-b"]["runner_id"]
        )
        journal = self.node_journal("observer-b")
        self.configure(token="observer-b-rotated")
        denied_at = datetime.now(UTC)
        queued = self.eventually(
            "denied observer keeps measuring into its journal",
            lambda: (
                sample
                if (sample := self.node_journal("observer-b"))
                and len(
                    [
                        report
                        for report in sample["reports"]
                        if datetime.fromisoformat(report["started_at"]) > denied_at
                    ]
                )
                >= 3
                else False
            ),
        )
        self.eventually(
            "one stale observer, independent peer still advances",
            lambda: (
                self.stream("host:observer-b")["current"]["knowledge"] == "stale"
                and (peer := self.fresh("host:observer-a"))
                and datetime.fromisoformat(peer["current"]["evaluated_at"]) > denied_at
            ),
        )
        self.eventually(
            "declared coverage preserves the stale observer",
            lambda: self.coverage_counts(1, 1),
        )
        failures = self.events("observer-b")
        assert any(
            event.get("event") == "controller_unavailable"
            and event.get("http_status") == 403
            for event in failures
        )
        self.compose("restart", "observer-b")
        restarted = self.eventually(
            "same durable installation after restart",
            lambda: (
                sample
                if (sample := self.node_journal("observer-b"))["status"]["boot"]
                > journal["status"]["boot"]
                else False
            ),
        )
        assert (
            restarted["status"]["installation_id"]
            == journal["status"]["installation_id"]
        )
        assert restarted["status"]["session_id"] != journal["status"]["session_id"]
        captured = {report["id"]: report for report in queued["reports"]}
        assert all(report in restarted["reports"] for report in captured.values())
        self.eventually(
            "registration fails visibly after restart",
            lambda: (
                {
                    event.get("channel")
                    for event in self.events("observer-b", current_session=True)
                    if event.get("event") == "controller_unavailable"
                }
                >= {"inventory", "control"}
            ),
        )
        restored_at = datetime.now(UTC)
        self.configure("observer-b", "observer-b-rotated")
        admitted = self.eventually(
            "all pre-restart buffered evidence reaches PostgreSQL",
            lambda: (
                items
                if len(items := self.stored_reports(list(captured))) == len(captured)
                else False
            ),
        )
        preserved = exact_buffered_evidence(list(captured.values()), admitted)
        assert preserved["historical"] == len(captured), (
            "Old-session evidence became current"
        )
        fresh = self.eventually(
            "fresh execution after access restoration",
            lambda: (
                row
                if (row := self.fresh("host:observer-b"))
                and datetime.fromisoformat(row["current"]["evaluated_at"]) > restored_at
                and row["current"]["session_id"] == restarted["status"]["session_id"]
                else False
            ),
        )
        assert fresh["id"] == baseline["observer-b"]["id"]
        assert len(self.snapshot()["runners"]) == 2
        peer = self.fresh("host:observer-a")
        assert peer
        for field in ("id", "runner_id"):
            assert peer[field] == baseline["observer-a"][field]
        assert (
            peer["current"]["session_id"]
            == baseline["observer-a"]["current"]["session_id"]
        )
        self.eventually(
            "both declared scopes recover", lambda: self.coverage_counts(2, 0)
        )
        final = self.node_journal("observer-b")
        assert final["status"]["dropped"] == journal["status"]["dropped"] == 0
        self.eventually(
            "inventory and control report recovery after rejected registration",
            lambda: (
                {
                    event.get("channel")
                    for event in self.events("observer-b")
                    if event.get("event") == "controller_ready"
                    and event.get("failed_attempts", 0) > 0
                }
                >= {"inventory", "control"}
            ),
        )
        events = self.events("observer-b")
        for credential in (
            "observer-b-initial",
            "observer-b-rotated",
            "observer-a-test",
        ):
            assert credential not in json.dumps(events)
        (self.output / "journal-cohort.json").write_text(
            json.dumps(
                {"captured": list(captured.values()), "stored": admitted}, indent=2
            )
        )
        (self.output / "runner-events.json").write_text(json.dumps(events, indent=2))
        return {
            "observers": 2,
            "buffered_evidence": preserved,
            "dropped": 0,
            "observer-b_installation": journal["status"]["installation_id"],
        }

    def run(self):
        success = False
        print(
            f"Gateway acceptance: {self.project}; evidence: {self.output}", flush=True
        )
        try:
            self.run_step(
                "two independent observers survive denial, restart and credential rotation",
                self.exercise,
            )
            success = True
        finally:
            try:
                (self.output / "gateway-results.json").write_text(
                    json.dumps({"success": success, "steps": self.steps}, indent=2)
                )
            finally:
                try:
                    self.compose("logs", "--no-color", "--tail", "200")
                finally:
                    try:
                        self.compose("down", "--volumes", "--remove-orphans")
                    finally:
                        self.log.close()
        assert success


if __name__ == "__main__":
    GatewayAcceptance().run()
