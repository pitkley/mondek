#!/usr/bin/env python3
# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Declared coverage through installed consumers, real HTTP and durable state.

The invocation owns every mutated container and volume. Results always come
from installed runner processes. Rejected/replayed inventories use the exact
runner journal envelope; direct SQL only witnesses original buffered reports.
"""

from __future__ import annotations

import copy
import json
import urllib.parse
from datetime import UTC, datetime
from typing import Any

from acceptance import run_compose
from grouped import HEALTHY, after_boundary
from parity import ParityAcceptance
from parity_transport import exact_buffered_evidence

SOURCE = "declared-coverage"
NODE_A = "coverage-node-a"
NODE_B = "coverage-node-b"
SERVICE_A = "coverage-service-a"
SERVICE_B = "coverage-service-b"
SERVICES = (NODE_A, NODE_B, SERVICE_A, SERVICE_B)
SERVICE_TARGET = "service:search"
PUBLISHER_AUTHORITY = (
    "id",
    "runner_id",
    "source_id",
    "inventory_revision",
    "source_revision",
    "coverage_revision",
    "coverage_source_revision",
    "code_revision",
    "runtime_revision",
    "coverage_confirmed",
)


def matches_scope(
    row: dict, environment: str, target: str, key: str | None = None
) -> bool:
    return (
        row.get("source_id") == SOURCE
        and row.get("environment") == environment
        and row.get("target", {}).get("key") == target
        and row.get("target", {}).get("kind")
        == ("service" if target == SERVICE_TARGET else "host")
        and row.get("result_key")
        == ("collection" if key == "local-collection" else "capacity")
        and (key is None or row.get("source_key") == key)
    )


def publisher_authority(row: dict) -> dict:
    """Exclude changing contact times while retaining accepted catalogue identity."""
    return {key: row[key] for key in PUBLISHER_AUTHORITY}


def fresh_desired(row: dict, health: str, after: datetime | None = None) -> bool:
    current = row.get("current") or {}
    return (
        row.get("desired_generation") is not None
        and current.get("knowledge") == "fresh"
        and current.get("health") == health
        and current.get("observation_id") is not None
        and current.get("observation_id") == current.get("confirmed_observation_id")
        and current.get("confirmed_generation") == row.get("desired_generation")
        and row.get("active_generation") == row.get("desired_generation")
        and (
            after is None
            or all(
                after_boundary(current.get(key), after)
                for key in ("evaluated_at", "confirmed_evaluated_at", "source_at")
            )
        )
    )


def fresh_after_restart(
    row: dict, previous: dict, after: datetime, session_id: str
) -> bool:
    """Require a new execution from this restart, never retained predeploy health."""
    current = row.get("current") or {}
    prior = previous.get("current") or {}
    return (
        bool(session_id)
        and session_id != prior.get("session_id")
        and current.get("session_id") == session_id
        and current.get("observation_id") != prior.get("observation_id")
        and fresh_desired(row, "OK", after)
    )


class CoverageAcceptance(ParityAcceptance):
    def __init__(self) -> None:
        super().__init__()
        self.env.update(MONDEK_NOTIFICATION_MAX_ATTEMPTS="3")
        self.identities: dict[str, str] = {}

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
                "examples/compose/coverage.yaml",
                "--profile",
                "restore-node-b",
                *args,
            ],
            env=self.env,
            log=self.log,
            capture=capture,
            timeout=timeout,
        )

    def coverage_list(self, **filters: Any) -> dict:
        return self.request("/api/v1/coverage?" + urllib.parse.urlencode(filters))

    def publishers(self) -> list[dict]:
        return self.request("/api/v1/coverage/publishers?source_id=" + SOURCE)["items"]

    def publisher(self, observer: str) -> dict:
        rows = [
            row for row in self.publishers() if row["runner_context"]["id"] == observer
        ]
        assert len(rows) <= 1, "One persisted installation created duplicate publishers"
        return next(iter(rows))

    def scope(self, environment: str, target: str, key: str | None = None) -> dict:
        rows = [
            row
            for row in self.coverage_list(source_id=SOURCE, environment=environment)[
                "items"
            ]
            if matches_scope(row, environment, target, key)
        ]
        assert len(rows) <= 1, (
            "Exact declared identity created duplicate coverage scopes"
        )
        return next(iter(rows))

    def counted(
        self, environment: str, target: str, key: str | None = None, **counts: int
    ) -> dict | bool:
        row = self.scope(environment, target, key)
        return (
            row
            if all(row["counts"][name] == value for name, value in counts.items())
            else False
        )

    def observers(self, scope: dict) -> list[dict]:
        listing = self.request(f"/api/v1/coverage/{scope['id']}/observers")
        assert listing["total"] <= 4, "Unexpected observers in the isolated example"
        assert listing["total"] == len(listing["items"])
        return listing["items"]

    def result(self, observer: str, environment: str, key: str | None = None) -> dict:
        runner = self.identities[observer]
        rows = self.streams(runner_id=runner, environment=environment)["items"]
        rows = [
            row
            for row in rows
            if row["source_id"] == SOURCE and (key is None or row["source_key"] == key)
        ]
        assert len(rows) <= 1, (
            "Result selection must retain observer and check identity"
        )
        return next(iter(rows))

    def measured(
        self,
        observer: str,
        environment: str,
        health: str = "OK",
        after: datetime | None = None,
        key: str | None = None,
    ) -> dict | bool:
        row = self.result(observer, environment, key)
        return row if fresh_desired(row, health, after) else False

    def samples(self, changes: dict[str, dict]) -> datetime:
        self.mode(grouped_samples=changes)
        return datetime.now(UTC)

    def incident_for(self, row: dict, status: str = "open") -> dict:
        matches = [
            item
            for item in self.detail(row)["incidents"]
            if item["stream_id"] == row["id"] and item["status"] == status
        ]
        assert len(matches) <= 1 or status != "open", (
            "One result opened duplicate incidents"
        )
        return next(iter(matches))

    def remember(self, observer: str) -> dict:
        publisher = self.publisher(observer)
        if observer in self.identities:
            assert publisher["runner_id"] == self.identities[observer]
        self.identities[observer] = publisher["runner_id"]
        return publisher

    def runner_inventory(self, service: str) -> dict:
        script = """
