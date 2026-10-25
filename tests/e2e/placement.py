#!/usr/bin/env python3
# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""One installed project selects node and service checks across three observers."""

from __future__ import annotations

import json
from datetime import UTC, datetime
from typing import Any

from acceptance import run_compose
from parity import ParityAcceptance
from parity_transport import exact_buffered_evidence

NODE_A = "placement-node-a"
NODE_B = "placement-node-b"
SHARED = "placement-shared-services"
SERVICES = (NODE_A, NODE_B, SHARED)
TARGETS = ("node:node-a", "node:node-b", "staging", "production")


class PlacementAcceptance(ParityAcceptance):
    def __init__(self) -> None:
        super().__init__()

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
                "examples/compose/placement.yaml",
                *args,
            ],
            env=self.env,
            log=self.log,
            capture=capture,
            timeout=timeout,
        )

    def cohort(self) -> dict[str, dict[str, Any]] | bool:
        rows = {row["target"]["key"]: row for row in self.streams()["items"]}
        if set(rows) != set(TARGETS):
            return False
        return (
            rows
            if all(
                row["current"].get("knowledge") == "fresh"
                and row["current"].get("health") == "OK"
                for row in rows.values()
            )
            else False
        )

    def installed_source(self, service: str) -> str:
        return self.compose(
            "exec",
            "-T",
            service,
            "python",
            "-c",
            "from pathlib import Path; import importlib.util; "
            "print(Path(importlib.util.find_spec('mondek_examples.placement').origin).read_text(),end='')",
            capture=True,
        )

    def runner_status(self, service: str) -> dict[str, Any]:
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

    def deploy_source(self, service: str, source: str) -> None:
        # Only the installed package inside this disposable Compose project is
        # changed; the tracked example and other installations are untouched.
        script = (
            "from pathlib import Path; import importlib.util; "
            "p=Path(importlib.util.find_spec('mondek_examples.placement').origin); "
            f"p.write_text({source!r})"
        )
        self.compose("exec", "-T", "--user", "0", service, "python", "-c", script)
        self.compose("restart", service)

    def clean_start(self) -> dict[str, Any]:
        self.compose(
            "up", "--build", "--detach", "--wait", "--wait-timeout", "180", *SERVICES
        )
        rows = self.eventually(
            "two node measurements and two environments on the shared observer",
            self.cohort,
            timeout=180,
        )
        overview = self.overview()
        assert overview["runner_count"] == 3
        assert overview["coverage"]["expected_count"] == 4
        assert len({row["runner_id"] for row in rows.values()}) == 3
        for row in rows.values():
            assert row["source_id"] == "execution-placement"
            assert row["current"]["value"] is not None
        assert rows[TARGETS[0]]["environment"] == "production"
        assert rows[TARGETS[1]]["environment"] == "production"
        assert rows[TARGETS[2]]["environment"] == "staging"
        assert rows[TARGETS[3]]["environment"] == "production"
        assert rows[TARGETS[2]]["runner_id"] == rows[TARGETS[3]]["runner_id"]
        assert rows[TARGETS[2]]["assignment_id"] != rows[TARGETS[3]]["assignment_id"]
        for target, expected in zip(TARGETS, (1, 1, 2, 2), strict=True):
            assert (
                self.streams(runner_id=rows[target]["runner_id"])["total"] == expected
            )
        sources = [self.installed_source(service) for service in SERVICES]
        assert all(source == sources[0] for source in sources)
        # Node images contain SharedHTTP and its check, but no URL/registration.
        for service in (NODE_A, NODE_B):
            self.compose(
                "exec",
                "-T",
                service,
                "python",
                "-c",
                "from mondek_examples.placement import app,SharedHTTP; "
                "assert SharedHTTP not in app._providers; "
                "assert len(app.bindings)==3; assert len(app.metadata('a'*64))==1",
            )
        running = set(
            self.compose(
                "ps", "--services", "--status", "running", capture=True
            ).splitlines()
        )
        assert running == {*SERVICES, "controller", "postgres", "target"}
        return {
            "observers": 3,
            "eligible_results": 4,
            "shared_observer_environments": ["staging", "production"],
            "identical_installed_source": True,
        }

    def service_failure_and_recovery(self) -> dict[str, Any]:
        self.mode(ready=False)
        failed = self.eventually(
            "shared observer measures HTTP failure",
            lambda: self.fresh(TARGETS[2], "CRIT"),
        )
        incident = next(
            item
            for item in self.detail(failed)["incidents"]
            if item["status"] == "open"
        )
        assert all(self.fresh(target) for target in (*TARGETS[:2], TARGETS[3]))
        self.eventually(
            "local firing notification is delivered",
            lambda: any(
                row["payload"].get("incident_id") == incident["id"]
                and row["payload"].get("kind") == "firing"
                for row in self.records()
            ),
        )
        self.mode(ready=True)
        self.eventually("new HTTP measurement recovers", lambda: self.fresh(TARGETS[2]))
        closed = self.eventually(
            "the incident closes with measured recovery",
            lambda: next(
                (
                    item
                    for item in self.detail(failed)["incidents"]
                    if item["id"] == incident["id"] and item["status"] == "closed"
                ),
                None,
            ),
        )
        assert closed["closure_reason"] == "measured_recovery"
        return {
            "incident_id": incident["id"],
            "closing_observation_id": closed["closing_observation_id"],
        }

    def offline_accepted_placement(self) -> dict[str, Any]:
        original_source = self.installed_source(NODE_A)
        before = self.stream(TARGETS[0])
        identity = before["runner_id"]
        baseline = self.node_journal(NODE_A)
        peers = {
            target: self.stream(target)["current"]["observation_id"]
            for target in TARGETS[1:]
        }
        captured: list[dict[str, Any]] = []
        try:
            self.mode(offline_installations=[identity])
            offline = self.eventually(
                "node A continues to measure while disconnected",
                lambda: (
                    sample
                    if len((sample := self.node_journal(NODE_A))["reports"]) >= 2
                    else False
                ),
            )
            original = offline["reports"]
            captured.append(offline)
            self.eventually(
                "other node and both shared environments keep collecting",
                lambda: all(
                    (row := self.fresh(target))
                    and row["current"]["observation_id"] != previous
                    for target, previous in peers.items()
                ),
            )
            # A failed deployment during disconnection must retain the accepted
            # package, target selection and explicit construction environment.
            self.deploy_source(
                NODE_A,
                "raise RuntimeError('intentional broken placement deployment')\n",
            )
            restarted = self.eventually(
                "accepted node placement survives offline runner restart",
                lambda: (
                    sample
                    if (sample := self.node_journal(NODE_A))["status"]["boot"]
                    > baseline["status"]["boot"]
                    and any(
                        report["session_id"] == sample["status"]["session_id"]
                        for report in sample["reports"]
                    )
                    else False
                ),
                timeout=90,
            )
            captured.append(restarted)
            assert restarted["status"]["installation_id"] == identity
            assert restarted["status"]["dropped"] == baseline["status"]["dropped"]
            assert {report["assignment_id"] for report in restarted["reports"]} == {
                before["assignment_id"]
            }
            buffered = {report["id"]: report for report in restarted["reports"]}
            assert all(buffered[report["id"]] == report for report in original)
            self.mode(offline_installations=[])
            committed = self.eventually(
                "buffered node evidence commits without rewritten identities or age",
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
            proof = exact_buffered_evidence(original, committed)
            assert proof["historical"] == len(original)
            restored = self.eventually(
                "the accepted node check resumes from its new session",
                lambda: (
                    row
                    if (row := self.fresh(TARGETS[0]))
                    and row["current"]["session_id"]
                    == restarted["status"]["session_id"]
                    else False
                ),
                timeout=90,
            )
            assert restored["id"] == before["id"]
            assert restored["source_revision"] == before["source_revision"]
            assert self.streams(runner_id=identity)["total"] == 1
            assert self.overview()["coverage"]["expected_count"] == 4
            return {"retained_stream": before["id"], **proof}
        finally:
            (self.output / "placement-offline-journal.json").write_text(
                json.dumps(captured, indent=2)
            )
            self.mode(offline_installations=[])
            self.deploy_source(NODE_A, original_source)
            self.eventually(
                "all selected checks restore healthy coverage", self.cohort, timeout=90
            )

    def intentional_placement_withdrawal(self) -> dict[str, Any]:
        original = self.installed_source(SHARED)
        self.mode(ready=False)
        failed = self.eventually(
            "HTTP failure before placement withdrawal",
            lambda: self.fresh(TARGETS[2], "CRIT"),
        )
        incident = next(
            item
            for item in self.detail(failed)["incidents"]
            if item["status"] == "open"
        )
        replacement = original.replace(
            'requires=("service-query",)',
            'requires=("disabled-service-query",)',
        )
        assert replacement != original
        try:
            self.deploy_source(SHARED, replacement)
            retired = self.eventually(
                "a complete inventory with no eligible checks retires old coverage",
                lambda: (
                    detail
                    if (detail := self.detail(failed))["stream"]["retired"]
                    else False
                ),
                timeout=90,
            )
            closed = next(
                item for item in retired["incidents"] if item["id"] == incident["id"]
            )
            assert closed["status"] == "closed"
            assert closed["closure_reason"] == "source_removed"
            assert closed["closing_observation_id"] is None
            assert self.overview()["coverage"]["expected_count"] == 2
            assert all(self.fresh(target) for target in TARGETS[:2])
        finally:
            self.mode(ready=True)
            self.deploy_source(SHARED, original)
        restored = self.eventually(
            "restored placement creates fresh active coverage",
            lambda: self.fresh(TARGETS[2]),
            timeout=90,
        )
        assert restored["id"] != failed["id"]
        return {
            "retired_stream": failed["id"],
            "closure_reason": closed["closure_reason"],
            "restored_stream": restored["id"],
        }

    def scoped_access_and_failed_policy(self) -> dict[str, Any]:
        original = self.installed_source(SHARED)
        staging = self.stream("staging")
        self.mode(secondary_ready=False)
        production = self.eventually(
            "Production fails independently before scoped access changes",
            lambda: self.fresh("production", "CRIT"),
        )
        incident = next(
            item
            for item in self.detail(production)["incidents"]
            if item["status"] == "open"
        )
        restricted = original.replace('"staging,production"', '"staging"')
        assert restricted != original
        try:
            self.deploy_source(SHARED, restricted)
            retired = self.eventually(
                "restricting access retires only the unsupported Production scope",
                lambda: (
                    detail
                    if (detail := self.detail(production))["stream"]["retired"]
                    and self.overview()["coverage"]["expected_count"] == 3
                    else False
                ),
            )
            closed = next(
                item for item in retired["incidents"] if item["id"] == incident["id"]
            )
            assert closed["closure_reason"] == "source_removed"
            assert closed["closing_observation_id"] is None
            retained = self.eventually(
                "Staging remains independently measured", lambda: self.fresh("staging")
            )
            assert retained["id"] == staging["id"]
            assert retained["assignment_id"] == staging["assignment_id"]
            assert all(self.fresh(target) for target in TARGETS[:2])

            broken = restricted.replace(
                "class SharedHTTP(Datasource):",
                "def broken_policy(context):\n"
                "    raise ValueError('intentional placement policy failure')\n\n\n"
                "class SharedHTTP(Datasource):",
            ).replace(
                'requires=("service-query",),',
                'requires=("service-query",), policy=broken_policy,',
            )
            self.deploy_source(SHARED, broken)
            status = self.eventually(
                "failed placement policy remains visible as a discovery error",
                lambda: (
                    sample
                    if "intentional placement policy failure"
                    in (sample := self.runner_status(SHARED)).get("diagnostic", "")
                    else False
                ),
            )
            resumed = self.eventually(
                "accepted scoped checks still execute after the failed policy deployment",
                lambda: (
                    row
                    if (row := self.fresh("staging"))
                    and row["current"]["session_id"] == status["session_id"]
                    else False
                ),
            )
            assert resumed["id"] == staging["id"]
            assert resumed["source_revision"] == retained["source_revision"]
            assert self.streams(runner_id=resumed["runner_id"])["total"] == 1
        finally:
            self.mode(secondary_ready=True)
            self.deploy_source(SHARED, original)
            rows = self.eventually(
                "full scoped access restores four fresh results", self.cohort
            )
        assert rows["production"]["id"] != production["id"]
        return {
            "retained_staging_stream": staging["id"],
            "retired_production_stream": production["id"],
            "restored_production_stream": rows["production"]["id"],
            "failed_policy_preserved_accepted_source": True,
        }

    def run(self) -> None:
        print(
            f"Placement project: {self.project}; UI: {self.base}; evidence: {self.output}",
            flush=True,
        )
        success = False
        try:
            for label, function in (
                (
                    "identical project selects nodes and two shared environments",
                    self.clean_start,
                ),
                (
                    "real HTTP failure, local notification and measured recovery",
                    self.service_failure_and_recovery,
                ),
                (
                    "accepted placement survives failed deployment, offline restart and reconnect",
                    self.offline_accepted_placement,
                ),
                (
                    "intentional placement withdrawal preserves incident history",
                    self.intentional_placement_withdrawal,
                ),
                (
                    "scoped access isolates environments and failed policy preserves coverage",
                    self.scoped_access_and_failed_policy,
                ),
            ):
                self.run_step(label, function)
            success = True
        finally:
            try:
                for name, read in (
                    ("snapshot", self.snapshot),
                    ("overview", self.overview),
                    ("receipts", self.records),
                ):
                    try:
                        (self.output / f"{name}.json").write_text(
                            json.dumps(read(), indent=2)
                        )
                    except Exception:
                        pass
                (self.output / "placement-results.json").write_text(
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
                    self.compose("logs", "--no-color", "--tail", "250")
                finally:
                    try:
                        self.compose("down", "--volumes", "--remove-orphans")
                    finally:
                        self.log.close()
            print(f"Evidence: {self.output}", flush=True)
        assert success
        print("All real execution-placement scenarios passed.", flush=True)


if __name__ == "__main__":
    PlacementAcceptance().run()
