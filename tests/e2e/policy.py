#!/usr/bin/env python3
# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Real policy CLI, PostgreSQL, installed file workers and reconnect acceptance."""

from __future__ import annotations

import copy
import json
import os
import subprocess
import sys
import uuid
from pathlib import Path
from typing import Any

from acceptance import ROOT
from durable_rules import (
    CONTRACT,
    DEFAULTS,
    NODE_A,
    NODE_B,
    RULE_FIELDS,
    SOURCE,
    TARGET,
    DurableRulesAcceptance,
)
from parity_transport import exact_buffered_evidence

PROJECT = "volume-policy"
CHANGED_DEFAULTS = {"warning_items": 75, "critical_items": 150}
EXCEPTION = {"warning_items": 20, "critical_items": 30}


class PolicyAcceptance(DurableRulesAcceptance):
    def __init__(self) -> None:
        super().__init__()
        self.manifest: dict[str, Any] = {"version": 1, "project": PROJECT, "rules": []}
        self.cli_sequence = 0
        self.unmanaged_id = ""
        self.first_plan = self.output / "first-plan.json"
        self.first_receipt: dict[str, Any] = {}

    def cli(
        self,
        *args: str,
        document: dict[str, Any] | None = None,
        code: int = 0,
    ) -> dict[str, Any]:
        """Invoke the same dependency-free module as the installed CLI entry point."""
        # This acceptance harness authors each complete fixture change deliberately.
        # The production CLI must never obtain a fresh baseline automatically.
        if args[0] == "plan":
            head = self.request("/api/v1/configuration/revision")["head"]
            args = (*args, "--base", head)
        env = self.env | {"PYTHONPATH": str(ROOT / "runner")}
        if previous := os.environ.get("PYTHONPATH"):
            env["PYTHONPATH"] += os.pathsep + previous
        result = subprocess.run(
            [
                sys.executable,
                "-m",
                "mondek_runner.policy",
                *args,
                *([] if args[0] == "validate" else ["--controller", self.base]),
                "--json",
            ],
            cwd=ROOT,
            env=env,
            text=True,
            input=None if document is None else json.dumps(document),
            capture_output=True,
            timeout=30,
        )
        self.cli_sequence += 1
        stem = self.output / f"cli-{self.cli_sequence:03d}-{args[0]}"
        stem.with_suffix(".stdout").write_text(result.stdout)
        stem.with_suffix(".stderr").write_text(result.stderr)
        assert result.returncode == code, (
            args,
            result.returncode,
            result.stdout,
            result.stderr,
        )
        if code:
            return {
                "error": result.stderr,
                "output": json.loads(result.stdout) if result.stdout.strip() else None,
            }
        return json.loads(result.stdout)

    def plan(self, manifest: dict[str, Any] | None = None) -> Path:
        path = self.output / f"plan-{self.cli_sequence + 1:03d}.json"
        result = self.cli(
            "plan", "-", "--out", str(path), document=manifest or self.manifest
        )
        assert json.loads(path.read_text())["plan"] == result
        return path

    def apply_plan(self, plan: Path) -> dict[str, Any]:
        return self.cli("apply", str(plan))

    def assert_replay(self, plan: Path, original: dict[str, Any]) -> None:
        replay = self.apply_plan(plan)
        assert replay["replayed"] is True
        volatile = {"replayed", "superseded", "current_project_revision"}
        assert {key: value for key, value in replay.items() if key not in volatile} == {
            key: value for key, value in original.items() if key not in volatile
        }
        assert (
            replay["current_project_revision"] >= original["applied_project_revision"]
        )
        assert replay["superseded"] == (
            replay["current_project_revision"] != original["applied_project_revision"]
        )

    def export(self) -> dict[str, Any]:
        path = self.output / f"export-{self.cli_sequence + 1:03d}.json"
        result = self.cli("export", "--project", PROJECT, "--out", str(path))
        assert json.loads(path.read_text()) == result
        return result

    def values(self) -> dict[str, Any]:
        identity = self.assignment_state()["id"]
        inspected = self.cli("inspect", "--source", SOURCE)
        return next(row for row in inspected["rows"] if row["id"] == identity)

    def restart_controller(self) -> None:
        self.compose("restart", "controller")
        self.eventually(
            "controller HTTP endpoint is ready after restart",
            lambda: self.request("/health").get("status") == "ok",
        )

    def history(self, assignment_id: str) -> list[dict[str, Any]]:
        """Read immutable saved generations independently from policy responses."""
        identity = str(uuid.UUID(assignment_id))
        query = (
            "SELECT COALESCE(json_agg(row_to_json(c)), '[]'::json) FROM "
            "(SELECT generation, params, definition, saved_at FROM configurations "
            f"WHERE assignment_id = '{identity}' ORDER BY generation) c"
        )
        return json.loads(
            self.compose(
                "exec",
                "-T",
                "postgres",
                "psql",
                "-U",
                "mondek",
                "-d",
                "mondek_dev",
                "-At",
                "-c",
                query,
                capture=True,
                timeout=10,
            )
        )

    def set_exception(self, params: dict[str, int]) -> None:
        row = self.assignment_state()
        self.request(
            "/api/v1/assignments/" + row["id"],
            {"revision": row["revision"], "params": params},
            method="PUT",
        )

    def reset_exception(self) -> None:
        row = self.assignment_state()
        preview = self.request(
            "/api/v1/assignments/" + row["id"] + "/exception/preview",
            {"revision": row["revision"]},
        )
        assert preview["proposed_params"] == self.rule_params
        self.request(
            "/api/v1/configuration/exception/reset",
            {"review_token": preview["review_token"]},
        )

    def source_defaults_without_policy(self) -> dict[str, Any]:
        evidence = self.clean_start()
        assert self.rules()["total"] == 0
        inspected = self.values()
        assert inspected["source_defaults"] == DEFAULTS
        assert self.assignment_state()["configuration_origin"]["kind"] == "source"
        return evidence | {"no_policy_required": True}

    def prepare_unmanaged_rules(self) -> dict[str, Any]:
        evidence = self.create_target_rule()
        original_id = self.rule_id
        # A deliberately unrelated, disabled UI rule witnesses the removal boundary.
        seed = self.request(
            "/api/v1/configuration/rules/seed/" + self.original_assignment
        )
        seed.update(
            name="Unmanaged archive volume",
            target_key="volume:archive",
            enabled=False,
        )
        self.apply_rule(seed)
        self.unmanaged_id = self.rule_id
        self.rule_id = original_id
        assert self.rules()["total"] == 2
        return evidence | {"unmanaged_rule_id": self.unmanaged_id}

    def reviewed_adoption_and_replay(self) -> dict[str, Any]:
        rule = self.rule()
        self.manifest = self.cli(
            "export",
            "--project",
            PROJECT,
            "--out",
            str(self.output / "adoption.json"),
            "--adopt",
            f"{self.rule_id}=orders",
        )
        assert self.manifest["rules"][0]["adopt_rule_id"] == self.rule_id
        assert self.manifest["rules"][0]["parameter_contract"] == CONTRACT
        assert self.rule()["managed_project"] is None
        self.cli("validate", "-", document=self.manifest)
        self.first_plan = self.plan()
        self.first_receipt = self.apply_plan(self.first_plan)
        self.eventually(
            "adopted policy is actually measured",
            lambda: self.measured(self.rule_params, "CRIT"),
        )
        assert self.rule()["managed_project"] == PROJECT
        assert self.rule()["managed_key"] == "orders"
        before = self.assignment_state()
        history = self.history(before["id"])
        exported = self.export()
        assert "parameter_schema" not in exported["rules"][0]
        self.manifest = exported
        self.cli("validate", "-", document=exported)
        self.apply_plan(self.plan(exported))
        assert (
            self.assignment_state()["desired_generation"]
            == before["desired_generation"]
        )
        assert self.history(before["id"]) == history
        self.restart_controller()
        self.assert_replay(self.first_plan, self.first_receipt)
        assert self.export() == exported
        assert self.history(before["id"]) == history
        # A stale UI draft cannot mutate the newly managed rule.
        proposal = {key: rule[key] for key in RULE_FIELDS}
        blocked = self.request(
            "/api/v1/configuration/rules/preview", {"proposal": proposal}, code=409
        )
        assert blocked["error"] == "stale"
        # Project ownership is no longer an editing lock. A fresh UI review works.
        current_rule = self.rule()
        current_proposal = {key: current_rule[key] for key in RULE_FIELDS}
        reviewed = self.request(
            "/api/v1/configuration/rules/preview", {"proposal": current_proposal}
        )
        assert reviewed["review_token"]
        return {
            "rule_id": self.rule_id,
            "project": PROJECT,
            "export_has_no_schema_copy": True,
            "repeat_apply_preserved_generation": before["desired_generation"],
            "original_receipt_replayed_after_restart": True,
        }

    def masked_source_and_exception(self) -> dict[str, Any]:
        source = self.installed_source(NODE_A)
        changed = source.replace(
            'DEFAULTS = {"warning_items": 50, "critical_items": 100}',
            'DEFAULTS = {"warning_items": 75, "critical_items": 150}',
        )
        assert changed != source
        self.deploy_source(NODE_A, changed)
        self.eventually(
            "code defaults update beneath managed policy",
            lambda: (
                self.assignment_state()["source_defaults"] == CHANGED_DEFAULTS
                and self.measured(self.rule_params, "CRIT")
            ),
        )
        inspected = self.values()
        assert inspected["source_defaults"] == CHANGED_DEFAULTS
        self.set_exception(EXCEPTION)
        self.eventually(
            "explicit instance exception is measured",
            lambda: self.measured(EXCEPTION, "OK"),
        )
        self.rule_params = {"warning_items": 7, "critical_items": 11}
        self.manifest["rules"][0]["params"] = self.rule_params
        before = self.assignment_state()
        self.apply_plan(self.plan())
        assert (
            self.assignment_state()["desired_generation"]
            == before["desired_generation"]
        )
        assert self.assignment_state()["params"] == EXCEPTION
        assert self.assignment_state()["instance_exception"] == EXCEPTION
        inspected = self.values()
        assert inspected["masked_by_exception"] is True
        assert inspected["current_params"] == EXCEPTION
        assert inspected["masked_params"] == self.rule_params
        self.reset_exception()
        self.eventually(
            "reviewed exception reset measures the managed policy",
            lambda: self.measured(self.rule_params, "CRIT"),
        )
        assert self.assignment_state()["instance_exception"] is None
        self.assert_replay(self.first_plan, self.first_receipt)
        assert self.rule()["params"] == self.rule_params
        return {
            "updated_source_defaults": CHANGED_DEFAULTS,
            "retained_exception": EXCEPTION,
            "policy_after_reset": self.rule_params,
            "old_receipt_did_not_restore_old_policy": True,
        }

    def stale_and_conflicting_plans(self) -> dict[str, Any]:
        draft = copy.deepcopy(self.manifest)
        draft["rules"][0]["params"] = {"warning_items": 8, "critical_items": 12}
        plan = self.plan(draft)
        self.set_exception(EXCEPTION)
        before_rule = self.rule()
        rejected = self.cli("apply", str(plan), code=1)
        assert "stale" in json.dumps(rejected).lower()
        assert self.rule() == before_rule
        assert self.assignment_state()["instance_exception"] == EXCEPTION
        self.reset_exception()
        self.eventually(
            "stale plan left current policy intact",
            lambda: self.measured(self.rule_params, "CRIT"),
        )
        conflicting = copy.deepcopy(self.manifest)
        conflicting["rules"].append(conflicting["rules"][0] | {"key": "tied"})
        before = self.export()
        rejected_plan = self.output / "conflicting-plan.json"
        rejected = self.cli(
            "plan", "-", "--out", str(rejected_plan), document=conflicting, code=1
        )
        assert "conflict" in json.dumps(rejected).lower()
        assert rejected["output"]["counts"]["conflicts"] == 1
        assert not rejected_plan.exists()
        assert self.export() == before
        assert self.rules()["total"] == 2
        return {"stale_apply_rejected": True, "conflicting_set_wrote_nothing": True}

    def dormant_policy_follows_target(self) -> dict[str, Any]:
        before = self.stream(TARGET)
        incident = self.open_incident(before)
        history = self.history(before["assignment_id"])
        self.set_membership("a", False)
        self.eventually("target explicitly withdrawn", self.empty_coverage)
        assert self.rule()["match_count"] == 0
        self.apply_plan(self.plan())
        exported = self.export()
        self.restart_controller()
        assert self.export() == exported
        assert self.rule()["match_count"] == 0
        self.set_membership("b", True)
        moved = self.eventually(
            "new observer inherits project policy for stable target",
            lambda: self.measured(self.rule_params, "CRIT"),
        )
        assert moved["runner_id"] != before["runner_id"]
        assert moved["assignment_id"] != before["assignment_id"]
        assert (
            self.assignment_state()["configuration_origin"]["managed_project"]
            == PROJECT
        )
        assert self.history(before["assignment_id"])[0 : len(history)] == history
        ended = next(
            row
            for row in self.request("/api/v1/checks/" + before["id"])["incidents"]
            if row["id"] == incident["id"]
        )
        assert ended["closure_reason"] == "source_removed"
        assert ended["closing_observation_id"] is None
        assert self.open_incident(moved)["id"] != incident["id"]
        return {
            "old_assignment": before["assignment_id"],
            "new_assignment": moved["assignment_id"],
            "retained_rule": self.rule_id,
            "new_incident_required": True,
        }

    def offline_apply_and_reconnect(self) -> dict[str, Any]:
        row = self.stream(TARGET)
        before = self.assignment_state()
        journal = self.node_journal(NODE_B)
        self.mode(offline_installations=[row["runner_id"]])
        reports: list[dict[str, Any]] = []
        try:
            buffered = self.eventually(
                "real worker continues producing original evidence while offline",
                lambda: (
                    sample
                    if len((sample := self.node_journal(NODE_B))["reports"]) >= 2
                    else False
                ),
            )
            reports = buffered["reports"]
            self.rule_params = {"warning_items": 20, "critical_items": 30}
            self.manifest["rules"][0]["params"] = self.rule_params
            plan = self.plan()
            receipt = self.apply_plan(plan)
            pending = self.assignment_state()
            assert pending["desired_generation"] > before["desired_generation"]
            assert pending["active_generation"] == before["active_generation"]
            assert pending["current"]["confirmed_params"] != self.rule_params
            self.restart_controller()
            self.assert_replay(plan, receipt)
        finally:
            self.mode(offline_installations=[])
        self.eventually(
            "reconnected runner measures new project policy",
            lambda: self.measured(self.rule_params, "OK"),
            timeout=120,
        )
        ids = [item["id"] for item in reports]
        stored = self.eventually(
            "original buffered evidence receives durable disposition",
            lambda: (
                rows if len(rows := self.stored_reports(ids)) == len(ids) else False
            ),
        )
        evidence = exact_buffered_evidence(reports, stored)
        assert (
            self.node_journal(NODE_B)["status"]["dropped"]
            == journal["status"]["dropped"]
        )
        assert self.stream(TARGET)["id"] == row["id"]
        return {"saved_before_measured": True, "original_evidence": evidence}

    def remove_only_owned_policy(self) -> dict[str, Any]:
        row = self.assignment_state()
        history = self.history(row["id"])
        unmanaged = self.request("/api/v1/configuration/rules/" + self.unmanaged_id)
        self.manifest["rules"] = []
        plan = self.plan()
        receipt = self.apply_plan(plan)
        self.eventually(
            "removing managed policy measures node B source defaults",
            lambda: self.measured(DEFAULTS, "OK"),
        )
        assert self.export()["rules"] == []
        assert self.rules()["total"] == 1
        assert (
            self.request("/api/v1/configuration/rules/" + self.unmanaged_id)
            == unmanaged
        )
        assert self.history(row["id"])[0 : len(history)] == history
        generation = self.assignment_state()["desired_generation"]
        self.assert_replay(plan, receipt)
        self.apply_plan(self.plan())
        assert self.assignment_state()["desired_generation"] == generation
        self.assert_replay(self.first_plan, self.first_receipt)
        assert self.rules()["total"] == 1
        return {
            "only_owned_rule_removed": self.rule_id,
            "unmanaged_rule_retained": self.unmanaged_id,
            "saved_generations_retained": len(history),
            "empty_project_repeat_is_noop": True,
            "old_receipt_cannot_recreate_removed_policy": True,
        }

    def run(self) -> None:
        print(
            f"Policy project: {self.project}; UI: {self.base}; evidence: {self.output}",
            flush=True,
        )
        success = False
        try:
            for label, function in (
                (
                    "source code defaults require no policy document",
                    self.source_defaults_without_policy,
                ),
                (
                    "existing UI rules remain explicit adoption candidates",
                    self.prepare_unmanaged_rules,
                ),
                (
                    "CLI reviewed adoption, export, no-op and durable exact replay",
                    self.reviewed_adoption_and_replay,
                ),
                (
                    "code defaults and deliberate exceptions retain distinct authority",
                    self.masked_source_and_exception,
                ),
                (
                    "stale and conflicting policy plans leave state untouched",
                    self.stale_and_conflicting_plans,
                ),
                (
                    "dormant managed policy follows a future observer",
                    self.dormant_policy_follows_target,
                ),
                (
                    "offline saved policy is measured after evidence-preserving reconnect",
                    self.offline_apply_and_reconnect,
                ),
                (
                    "removing owned rules preserves unrelated policy and immutable history",
                    self.remove_only_owned_policy,
                ),
            ):
                self.run_step(label, function)
            success = True
        finally:
            self.finish(success)
            print(f"Evidence: {self.output}", flush=True)
        assert success
        print("All real configuration-policy scenarios passed.", flush=True)


if __name__ == "__main__":
    PolicyAcceptance().run()