import json, sqlite3
from contextlib import closing
with closing(sqlite3.connect('file:/state/runner.sqlite3?mode=ro', uri=True)) as db:
    db.execute('BEGIN')
    metadata = dict(db.execute('SELECT key,value FROM metadata'))
    print(json.dumps(dict(version=1,complete=True,installation_id=metadata['installation_id'],session_id=metadata['session_id'],boot=int(metadata['boot']),**json.loads(metadata['inventory']))))
"""
        return json.loads(
            self.compose("exec", "-T", service, "python", "-c", script, capture=True)
        )

    def runner_status(self, service: str) -> dict:
        return json.loads(
            self.compose(
                "exec",
                "-T",
                service,
                "python",
                "-m",
                "mondek_runner",
                "--status",
                capture=True,
            )
        )

    def installed_source(self, service: str) -> str:
        return self.compose(
            "exec",
            "-T",
            service,
            "python",
            "-c",
            "from pathlib import Path; import importlib.util; print(Path(importlib.util.find_spec('mondek_examples.coverage').origin).read_text(),end='')",
            capture=True,
        )

    def deploy_source(self, service: str, source: str) -> None:
        script = (
            "from pathlib import Path; import importlib.util; p=Path(importlib.util.find_spec('mondek_examples.coverage').origin); "
            + f"p.write_text({source!r})"
        )
        self.compose("exec", "-T", "--user", "0", service, "python", "-c", script)
        self.compose("restart", service)

    def capture(self, name: str) -> dict:
        evidence = {
            "scopes": self.coverage_list(source_id=SOURCE),
            "publishers": self.publishers(),
            "diagnostics": self.request(
                "/api/v1/coverage/diagnostics?source_id=" + SOURCE
            ),
        }
        (self.output / f"coverage-{name}.json").write_text(
            json.dumps(evidence, indent=2)
        )
        return evidence

    def clean_start(self) -> dict:
        self.compose(
            "up", "--build", "--detach", "--wait", "--wait-timeout", "180", NODE_A
        )
        self.eventually(
            "Node A publishes its complete roster",
            lambda: self.remember("node-a"),
            timeout=180,
        )
        node_b = self.eventually(
            "never-installed Node B is already declared",
            lambda: self.counted(
                "production",
                "node:node-b",
                "root-disk-node-b",
                declaring=1,
                selected=0,
                fresh=0,
            ),
        )
        assert node_b["status"] == "missing"
        assert len(self.publishers()) == 1
        assert self.coverage_list(source_id=SOURCE)["total"] == 5
        self.eventually(
            "Node A measures only its own root filesystem",
            lambda: self.measured("node-a", "production", key="root-disk-node-a"),
        )
        assert all(row["exclusion_reason"] for row in self.observers(node_b))
        self.capture("node-a-only")

        self.compose(
            "up",
            "--build",
            "--detach",
            "--wait",
            "--wait-timeout",
            "180",
            SERVICE_A,
            SERVICE_B,
        )
        for observer in ("service-a", "service-b"):
            self.eventually(
                "independent service publisher " + observer,
                lambda observer=observer: self.remember(observer),
            )
        staging = self.eventually(
            "two independent observers measure Staging",
            lambda: self.counted(
                "staging", SERVICE_TARGET, declaring=3, selected=2, admitted=2, fresh=2
            ),
            timeout=120,
        )
        production = self.counted(
            "production", SERVICE_TARGET, declaring=3, selected=0, fresh=0
        )
        assert production and production["status"] == "missing"
        assert all(row["exclusion_reason"] for row in self.observers(production))
        assert (
            len(
                {row["stream_id"] for row in self.observers(staging) if row["selected"]}
            )
            == 2
        )
        filtered = self.coverage_list(
            runner_id=self.identities["service-a"], environment="staging"
        )
        assert len(filtered["items"]) == 1
        assert filtered["items"][0]["counts"] == staging["counts"]
        publishers = self.publishers()
        assert len({row["code_revision"] for row in publishers}) == 1
        assert len({row["runtime_revision"] for row in publishers}) == 1
        diagnostics = self.request("/api/v1/coverage/diagnostics?source_id=" + SOURCE)
        assert diagnostics["total"] == 2
        assert all(
            not row["scope_resolved"] and not row["selected"] and row["scope_reason"]
            for row in diagnostics["items"]
        )
        self.capture("initial-gaps")
        return {
            "declared_scopes": 5,
            "initial_publishers": 3,
            "never_installed_scope": node_b["id"],
            "excluded_production_scope": production["id"],
        }

    def restore_missing_placement(self) -> dict:
        production = self.scope("production", SERVICE_TARGET)
        node_b = self.scope("production", "node:node-b", "root-disk-node-b")
        prior_b = self.publisher("service-b")
        self.compose(
            "up", "--build", "--detach", "--wait", "--wait-timeout", "180", NODE_B
        )
        self.eventually(
            "Node B publishes its persisted installation",
            lambda: self.remember("node-b"),
        )
        self.env["MONDEK_COVERAGE_ACCESS_B"] = "staging,production"
        self.compose(
            "up",
            "--detach",
            "--force-recreate",
            "--wait",
            "--wait-timeout",
            "120",
            SERVICE_B,
        )
        self.eventually(
            "restored Production requires its own desired-generation measurement",
            lambda: self.counted(
                "production",
                SERVICE_TARGET,
                declaring=4,
                selected=1,
                admitted=1,
                fresh=1,
            ),
            timeout=120,
        )
        self.eventually(
            "installed Node B measures its declared scope",
            lambda: self.counted(
                "production",
                "node:node-b",
                "root-disk-node-b",
                declaring=4,
                selected=1,
                admitted=1,
                fresh=1,
            ),
        )
        assert self.scope("production", SERVICE_TARGET)["id"] == production["id"]
        assert (
            self.scope("production", "node:node-b", "root-disk-node-b")["id"]
            == node_b["id"]
        )
        assert self.coverage_list(source_id=SOURCE)["total"] == 6
        current_b = self.remember("service-b")
        assert current_b["id"] == prior_b["id"]
        assert current_b["code_revision"] == prior_b["code_revision"]
        assert current_b["source_revision"] != prior_b["source_revision"]
        self.capture("restored-placement")
        return {
            "declared_scopes": 6,
            "publishers": 4,
            "production_scope": production["id"],
            "node_b_scope": node_b["id"],
        }

    def independent_health_and_visibility(self) -> dict:
        boundary = self.samples(
            {
                "coverage-service-a-staging/elasticsearch": {"used_percent": 96},
                "coverage-service-b-staging/elasticsearch": {"used_percent": 96},
            }
        )
        failed = {
            observer: self.eventually(
                "fresh critical measurement from " + observer,
                lambda observer=observer: self.measured(
                    observer, "staging", "CRIT", boundary
                ),
            )
            for observer in ("service-a", "service-b")
        }
        incidents = {
            observer: self.incident_for(row) for observer, row in failed.items()
        }
        assert len({row["id"] for row in incidents.values()}) == 2
        self.eventually(
            "fresh critical results establish measured coverage",
            lambda: self.counted("staging", SERVICE_TARGET, selected=2, fresh=2),
        )
        boundary = self.samples(
            {
                "coverage-service-a-staging/elasticsearch": {"available": False},
                "coverage-service-b-staging/elasticsearch": dict(HEALTHY),
            }
        )
        self.eventually(
            "one observer recovers independently",
            lambda: self.measured("service-b", "staging", "OK", boundary),
        )
        self.eventually(
            "unavailable collection cannot borrow retained critical health",
            lambda: self.counted(
                "staging", SERVICE_TARGET, selected=2, fresh=1, unavailable=1
            ),
        )
        assert (
            self.incident_for(failed["service-a"])["id"] == incidents["service-a"]["id"]
        )
        recovered = self.request("/api/v1/incidents/" + incidents["service-b"]["id"])[
            "incident"
        ]
        assert (
            recovered["status"] == "closed"
            and recovered["closure_reason"] == "measured_recovery"
        )
        self.capture("partial-unavailable")
        self.samples(
            {
                "coverage-service-a-staging/elasticsearch": {
                    "available": True,
                    "sample_age_seconds": 60,
                }
            }
        )
        self.eventually(
            "old source time cannot establish fresh coverage",
            lambda: self.counted(
                "staging", SERVICE_TARGET, selected=2, fresh=1, stale=1
            ),
        )
        assert (
            self.incident_for(failed["service-a"])["id"] == incidents["service-a"]["id"]
        )
        self.capture("partial-stale")
        boundary = self.samples(
            {"coverage-service-a-staging/elasticsearch": dict(HEALTHY)}
        )
        self.eventually(
            "a new desired measurement restores the unavailable observer",
            lambda: self.measured("service-a", "staging", "OK", boundary),
        )
        self.eventually(
            "both independent scopes are measured again",
            lambda: self.counted("staging", SERVICE_TARGET, selected=2, fresh=2),
        )
        assert (
            self.request("/api/v1/incidents/" + incidents["service-a"]["id"])[
                "incident"
            ]["closure_reason"]
            == "measured_recovery"
        )
        return {
            "independent_incidents": {
                observer: row["id"] for observer, row in incidents.items()
            },
            "critical_established_coverage": True,
            "unavailable_and_stale_did_not": True,
        }

    def rejected_catalogue_and_withdrawal(self) -> dict:
        before = publisher_authority(self.publisher("service-a"))
        envelope = self.runner_inventory(SERVICE_A)
        replay = self.request("/api/v1/inventory", envelope)
        assert replay["inventory_revision"] == envelope["inventory_revision"]
        assert publisher_authority(self.publisher("service-a")) == before

        rejected = copy.deepcopy(envelope)
        rejected["inventory_revision"] += 1
        rejected["coverage"]["version"] = 999
        self.request("/api/v1/inventory", rejected, code=422)
        assert publisher_authority(self.publisher("service-a")) == before
        conflict = copy.deepcopy(envelope)
        conflict["coverage"]["code_revision"] = "0" * 64
        assert (
            conflict["coverage"]["code_revision"]
            != envelope["coverage"]["code_revision"]
        )
        self.request("/api/v1/inventory", conflict, code=409)
        assert publisher_authority(self.publisher("service-a")) == before
        assert self.counted("staging", SERVICE_TARGET, declaring=4, selected=2, fresh=2)

        original = self.installed_source(SERVICE_A)
        previous = self.eventually(
            "healthy desired measurement before failed discovery",
            lambda: self.measured("service-a", "staging"),
        )
        previous_status = self.runner_status(SERVICE_A)
        deploy_boundary = datetime.now(UTC)
        try:
            self.deploy_source(
                SERVICE_A,
                "raise RuntimeError('intentional coverage discovery failure')\n",
            )
            fallback_status = self.eventually(
                "failed discovery is visible in the restarted runner session",
                lambda: (
                    status
                    if (status := self.runner_status(SERVICE_A))["boot"]
                    > previous_status["boot"]
                    and "intentional coverage discovery failure"
                    in status.get("diagnostic", "")
                    else False
                ),
            )
            fallback = self.eventually(
                "accepted source still measures after failed discovery",
                lambda: (
                    row
                    if fresh_after_restart(
                        row := self.result("service-a", "staging"),
                        previous,
                        deploy_boundary,
                        fallback_status["session_id"],
                    )
                    else False
                ),
            )
            assert publisher_authority(self.publisher("service-a")) == before
            assert self.scope("production", SERVICE_TARGET)["counts"]["declaring"] == 4
            self.capture("rejected-and-failed-discovery")
        finally:
            restore_boundary = datetime.now(UTC)
            self.deploy_source(SERVICE_A, original)
        restore_status = self.eventually(
            "restoring the source starts another runner session",
            lambda: (
                status
                if (status := self.runner_status(SERVICE_A))["boot"]
                > fallback_status["boot"]
                else False
            ),
        )
        restored_measurement = self.eventually(
            "restored source resumes desired measurements",
            lambda: (
                row
                if fresh_after_restart(
                    row := self.result("service-a", "staging"),
                    fallback,
                    restore_boundary,
                    restore_status["session_id"],
                )
                else False
            ),
        )

        boundary = self.samples(
            {"coverage-service-a-staging/elasticsearch": {"used_percent": 96}}
        )
        failed = self.eventually(
            "one observer fails before source withdrawal",
            lambda: self.measured("service-a", "staging", "CRIT", boundary),
        )
        incident = self.incident_for(failed)
        production_id = self.scope("production", SERVICE_TARGET)["id"]
        try:
            self.deploy_source(SERVICE_A, original + "\napp.bindings.clear()\n")
            remaining = self.eventually(
                "empty complete publication removes only its publisher's claims",
                lambda: self.counted(
                    "staging", SERVICE_TARGET, declaring=3, selected=1, fresh=1
                ),
            )
            publisher = self.publisher("service-a")
            assert publisher["coverage_confirmed"] and publisher["declarations"] == 0
            assert self.scope("production", SERVICE_TARGET)["id"] == production_id
            assert self.scope("production", SERVICE_TARGET)["counts"]["declaring"] == 3
            closed = self.request("/api/v1/incidents/" + incident["id"])["incident"]
            assert closed["status"] == "closed"
            assert closed["closure_reason"] == "source_removed"
            assert closed["closing_observation_id"] is None
            assert self.detail(failed)["stream"]["retired"]
            self.capture("one-publisher-withdrawn")
        finally:
            self.samples({"coverage-service-a-staging/elasticsearch": dict(HEALTHY)})
            self.deploy_source(SERVICE_A, original)
        restored = self.eventually(
            "restored source supplies a new admitted result incarnation",
            lambda: self.measured("service-a", "staging"),
            timeout=120,
        )
        assert restored["id"] != failed["id"]
        self.eventually(
            "all publishers' declarations return",
            lambda: self.counted(
                "staging", SERVICE_TARGET, declaring=4, selected=2, fresh=2
            ),
        )
        return {
            "replay_preserved": before,
            "rejected_revision": rejected["inventory_revision"],
            "shared_scope_retained": remaining["id"],
            "withdrawn_incident": incident["id"],
            "restored_stream": restored["id"],
            "failed_discovery_measurement": fallback["current"],
            "restored_source_measurement": restored_measurement["current"],
        }

    def deployment_identity_and_declaration_differences(self) -> dict:
        before = self.publisher("service-b")
        self.env["MONDEK_COVERAGE_URL_B"] = "http://target:8080//"
        self.compose(
            "up",
            "--detach",
            "--force-recreate",
            "--wait",
            "--wait-timeout",
            "120",
            SERVICE_B,
        )
        changed = self.eventually(
            "private connection settings create a new executable revision",
            lambda: (
                row
                if (row := self.remember("service-b"))["source_revision"]
                != before["source_revision"]
                else False
            ),
        )
        self.eventually(
            "the private settings revision produces its own desired evidence",
            lambda: self.counted("production", SERVICE_TARGET, fresh=1),
        )
        assert changed["code_revision"] == before["code_revision"]
        assert changed["runtime_revision"] == before["runtime_revision"]
        assert self.scope("staging", SERVICE_TARGET)["definition_variants"] == 1
        assert self.scope("staging", SERVICE_TARGET)["code_variants"] == 1

        original = self.installed_source(SERVICE_B)
        revision = original.replace(
            'name="Search service capacity"', 'name="Search capacity revised"'
        )
        assert revision != original
        try:
            self.deploy_source(SERVICE_B, revision)
            different = self.eventually(
                "different public definitions are inspectable",
                lambda: (
                    row
                    if (row := self.scope("staging", SERVICE_TARGET))["code_variants"]
                    == 2
                    and row["definition_variants"] == 2
                    else False
                ),
            )
            assert different["runtime_variants"] == 1
            assert different["counts"]["declaring"] == 4
            self.eventually(
                "both differing deployments establish their own fresh evidence",
                lambda: self.counted("staging", SERVICE_TARGET, fresh=2),
            )
            self.capture("code-and-declaration-differences")
        finally:
            self.deploy_source(SERVICE_B, original)
        self.eventually(
            "the restored common source measures Production",
            lambda: self.measured("service-b", "production"),
        )
        self.eventually(
            "comparable source identity converges again",
            lambda: self.scope("staging", SERVICE_TARGET)["code_variants"] == 1,
        )
        return {
            "private_source_revision_changed": True,
            "private_code_revision_unchanged": before["code_revision"],
            "code_variants_exercised": 2,
            "definition_variants_exercised": 2,
        }

    def offline_restart_and_reconnect(self) -> dict:
        before = self.result("service-b", "production")
        publisher = publisher_authority(self.publisher("service-b"))
        baseline = self.node_journal(SERVICE_B)
        captures = []
        self.mode(offline_installations=[self.identities["service-b"]])
        boundary = datetime.now(UTC)
        try:

            def queued() -> dict | bool:
                sample = self.node_journal(SERVICE_B)
                reports = [
                    report
                    for report in sample["reports"]
                    if after_boundary(report["started_at"], boundary)
                ]
                return sample if len(reports) >= 3 else False

            offline = self.eventually(
                "the disconnected installed runner keeps executing", queued
            )
            captures.append(offline)
            original = [
                report
                for report in offline["reports"]
                if after_boundary(report["started_at"], boundary)
            ]
            self.eventually(
                "expired source evidence and lost contact leave Production uncovered",
                lambda: self.counted(
                    "production",
                    SERVICE_TARGET,
                    declaring=4,
                    selected=1,
                    fresh=0,
                    offline=1,
                ),
                timeout=45,
            )
            self.eventually(
                "another Staging observer still provides independent visibility",
                lambda: self.counted(
                    "staging", SERVICE_TARGET, selected=2, fresh=1, offline=1
                ),
            )
            assert publisher_authority(self.publisher("service-b")) == publisher
            self.capture("offline")

            self.compose("restart", "controller", SERVICE_B)
            self.eventually(
                "controller restarts with its retained declarations",
                lambda: self.coverage_list(source_id=SOURCE)["total"] == 6,
                timeout=90,
            )
            restarted = self.eventually(
                "runner persists identity while starting a new session",
                lambda: (
                    sample
                    if (sample := self.node_journal(SERVICE_B))["status"]["boot"]
                    > baseline["status"]["boot"]
                    and any(
                        report["session_id"] == sample["status"]["session_id"]
                        for report in sample["reports"]
                    )
                    else False
                ),
                timeout=90,
            )
            captures.append(restarted)
            assert restarted["status"]["installation_id"] == before["runner_id"]
            assert restarted["status"]["dropped"] == baseline["status"]["dropped"]
            buffered = {report["id"]: report for report in restarted["reports"]}
            assert all(buffered[report["id"]] == report for report in original)
            assert publisher_authority(self.publisher("service-b")) == publisher

            self.mode(offline_installations=[])
            stored = self.eventually(
                "original buffered evidence is durably received without rewritten age",
                lambda: (
                    rows
                    if len(
                        rows := self.stored_reports(
                            [report["id"] for report in original]
                        )
                    )
                    == len(original)
                    else False
                ),
                timeout=90,
            )
            proof = exact_buffered_evidence(original, stored)
            assert proof["historical"] == len(original)
            fresh = self.eventually(
                "only the new session's own desired measurement restores coverage",
                lambda: (
                    row
                    if (row := self.measured("service-b", "production"))
                    and row["current"]["session_id"]
                    == restarted["status"]["session_id"]
                    else False
                ),
                timeout=90,
            )
            for field in (
                "id",
                "assignment_id",
                "runner_id",
                "source_revision",
                "desired_generation",
            ):
                assert fresh[field] == before[field], f"Restart replaced {field}"
            assert publisher_authority(self.publisher("service-b")) == publisher
            self.eventually(
                "all declared placements are measured after reconnect",
                lambda: self.counted("staging", SERVICE_TARGET, selected=2, fresh=2),
            )
            self.eventually(
                "Production has independently measured coverage again",
                lambda: self.counted("production", SERVICE_TARGET, selected=1, fresh=1),
            )
            self.capture("reconnected")
            return {
                "preserved_publisher": publisher,
                "preserved_stream": fresh["id"],
                **proof,
            }
        finally:
            (self.output / "coverage-offline-journal.json").write_text(
                json.dumps(captures, indent=2)
            )
            self.mode(offline_installations=[])

    def run(self) -> None:
        print(
            f"Coverage project: {self.project}; UI: {self.base}/coverage; evidence: {self.output}",
            flush=True,
        )
        success = False
        try:
            for label, action in (
                (
                    "complete declarations reveal never-installed nodes and zero-selected environments",
                    self.clean_start,
                ),
                (
                    "suitable observers restore placement only with desired measurements",
                    self.restore_missing_placement,
                ),
                (
                    "independent critical, unavailable, stale and recovery evidence",
                    self.independent_health_and_visibility,
                ),
                (
                    "replay, rejected catalogue, failed discovery and publisher-specific withdrawal",
                    self.rejected_catalogue_and_withdrawal,
                ),
                (
                    "private deployment settings and public source differences remain distinct",
                    self.deployment_identity_and_declaration_differences,
                ),
                (
                    "controller/runner restart and actual reconnect preserve accepted declarations and original evidence",
                    self.offline_restart_and_reconnect,
                ),
            ):
                self.run_step(label, action)
            success = True
        finally:
            self.finish(success)
            print(f"Evidence: {self.output}", flush=True)
        print("All real declared-coverage scenarios passed.", flush=True)


if __name__ == "__main__":
    CoverageAcceptance().run()
