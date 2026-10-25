#!/usr/bin/env python3
# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Durable parameter rules follow a real file-backed logical volume across nodes."""

from __future__ import annotations

import json
from typing import Any

from acceptance import run_compose
from parity import ParityAcceptance
from parity_transport import exact_buffered_evidence

NODE_A = "rules-a-runner"
NODE_B = "rules-b-runner"
TARGET = "volume:orders"
SOURCE = "durable-volume-monitoring"
CONTRACT = "volume.pending-items.v1"
DEFAULTS = {"warning_items": 50, "critical_items": 100}
RULE_PARAMS = {"warning_items": 5, "critical_items": 10}
RULE_FIELDS = (
    "id",
    "revision",
    "name",
    "source_id",
    "parameter_contract",
    "environment",
    "target_kind",
    "target_key",
    "priority",
    "enabled",
    "parameter_schema",
    "params",
)
DECLARATIONS = [
    {"id": "orders", "label": "Orders volume", "path": "/volume/orders.queue"}
]


class DurableRulesAcceptance(ParityAcceptance):
    def __init__(self) -> None:
        super().__init__()
        self.rule_id = ""
        self.original_incident = ""
        self.original_stream = ""
        self.original_assignment = ""
        self.rule_params = dict(RULE_PARAMS)

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
                "examples/compose/rules.yaml",
                *args,
            ],
            env=self.env,
            log=self.log,
            capture=capture,
            timeout=timeout,
        )

    def rule(self) -> dict[str, Any]:
        return self.request("/api/v1/configuration/rules/" + self.rule_id)

    def rules(self) -> dict[str, Any]:
        return self.request("/api/v1/configuration/rules")

    def apply_rule(self, proposal: dict[str, Any]) -> dict[str, Any]:
        proposal = {key: proposal[key] for key in RULE_FIELDS if key in proposal}
        preview = self.request(
            "/api/v1/configuration/rules/preview", {"proposal": proposal}
        )
        assert preview["counts"]["conflicts"] == 0, preview
        assert preview["review_token"], preview
        applied = self.request(
            "/api/v1/configuration/rules/apply",
            {
                "proposal": preview["proposal"],
                "review_token": preview["review_token"],
            },
        )
        self.rule_id = applied["rule"]["id"]
        return applied

    def edit_rule(self, **changes: Any) -> dict[str, Any]:
        return self.apply_rule(self.rule() | changes)

    def assignment_state(self, assignment_id: str | None = None) -> dict[str, Any]:
        assignment_id = assignment_id or self.stream(TARGET)["assignment_id"]
        return self.request("/api/v1/assignments/" + assignment_id)

    def measured(self, params: dict[str, int], health: str) -> dict[str, Any] | bool:
        row = self.stream(TARGET)
        assignment = self.assignment_state(row["assignment_id"])
        current = row["current"]
        return (
            row
            if (
                assignment["params"] == params
                and assignment["active_generation"] == assignment["desired_generation"]
                and current.get("confirmed_generation")
                == assignment["desired_generation"]
                and current.get("confirmed_params") == params
                and current.get("knowledge") == "fresh"
                and current.get("health") == health
            )
            else False
        )

    def set_membership(self, node: str, present: bool) -> None:
        content = json.dumps(DECLARATIONS if present else [])
        self.compose(
            "run",
            "--rm",
            "--no-deps",
            "rules-files",
            "python",
            "-c",
            f"from pathlib import Path; Path('/files-{node}/volumes.json').write_text({content!r})",
        )
        self.compose("restart", NODE_A if node == "a" else NODE_B)

    def installed_source(self, service: str) -> str:
        return self.compose(
            "exec",
            "-T",
            service,
            "python",
            "-c",
            "from pathlib import Path; import importlib.util; "
            "print(Path(importlib.util.find_spec('mondek_examples.durable').origin).read_text(),end='')",
            capture=True,
        )

    def deploy_source(self, service: str, source: str) -> None:
        self.compose(
            "exec",
            "-T",
            "--user",
            "0",
            service,
            "python",
            "-c",
            "from pathlib import Path; import importlib.util; "
            "p=Path(importlib.util.find_spec('mondek_examples.durable').origin); "
            f"p.write_text({source!r})",
        )
        self.compose("restart", service)

    def open_incident(self, row: dict[str, Any]) -> dict[str, Any]:
        return next(
            item for item in self.detail(row)["incidents"] if item["status"] == "open"
        )

    def empty_coverage(self) -> dict[str, Any] | bool:
        view = self.overview()
        return (
            view
            if view["coverage"]["expected_count"] == 0 and self.streams()["total"] == 0
            else False
        )

    def clean_start(self) -> dict[str, Any]:
        self.compose(
            "up",
            "--build",
            "--detach",
            "--wait",
            "--wait-timeout",
            "180",
            NODE_A,
            NODE_B,
        )
        row = self.eventually(
            "source default measures the real volume file",
            lambda: self.measured(DEFAULTS, "OK"),
            timeout=180,
        )
        self.eventually(
            "both independent observers register",
            lambda: self.overview()["runner_count"] == 2,
        )
        assert self.overview()["coverage"]["expected_count"] == 1
        assert row["current"]["value"] == 12
        assert row["source_id"] == SOURCE
        assert row["environment"] == "production"
        assert self.assignment_state()["configuration_origin"]["kind"] == "source"
        assert self.installed_source(NODE_A) == self.installed_source(NODE_B)
        self.original_stream = row["id"]
        self.original_assignment = row["assignment_id"]
        return {
            "observers": 2,
            "active_results": 1,
            "logical_target": TARGET,
            "source_defaults": DEFAULTS,
        }

    def create_target_rule(self) -> dict[str, Any]:
        proposal = self.request(
            "/api/v1/configuration/rules/seed/" + self.original_assignment
        )
        assert proposal["source_id"] == SOURCE
        assert proposal["parameter_contract"] == CONTRACT
        proposal.update(name="Orders volume limits", params=self.rule_params)
        result = self.apply_rule(proposal)
        assert result["changed_count"] == 1
        row = self.eventually(
            "target rule produces a real measured failure",
            lambda: self.measured(self.rule_params, "CRIT"),
        )
        incident = self.open_incident(row)
        self.original_incident = incident["id"]
        self.eventually(
            "old observer failure reaches the local receiver",
            lambda: any(
                item["payload"].get("incident_id") == incident["id"]
                and item["payload"].get("kind") == "firing"
                for item in self.records()
            ),
        )
        origin = self.assignment_state()["configuration_origin"]
        assert origin["kind"] == "rule" and origin["rule_id"] == self.rule_id
        return {
            "rule_id": self.rule_id,
            "incident_id": incident["id"],
            "origin": origin,
            "params": self.rule_params,
        }

    def move_volume_between_observers(self) -> dict[str, Any]:
        before_runner = self.stream(TARGET)["runner_id"]
        self.set_membership("a", False)
        self.eventually(
            "explicit withdrawal leaves zero expected results", self.empty_coverage
        )
        retired = self.request("/api/v1/checks/" + self.original_stream)
        incident = next(
            item
            for item in retired["incidents"]
            if item["id"] == self.original_incident
        )
        assert incident["status"] == "closed"
        assert incident["closure_reason"] == "source_removed"
        assert incident["closing_observation_id"] is None
        dormant = self.rule()
        assert dormant["match_count"] == 0
        saved_rule = {key: dormant[key] for key in RULE_FIELDS}
        self.compose("restart", "controller")
        persisted = self.eventually(
            "rule survives controller restart with zero matches", self.rule
        )
        assert persisted["match_count"] == 0
        assert {key: persisted[key] for key in RULE_FIELDS} == saved_rule
        # The subject is one persisted volume, not duplicate files per observer.
        # A data change during the coverage gap must be freshly measured on B.
        self.compose(
            "run",
            "--rm",
            "--no-deps",
            "rules-files",
            "python",
            "-c",
            "from pathlib import Path; Path('/volume/orders.queue').write_text('13\\n')",
        )
        self.set_membership("b", True)
        moved = self.eventually(
            "node B automatically inherits the durable target rule",
            lambda: self.measured(self.rule_params, "CRIT"),
        )
        assert moved["runner_id"] != before_runner
        assert moved["id"] != self.original_stream
        assert moved["assignment_id"] != self.original_assignment
        assert moved["current"]["value"] == 13
        new_incident = self.open_incident(moved)
        assert new_incident["id"] != self.original_incident
        assert all(
            item["id"] != self.original_incident
            for item in self.detail(moved)["incidents"]
        )
        assert self.rule()["match_count"] == 1
        assert self.assignment_state()["instance_exception"] is None
        self.eventually(
            "new observer failure has its own notification",
            lambda: any(
                item["payload"].get("incident_id") == new_incident["id"]
                and item["payload"].get("kind") == "firing"
                for item in self.records()
            ),
        )
        assert not any(
            item["payload"].get("incident_id") == self.original_incident
            and item["payload"].get("kind") == "resolved"
            for item in self.records()
        )
        return {
            "retired_stream": self.original_stream,
            "new_stream": moved["id"],
            "old_incident": self.original_incident,
            "new_incident": new_incident["id"],
            "zero_match_restart_preserved_rule": True,
            "new_data_measured_after_gap": 13,
        }

    def exception_reset_and_disabled_fallback(self) -> dict[str, Any]:
        assignment = self.assignment_state()
        exception = {"warning_items": 20, "critical_items": 30}
        self.request(
            "/api/v1/assignments/" + assignment["id"],
            {"revision": assignment["revision"], "params": exception},
            method="PUT",
        )
        self.eventually(
            "instance exception produces measured recovery",
            lambda: self.measured(exception, "OK"),
        )
        assert self.assignment_state()["configuration_origin"]["kind"] == "exception"
        self.rule_params = {"warning_items": 7, "critical_items": 11}
        changed = self.edit_rule(params=self.rule_params)
        assert changed["changed_count"] == 0
        assert self.rule()["counts"]["exceptions"] == 1
        assert self.assignment_state()["params"] == exception
        current = self.assignment_state()
        preview = self.request(
            "/api/v1/assignments/" + current["id"] + "/exception/preview",
            {"revision": current["revision"]},
        )
        assert preview["proposed_params"] == self.rule_params
        self.request(
            "/api/v1/configuration/exception/reset",
            {"review_token": preview["review_token"]},
        )
        self.eventually(
            "clearing exception adopts and measures the current rule",
            lambda: self.measured(self.rule_params, "CRIT"),
        )
        assert self.assignment_state()["instance_exception"] is None
        self.edit_rule(enabled=False)
        self.eventually(
            "disabled rule returns to source defaults",
            lambda: self.measured(DEFAULTS, "OK"),
        )
        assert self.assignment_state()["configuration_origin"]["kind"] == "source"
        self.edit_rule(enabled=True)
        self.eventually(
            "reenabled rule is independently measured",
            lambda: self.measured(self.rule_params, "CRIT"),
        )
        return {
            "exception_params": exception,
            "reset_params": self.rule_params,
            "disabled_params": DEFAULTS,
            "instance_exception": None,
        }

    def incompatible_future_inventory_and_recovery(self) -> dict[str, Any]:
        previous = self.stream(TARGET)
        source = self.installed_source(NODE_B)
        self.set_membership("b", False)
        self.eventually(
            "volume absent before incompatible future publication", self.empty_coverage
        )
        altered = source.replace(
            'PARAMETER_UNIT = "items"', 'PARAMETER_UNIT = "records"'
        )
        assert altered != source
        self.deploy_source(NODE_B, altered)
        self.set_membership("b", True)
        try:
            diagnostics = self.eventually(
                "future incompatible schema is durably reported against the rule",
                lambda: self.rule()["diagnostics"],
            )
            assert self.empty_coverage()
            assert self.rule()["match_count"] == 0
            assert self.rule()["enabled"] is True
            assert any(self.rule_id in item["rule_ids"] for item in diagnostics)
            self.compose("restart", "controller")
            self.eventually(
                "rule diagnostic survives controller restart",
                lambda: self.rule()["diagnostics"],
            )
        finally:
            self.deploy_source(NODE_B, source)
        recovered = self.eventually(
            "explicitly restoring a compatible source admits the future check",
            lambda: self.measured(self.rule_params, "CRIT"),
        )
        self.eventually(
            "accepted replacement clears the active rule diagnostic",
            lambda: not self.rule()["diagnostics"],
        )
        assert recovered["id"] != previous["id"]
        assert (
            self.assignment_state()["configuration_origin"]["rule_id"] == self.rule_id
        )
        return {
            "rejected_unit": "records",
            "diagnostic_survived_restart": True,
            "reintroduced_stream": recovered["id"],
            "restored_unit": "items",
        }

    def offline_rule_change_and_reconnect(self) -> dict[str, Any]:
        row = self.stream(TARGET)
        old = self.assignment_state()
        before = self.node_journal(NODE_B)
        self.mode(offline_installations=[row["runner_id"]])
        reports: list[dict[str, Any]] = []
        try:
            buffered = self.eventually(
                "node B continues old-configuration execution while disconnected",
                lambda: (
                    sample
                    if len((sample := self.node_journal(NODE_B))["reports"]) >= 2
                    else False
                ),
            )
            reports = buffered["reports"]
            self.rule_params = {"warning_items": 20, "critical_items": 30}
            self.edit_rule(params=self.rule_params)
            pending = self.assignment_state()
            assert pending["desired_generation"] > old["desired_generation"]
            assert pending["active_generation"] == old["active_generation"]
            assert pending["current"]["confirmed_params"] != self.rule_params
            self.compose("restart", "controller")
            persisted = self.eventually(
                "offline rule edit survives controller restart", self.rule
            )
            assert persisted["params"] == self.rule_params
        finally:
            self.mode(offline_installations=[])
        recovered = self.eventually(
            "reconnect activates and measures the changed durable rule",
            lambda: self.measured(self.rule_params, "OK"),
            timeout=120,
        )
        ids = [item["id"] for item in reports]
        stored = self.eventually(
            "all original disconnected reports receive durable dispositions",
            lambda: (
                records
                if len(records := self.stored_reports(ids)) == len(ids)
                else False
            ),
        )
        evidence = exact_buffered_evidence(reports, stored)
        journal = self.node_journal(NODE_B)
        assert journal["status"]["dropped"] == before["status"]["dropped"]
        assert recovered["id"] == row["id"]
        assert (
            self.assignment_state()["configuration_origin"]["rule_revision"]
            == self.rule()["revision"]
        )
        return {
            "new_params": self.rule_params,
            "original_evidence": evidence,
            "stream_identity_preserved": True,
        }

    def run(self) -> None:
        print(
            f"Durable rules project: {self.project}; UI: {self.base}; evidence: {self.output}",
            flush=True,
        )
        success = False
        try:
            for label, function in (
                (
                    "identical installed consumers measure an explicitly declared local volume",
                    self.clean_start,
                ),
                (
                    "reviewed target rule reaches a real measurement and local notification",
                    self.create_target_rule,
                ),
                (
                    "rule survives absent target and restart then follows a different observer",
                    self.move_volume_between_observers,
                ),
                (
                    "instance exception reset and disabled-rule source fallback",
                    self.exception_reset_and_disabled_fallback,
                ),
                (
                    "incompatible future source produces durable diagnosis and explicit recovery",
                    self.incompatible_future_inventory_and_recovery,
                ),
                (
                    "offline rule edit reconciles on reconnect without rewriting buffered evidence",
                    self.offline_rule_change_and_reconnect,
                ),
            ):
                self.run_step(label, function)
            success = True
        finally:
            try:
                (self.output / "rules.json").write_text(
                    json.dumps(self.rules(), indent=2)
                )
            except Exception:
                pass
            self.finish(success)
            print(f"Evidence: {self.output}", flush=True)
        assert success
        print("All real durable-rule scenarios passed.", flush=True)


if __name__ == "__main__":
    DurableRulesAcceptance().run()
