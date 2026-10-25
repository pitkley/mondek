#!/usr/bin/env python3
# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Reviewed publisher lifecycle with installed workers and durable evidence."""

from __future__ import annotations

import copy
import json
from datetime import UTC, datetime

from acceptance import run_compose
from coverage import CoverageAcceptance, NODE_A, SERVICE_A, SERVICE_B, fresh_desired
from grouped import HEALTHY, after_boundary
from parity_transport import exact_buffered_evidence

SOURCE = "elasticsearch-monitoring"


def assert_new_membership(before: dict, after: dict, boundary: datetime) -> None:
    """A restored publication must establish its own new membership and evidence."""
    assert after["runner_id"] == before["runner_id"]
    assert after["source_id"] == before["source_id"]
    assert after["id"] != before["id"], "Restoration reused a retired result"
    assert after["assignment_id"] != before["assignment_id"], (
        "Restoration reused assignment"
    )
    assert after["current"]["observation_id"] != before["current"]["observation_id"]
    assert fresh_desired(after, after["current"]["health"], boundary)


def assert_administrative_closure(
    incident: dict, reason: str = "publisher_retired"
) -> None:
    assert incident["status"] == "closed"
    assert incident["closure_reason"] == reason
    assert incident["closing_observation_id"] is None, (
        "Retirement invented recovery evidence"
    )


def failed_restore_refresh(
    status: dict, floor: int, lifecycle_revision: int, boundary: datetime
) -> bool:
    refresh = status.get("inventory_refresh") or {}
    return (
        refresh.get("after_revision") == floor
        and refresh.get("lifecycle_revision") == lifecycle_revision
        and refresh.get("state") == "failed"
        and after_boundary(refresh.get("attempted_at"), boundary)
    )


class PublisherAcceptance(CoverageAcceptance):
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
                "-f",
                "examples/compose/publishers.yaml",
                *args,
            ],
            env=self.env,
            log=self.log,
            capture=capture,
            timeout=timeout,
        )

    def publishers(self) -> list[dict]:
        return self.request("/api/v1/coverage/publishers?source_id=" + SOURCE)["items"]

    def result(self, observer: str, environment: str = "production", key=None) -> dict:
        rows = [
            row
            for row in self.streams(runner_id=self.identities[observer])["items"]
            if row["source_id"] == SOURCE and row["environment"] == environment
        ]
        assert len(rows) <= 1, "Independent publisher results were merged or duplicated"
        return next(iter(rows))

    def lifecycle(self, publisher_id: int) -> dict:
        return self.request(f"/api/v1/publishers/{publisher_id}")

    def reported_status(self, observer: str) -> dict:
        """Read refresh progress actually reported by this owned worker to control."""
        return next(
            row["status"]
            for row in self.snapshot()["runners"]
            if row["id"] == self.identities[observer]
        )

    def proposal(self, action: str, *, successor: bool = False) -> dict:
        value = {
            "publisher_id": self.predecessor_id,
            "action": action,
            "reason": "Reviewed local-service publisher lifecycle acceptance",
        }
        if successor:
            value["successor_id"] = self.successor_id
        return value

    def preview(self, proposal: dict) -> dict:
        return self.request("/api/v1/publishers/preview", {"proposal": proposal})

    def apply(self, preview: dict, code: int = 200) -> dict:
        return self.request(
            "/api/v1/publishers/apply",
            {"proposal": preview["proposal"], "review_token": preview["review_token"]},
            code=code,
        )

    def group(self, id_: str | None = None) -> dict:
        if id_ is None:
            groups = self.request("/api/v1/incidents")
            assert groups["total"] <= 1, (
                "Same explicit condition created duplicate episodes"
            )
            id_ = next(iter(groups["items"]))["id"]
        return self.request(
            f"/api/v1/incidents/{id_}?state=all&notification_status=all"
        )

    def installed_source(self, service: str) -> str:
        return self.compose(
            "exec",
            "-T",
            service,
            "python",
            "-c",
            "from pathlib import Path; import importlib.util; print(Path(importlib.util.find_spec('mondek_examples.grouped').origin).read_text(),end='')",
            capture=True,
        )

    def deploy_source(self, service: str, source: str) -> None:
        script = (
            "from pathlib import Path; import importlib.util; p=Path(importlib.util.find_spec('mondek_examples.grouped').origin); "
            + f"p.write_text({source!r})"
        )
        self.compose("exec", "-T", "--user", "0", service, "python", "-c", script)
        self.compose("restart", service)

    def save_lifecycle(self, label: str) -> None:
        (self.output / f"publishers-{label}.json").write_text(
            json.dumps(
                {
                    "predecessor": self.lifecycle(self.predecessor_id),
                    "successor": self.lifecycle(self.successor_id),
                    "scopes": self.request("/api/v1/coverage"),
                },
                indent=2,
            )
        )

    def start_and_readiness(self) -> dict:
        self.compose(
            "up", "--build", "--detach", "--wait", "--wait-timeout", "180", NODE_A
        )
        self.mode(
            grouped_samples={
                "service-a/elasticsearch": dict(HEALTHY),
                "service-b/elasticsearch": dict(HEALTHY),
            }
        )
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
                "installed publisher " + observer,
                lambda observer=observer: self.remember(observer),
            )
            self.eventually(
                "fresh owned measurement " + observer,
                lambda observer=observer: self.measured(observer, "production"),
            )
        self.predecessor_id = self.publisher("service-a")["id"]
        self.successor_id = self.publisher("service-b")["id"]
        self.unrelated = next(
            row
            for row in self.streams()["items"]
            if row["source_id"] == "declared-coverage"
        )
        self.request(
            "/api/v1/publishers/preview",
            {"proposal": self.proposal("replace")},
            code=422,
        )
        self.request(
            "/api/v1/publishers/preview",
            {"proposal": self.proposal("replace") | {"successor_id": 999999999}},
            code=404,
        )
        self.samples({"service-b/elasticsearch": {"sample_age_seconds": 60}})
        self.eventually(
            "successor source evidence becomes stale",
            lambda: self.result("service-b")["current"]["knowledge"] == "stale",
        )
        blocked = self.preview(self.proposal("replace", successor=True))
        assert not blocked["can_apply"] and blocked["blockers"]
        self.apply(blocked, code=422)
        assert (
            self.lifecycle(self.predecessor_id)["publisher"]["lifecycle_status"]
            == "active"
        )
        boundary = self.samples({"service-b/elasticsearch": dict(HEALTHY)})
        self.eventually(
            "successor supplies new fresh evidence",
            lambda: self.measured("service-b", "production", "OK", boundary),
        )
        return {
            "predecessor": self.predecessor_id,
            "successor": self.successor_id,
            "rejected_absent_and_stale_successor": True,
        }

    def reviewed_shared_replacement(self) -> dict:
        boundary = self.samples(
            {
                "service-a/elasticsearch": {"used_percent": 96},
                "service-b/elasticsearch": {"used_percent": 96},
            }
        )
        self.old = self.eventually(
            "predecessor confirms Critical",
            lambda: self.measured("service-a", "production", "CRIT", boundary),
        )
        self.peer = self.eventually(
            "successor confirms its own Critical",
            lambda: self.measured("service-b", "production", "CRIT", boundary),
        )
        shared = self.eventually(
            "two independent contributors share one condition",
            lambda: row if (row := self.group())["counts"]["open"] == 2 else False,
        )
        self.group_id = shared["incident"]["id"]
        self.old_incident = next(
            row["incident"]
            for row in shared["contributions"]
            if row["incident"]["stream_id"] == self.old["id"]
        )
        peer_incident = next(
            row["incident"]
            for row in shared["contributions"]
            if row["incident"]["stream_id"] == self.peer["id"]
        )
        stale = self.preview(self.proposal("replace", successor=True))
        assert stale["can_apply"]
        self.request(
            f"/api/v1/incidents/{self.old_incident['id']}/acknowledge",
            {
                "mode": "until_incident_ends",
                "revision": self.old_incident["acknowledgement_revision"],
                "attention_revision": self.old_incident["attention_revision"],
                "note": "Predecessor only; never transfer",
            },
        )
        assert next(
            row
            for row in self.group(self.group_id)["contributions"]
            if row["incident"]["id"] == self.old_incident["id"]
        )["coverage"]["individual_acknowledgement"]
        self.apply(stale, code=409)
        assert (
            self.lifecycle(self.predecessor_id)["publisher"]["lifecycle_status"]
            == "active"
        )
        self.mode(offline_installations=[self.identities["service-a"]])
        self.accepted_envelope = self.runner_inventory(SERVICE_A)
        self.offline_boundary = datetime.now(UTC)

        def offline_reports() -> dict | bool:
            sample = self.node_journal(SERVICE_A)
            reports = [
                r
                for r in sample["reports"]
                if after_boundary(r["started_at"], self.offline_boundary)
            ]
            return sample if len(reports) >= 2 else False

        queued = self.eventually(
            "offline predecessor continues executing",
            offline_reports,
        )
        self.original_reports = [
            r
            for r in queued["reports"]
            if after_boundary(r["started_at"], self.offline_boundary)
        ]
        reviewed = self.preview(self.proposal("replace", successor=True))
        assert reviewed["can_apply"], reviewed["blockers"]
        saved = self.apply(reviewed)
        assert saved["publisher"]["lifecycle_status"] == "retired"
        assert saved["publisher"]["replacement_id"] == self.successor_id
        self.retirement = reviewed
        self.retirement_receipt = saved["receipt"]
        assert self.apply(reviewed)["receipt"] == self.retirement_receipt
        self.saved_decision_path = (
            f"/api/v1/publishers/{self.predecessor_id}/events/{saved['receipt']['id']}"
        )
        self.saved_decision = self.request(self.saved_decision_path)
        assert (
            self.saved_decision["page"] == 1 and self.saved_decision["page_size"] == 25
        )
        assert self.saved_decision["total"] == len(self.saved_decision["items"]) == 1
        witness = self.saved_decision["items"][0]
        assert witness["stream_id"] == self.old["id"]
        assert witness["successor_stream_id"] == self.peer["id"]
        assert witness["successor_assignment_id"] == self.peer["assignment_id"]
        assert witness["successor_generation"] == self.peer["desired_generation"]
        assert witness["successor_health"] == "CRIT"
        observed = self.stored_reports([witness["successor_observation_id"]])
        assert len(observed) == 1 and observed[0]["disposition"] == "current"
        payload = observed[0]["payload"]
        assert payload["installation_id"] == self.peer["runner_id"]
        assert payload["assignment_id"] == self.peer["assignment_id"]
        assert payload["generation"] == witness["successor_generation"]
        assert (
            next(
                row
                for row in payload["results"]
                if row["key"] == self.peer["result_key"]
            )["health"]
            == "CRIT"
        )
        closed = self.request(f"/api/v1/incidents/{self.old_incident['id']}")[
            "incident"
        ]
        assert_administrative_closure(closed, "publisher_replaced")
        continuity = self.group(self.group_id)
        assert (
            continuity["incident"]["status"] == "open"
            and continuity["counts"]["open"] == 1
        )
        successor = self.request(f"/api/v1/incidents/{peer_incident['id']}")["incident"]
        assert (
            successor["status"] == "open" and successor["acknowledgement_mode"] is None
        )
        assert self.result("service-b")["id"] == self.peer["id"]
        self.save_lifecycle("replaced")
        return {
            "shared_episode": self.group_id,
            "retired_contribution": self.old_incident["id"],
            "successor_contribution": peer_incident["id"],
            "stale_review_rejected": True,
            "retirement_receipt": self.retirement_receipt,
            "saved_successor_evidence": witness,
        }

    def retirement_fence_and_historical_reconnect(self) -> dict:
        original = self.installed_source(SERVICE_A)
        self.original_source = original
        self.deploy_source(
            SERVICE_A,
            original + "\n# A newer deployment cannot remove operator retirement.\n",
        )
        self.compose("restart", "controller")
        self.eventually(
            "durable retirement survives controller restart",
            lambda: (
                self.lifecycle(self.predecessor_id)["publisher"]["lifecycle_status"]
                == "retired"
            ),
        )
        self.mode(offline_installations=[])
        stored = self.eventually(
            "predecessor buffered evidence arrives historically",
            lambda: (
                rows
                if len(
                    rows := self.stored_reports(
                        [r["id"] for r in self.original_reports]
                    )
                )
                == len(self.original_reports)
                else False
            ),
            timeout=90,
        )
        proof = exact_buffered_evidence(self.original_reports, stored)
        assert proof["historical"] == len(self.original_reports)
        self.eventually(
            "retired worker receives an empty admitted schedule",
            lambda: self.runner_status(SERVICE_A)["active"] == {},
        )
        envelope = self.runner_inventory(SERVICE_A)
        self.retired_envelope = envelope
        attempted = copy.deepcopy(envelope)
        attempted["inventory_revision"] += 100
        response = self.request("/api/v1/inventory", attempted, code=409)
        assert response["code"] == "publisher_retired"
        retired = self.lifecycle(self.predecessor_id)["publisher"]
        assert retired["lifecycle_status"] == "retired"
        assert self.detail(self.old)["stream"]["retired"]
        assert self.group(self.group_id)["counts"]["open"] == 1
        unrelated = self.eventually(
            "unrelated source still measures",
            lambda: next(
                (
                    row
                    for row in self.streams()["items"]
                    if row["id"] == self.unrelated["id"]
                    and fresh_desired(row, "OK", self.offline_boundary)
                ),
                False,
            ),
        )
        self.save_lifecycle("fenced-reconnected")
        return proof | {
            "unrelated_result_preserved": unrelated["id"],
            "new_inventory_rejected": True,
        }

    def restoration_requires_new_inventory_and_measurements(self) -> dict:
        self.deploy_source(
            SERVICE_A,
            "raise RuntimeError('intentional restoration discovery failure')\n",
        )
        self.eventually(
            "failed source discovery is visible",
            lambda: (
                "intentional restoration discovery failure"
                in self.runner_status(SERVICE_A).get("diagnostic", "")
            ),
        )
        restore = self.preview(self.proposal("restore"))
        assert restore["can_apply"]
        restore_boundary = datetime.now(UTC)
        restored = self.apply(restore)
        assert restored["publisher"]["lifecycle_status"] == "awaiting_inventory"
        floor = restored["publisher"]["resume_after_revision"]
        assert floor >= self.accepted_envelope["inventory_revision"]
        current_session = self.runner_status(SERVICE_A)
        replayed = self.accepted_envelope | {
            key: current_session[key]
            for key in ("installation_id", "session_id", "boot")
        }
        rejection = self.request("/api/v1/inventory", replayed, code=409)
        assert rejection["code"] == "publication_refresh_required"
        failed_refresh = self.eventually(
            "post-restore rediscovery actually fails while membership remains fenced",
            lambda: (
                status
                if failed_restore_refresh(
                    status := self.reported_status("service-a"),
                    floor,
                    restored["publisher"]["lifecycle_revision"],
                    restore_boundary,
                )
                and self.lifecycle(self.predecessor_id)["publisher"]["lifecycle_status"]
                == "awaiting_inventory"
                else False
            ),
        )
        assert self.detail(self.old)["stream"]["retired"]
        boundary = datetime.now(UTC)
        self.deploy_source(SERVICE_A, self.original_source)
        new = self.eventually(
            "same successful source restores new membership with its own measurement",
            lambda: self.measured("service-a", "production", "CRIT", boundary),
            timeout=90,
        )
        assert_new_membership(self.old, new, boundary)
        active = self.lifecycle(self.predecessor_id)["publisher"]
        assert (
            active["lifecycle_status"] == "active"
            and active["inventory_revision"] > floor
        )
        assert_administrative_closure(
            self.request(f"/api/v1/incidents/{self.old_incident['id']}")["incident"],
            "publisher_replaced",
        )
        shared = self.eventually(
            "restored independent contributor joins existing failure",
            lambda: (
                row
                if (row := self.group(self.group_id))["counts"]["open"] == 2
                else False
            ),
        )
        contribution = next(
            row["incident"]
            for row in shared["contributions"]
            if row["incident"]["stream_id"] == new["id"]
        )
        assert contribution["acknowledgement_mode"] is None
        assert self.apply(self.retirement)["receipt"] == self.retirement_receipt
        assert (
            self.lifecycle(self.predecessor_id)["publisher"]["lifecycle_status"]
            == "active"
        )
        self.save_lifecycle("restored")
        return {
            "floor": floor,
            "new_revision": active["inventory_revision"],
            "new_assignment": new["assignment_id"],
            "new_result": new["id"],
            "fresh_measurement": new["current"],
            "historical_replay_was_idempotent": True,
            "failed_rediscovery_after_restore": failed_refresh["inventory_refresh"],
        }

    def intentional_retirement_is_not_recovery(self) -> dict:
        boundary = self.samples({"service-b/elasticsearch": dict(HEALTHY)})
        self.eventually(
            "successor independently recovers after its saved witness",
            lambda: self.measured("service-b", "production", "OK", boundary),
        )
        assert self.request(self.saved_decision_path) == self.saved_decision, (
            "Later health rewrote the saved replacement witness"
        )
        boundary = self.samples({"service-b/elasticsearch": {"used_percent": 96}})
        self.eventually(
            "successor independently fails again",
            lambda: self.measured("service-b", "production", "CRIT", boundary),
        )
        boundary = self.samples({"service-a/elasticsearch": dict(HEALTHY)})
        self.eventually(
            "one contributor independently recovers",
            lambda: self.measured("service-a", "production", "OK", boundary),
        )
        peer = self.group(self.group_id)
        assert peer["incident"]["status"] == "open" and peer["counts"]["open"] == 1
        successor_incident = next(
            row["incident"]
            for row in peer["contributions"]
            if row["incident"]["stream_id"] == self.peer["id"]
            and row["incident"]["status"] == "open"
        )
        review = self.preview(
            {
                "publisher_id": self.successor_id,
                "action": "retire",
                "reason": "End this independent observer intentionally",
            }
        )
        assert review["can_apply"]
        saved = self.apply(review)
        assert saved["publisher"]["lifecycle_status"] == "retired"
        assert_administrative_closure(
            self.request(f"/api/v1/incidents/{successor_incident['id']}")["incident"]
        )
        self.save_lifecycle("intentional-retirement")
        return {
            "retired_publisher": self.successor_id,
            "administrative_contribution": successor_incident["id"],
        }

    def run(self) -> None:
        print(
            f"Publisher lifecycle project: {self.project}; UI: {self.base}/coverage/publishers; evidence: {self.output}",
            flush=True,
        )
        success = False
        try:
            for label, action in (
                (
                    "installed independent publishers reject absent and stale replacement",
                    self.start_and_readiness,
                ),
                (
                    "reviewed Critical successor preserves shared failure without transferring individual controls",
                    self.reviewed_shared_replacement,
                ),
                (
                    "retirement fences newer deployment, restart and original buffered evidence",
                    self.retirement_fence_and_historical_reconnect,
                ),
                (
                    "explicit restoration requires successful new inventory and fresh new membership",
                    self.restoration_requires_new_inventory_and_measurements,
                ),
                (
                    "intentional retirement closes a failure administratively",
                    self.intentional_retirement_is_not_recovery,
                ),
            ):
                self.run_step(label, action)
            success = True
        finally:
            self.finish(success)
            print(f"Evidence: {self.output}", flush=True)
        print("All real publisher lifecycle scenarios passed.", flush=True)


if __name__ == "__main__":
    PublisherAcceptance().run()
