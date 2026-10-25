#!/usr/bin/env python3
# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Shared incidents from two installed consumers and real local delivery.

Only this harness's disposable Compose project is mutated. Measurements always
come from the consumer processes; SQL is used solely to witness buffered evidence.
"""

from __future__ import annotations

import json
import urllib.parse
from datetime import UTC, datetime
from typing import Any

from acceptance import run_compose
from maintenance import MaintenanceClient
from parity import ParityAcceptance
from parity_transport import exact_buffered_evidence

VOLUME = "volume:search-data"
ELASTICSEARCH = "service:elasticsearch"
VOLUME_SERVICE = "grouped-volume"
ELASTICSEARCH_SERVICE = "grouped-elasticsearch"
SERVICES = (VOLUME_SERVICE, ELASTICSEARCH_SERVICE)
SAMPLES = {VOLUME: "node-a/volume", ELASTICSEARCH: "service-a/elasticsearch"}
CONDITION = {"namespace": "grouped-example", "key": "search-volume-pressure"}
HEALTHY = {
    "used_percent": 40,
    "writes_blocked": False,
    "available": True,
    "sample_age_seconds": 0,
}


def after_boundary(value: Any, boundary: datetime) -> bool:
    """Arrival after a change is insufficient: require a new execution/measurement."""
    try:
        instant = datetime.fromisoformat(value)
        return instant.tzinfo is not None and instant > boundary
    except (TypeError, ValueError):
        return False


def fact_matches(occurrence: dict, kind: str, key: str) -> bool:
    fact = occurrence["payload"].get("requested_fact")
    return bool(fact and fact.get("kind") == kind and fact.get("key") == key)


def assert_preserved_pending_delivery(before: dict, after: dict) -> None:
    """A restart must retain the original held occurrence and its unused job budget."""
    original, current = before["occurrence"], after["occurrence"]
    for key in (
        "id",
        "condition_incident_id",
        "condition_fact_id",
        "covered_warn_fact_id",
        "kind",
        "attention_revision",
        "payload",
        "destination",
        "inserted_at",
    ):
        assert current[key] == original[key], f"Restart changed notification {key}"
    assert current["status"] == "pending"
    assert current["attempt_count"] == original["attempt_count"] == 0
    assert current["gates"] == ["acknowledgement"]
    for key in ("id", "attempt", "max_attempts"):
        assert after["job"][key] == before["job"][key], (
            f"Restart changed the original job {key}"
        )
    assert after["job"]["args"]["occurrence_id"] == original["id"]
    assert after["job"]["state"] == "scheduled"


class GroupedAcceptance(MaintenanceClient, ParityAcceptance):
    def __init__(self) -> None:
        super().__init__()
        self.env.update(MONDEK_NOTIFICATION_MAX_ATTEMPTS="3")
        self.group_ids: list[str] = []
        self.initial: dict[str, dict] = {}

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
                "examples/compose/grouped.yaml",
                *args,
            ],
            env=self.env,
            log=self.log,
            capture=capture,
            timeout=timeout,
        )

    def incident_list(self, **filters: Any) -> dict:
        return self.request("/api/v1/incidents?" + urllib.parse.urlencode(filters))

    def group(self, id_: str) -> dict:
        return self.request(
            f"/api/v1/incidents/{id_}?state=all&notification_status=all"
        )

    def one_group(self, count: int, health: str) -> dict | bool:
        listing = self.incident_list()
        assert listing["total"] <= 1, "Equivalent results created duplicate incidents"
        if listing["total"] != 1:
            return False
        incident = listing["items"][0]
        assert incident["incident_kind"] == "condition"
        assert {key: incident[key] for key in CONDITION} == CONDITION
        assert incident["environment"] == "production"
        detail = self.group(incident["id"])
        if detail["counts"]["open"] != count or detail["incident"]["health"] != health:
            return False
        if incident["id"] not in self.group_ids:
            self.group_ids.append(incident["id"])
        return detail

    def samples(self, changes: dict[str, dict]) -> datetime:
        self.mode(
            grouped_samples={SAMPLES[key]: value for key, value in changes.items()}
        )
        # Requiring execution after the completed mutation also excludes a request
        # that collected the previous sample while the fixture update was in flight.
        return datetime.now(UTC)

    def measured(
        self, target: str, health: str, after: datetime | None = None
    ) -> dict | bool:
        row = self.stream(target)
        current = row["current"]
        if (
            current.get("knowledge") != "fresh"
            or current.get("health") != health
            or current.get("observation_id") != current.get("confirmed_observation_id")
            or current.get("confirmed_generation") != row["desired_generation"]
            or row["active_generation"] != row["desired_generation"]
        ):
            return False
        if after and not all(
            after_boundary(current.get(key), after)
            for key in ("evaluated_at", "confirmed_evaluated_at", "source_at")
        ):
            return False
        return row

    def raw_result(self, row: dict) -> dict:
        report = next(
            item
            for item in self.detail(row)["evidence"]
            if item["id"] == row["current"]["observation_id"]
        )
        return next(
            result
            for result in report["payload"]["results"]
            if result["key"] == row["result_key"]
        )

    def uncertain(
        self, target: str, health: str, knowledge: str, after: datetime
    ) -> dict | bool:
        row = self.stream(target)
        current = row["current"]
        if current.get("knowledge") != knowledge or not after_boundary(
            current.get("evaluated_at"), after
        ):
            return False
        result = self.raw_result(row)
        if result["health"] != health:
            return False
        assert result["source_at"], "Fixture source time was discarded"
        if knowledge == "stale":
            assert (
                datetime.fromisoformat(current["evaluated_at"])
                - datetime.fromisoformat(result["source_at"])
            ).total_seconds() >= 29
        return row

    def wait_measurements(self, states: dict[str, str], after: datetime) -> dict:
        def read() -> dict | bool:
            rows = {
                key: self.measured(key, value, after) for key, value in states.items()
            }
            return rows if all(rows.values()) else False

        return self.eventually("new consumer measurements " + repr(states), read)

    def acknowledge(self, detail: dict, mode: str = "until_incident_ends") -> dict:
        incident = detail["incident"]
        self.request(
            f"/api/v1/incidents/{incident['id']}/acknowledge",
            {
                "mode": mode,
                "revision": incident["acknowledgement_revision"],
                "attention_revision": incident["attention_revision"],
                "note": "Real installed-consumer shared incident acceptance",
            },
        )
        return self.group(incident["id"])

    def occurrence(self, group_id: str, kind: str, key: str) -> dict:
        found = [
            item
            for item in self.group(group_id)["occurrences"]
            if fact_matches(item, kind, key)
        ]
        assert len(found) == 1, (
            "One continuous notification fact must have one occurrence"
        )
        return found[0]

    def receipt_rows(
        self, group_id: str, occurrence_id: str | None = None
    ) -> list[dict]:
        return [
            item
            for item in self.records()
            if item["payload"].get("condition_incident_id") == group_id
            and (
                occurrence_id is None
                or item["payload"]["occurrence_id"] == occurrence_id
            )
        ]

    def delivered(self, group_id: str, kind: str, key: str) -> dict | bool:
        occurrence = self.occurrence(group_id, kind, key)
        receipts = self.receipt_rows(group_id, occurrence["id"])
        if occurrence["status"] != "delivered" or not receipts:
            return False
        assert all(row["payload"] == occurrence["payload"] for row in receipts)
        assert occurrence["incident_id"] is None
        return occurrence

    def resolved_delivery(self, group_id: str) -> dict | bool:
        detail = self.group(group_id)
        terminal = [row for row in detail["occurrences"] if row["kind"] == "resolved"]
        assert len(terminal) == 1, (
            "An attempted shared episode needs one terminal notice"
        )
        occurrence = terminal[0]
        incident = detail["incident"]
        payload = occurrence["payload"]
        assert occurrence["incident_id"] is None
        assert payload["kind"] == "resolved"
        assert payload["occurrence_id"] == occurrence["id"]
        assert payload["condition_incident_id"] == group_id
        assert payload["observation_id"] == incident["closing_observation_id"], (
            "Terminal delivery does not identify the exact closing evidence"
        )
        assert payload["closure_reason"] == incident["closure_reason"]
        assert payload["closure_reasons"] == incident["closure_reasons"]
        receipts = self.receipt_rows(group_id, occurrence["id"])
        if occurrence["status"] != "delivered" or not receipts:
            return False
        assert all(row["payload"] == payload for row in receipts), (
            "Terminal receipt changed the immutable occurrence payload"
        )
        return occurrence

    def notification_job(self, occurrence_id: str) -> dict:
        jobs = [
            row
            for row in self.snapshot()["jobs"]
            if row["args"]["occurrence_id"] == occurrence_id
        ]
        assert len(jobs) == 1, "Held delivery must retain exactly one original job"
        return jobs[0]

    def pending_warning(self, group_id: str) -> dict | bool:
        occurrence = self.occurrence(group_id, "severity", "WARN")
        assert occurrence["attempt_count"] == 0, (
            "Acknowledged work reached the receiver"
        )
        job = self.notification_job(occurrence["id"])
        if (
            occurrence["status"] == "pending"
            and occurrence["gates"] == ["acknowledgement"]
            and job["state"] == "scheduled"
            and job["args"].get("mondek_hold_revision") == occurrence["gate_revision"]
        ):
            return {"occurrence": occurrence, "job": job}
        return False

    def capture(self, name: str, id_: str) -> dict:
        detail = self.group(id_)
        (self.output / f"group-{name}.json").write_text(json.dumps(detail, indent=2))
        return detail

    def recover(self, id_: str) -> dict:
        boundary = self.samples({target: HEALTHY for target in SAMPLES})
        self.wait_measurements(dict.fromkeys(SAMPLES, "OK"), boundary)
        detail = self.eventually(
            "shared incident closes after all contributors recover",
            lambda: (
                value
                if (value := self.group(id_))["incident"]["status"] == "closed"
                else False
            ),
        )
        assert detail["counts"]["open"] == 0
        assert self.incident_list()["total"] == 0
        assert detail["incident"]["closing_observation_id"]
        if detail["attempts"]:
            self.eventually(
                "delivered terminal receipt preserves exact closing authority",
                lambda: self.resolved_delivery(id_),
            )
        return self.capture("closed-" + id_, id_)

    def clean_start(self) -> dict:
        self.compose(
            "up", "--build", "--detach", "--wait", "--wait-timeout", "180", *SERVICES
        )
        rows = self.eventually(
            "two installed independent consumers measure healthy results",
            lambda: (
                rows
                if all(
                    (
                        rows := {key: self.measured(key, "OK") for key in SAMPLES}
                    ).values()
                )
                else False
            ),
            timeout=180,
        )
        self.initial = rows
        assert self.overview()["runner_count"] == 2
        assert self.overview()["coverage"]["expected_count"] == 2
        assert len({row["runner_id"] for row in rows.values()}) == 2
        assert {row["source_id"] for row in rows.values()} == {
            "linux-volume-monitoring",
            "elasticsearch-monitoring",
        }
        assert all(row["environment"] == "production" for row in rows.values())
        assert self.incident_list()["total"] == 0
        running = self.compose("ps", "--services", "--status", "running", capture=True)
        assert set(running.splitlines()) == {
            "postgres",
            "controller",
            "target",
            *SERVICES,
        }
        return {"streams": rows, "project": self.project}

    def corroboration_and_acknowledgement(self) -> dict:
        windows = [
            self.save_window(
                self.seed_window(row["assignment_id"], name="Review shared failure")
            )
            for row in self.initial.values()
        ]
        boundary = self.samples({VOLUME: {"used_percent": 92}})
        self.wait_measurements({VOLUME: "WARN"}, boundary)
        opened = self.eventually(
            "one shared warning", lambda: self.one_group(1, "WARN")
        )
        id_ = opened["incident"]["id"]
        assert opened["counts"]["contradictory_results"] == 1
        acknowledged = self.acknowledge(opened)
        revision = acknowledged["incident"]["acknowledgement_revision"]
        warning = self.occurrence(id_, "severity", "WARN")
        assert warning["attempt_count"] == 0

        boundary = self.samples(
            {ELASTICSEARCH: {"used_percent": 92, "sample_age_seconds": 30}}
        )
        self.eventually(
            "old peer evidence remains visibly stale",
            lambda: self.uncertain(ELASTICSEARCH, "WARN", "stale", boundary),
        )
        assert self.group(id_)["counts"]["open"] == 1
        boundary = self.samples({ELASTICSEARCH: {"sample_age_seconds": 0}})
        self.wait_measurements({ELASTICSEARCH: "WARN"}, boundary)
        shared = self.eventually(
            "equivalent peer joins existing episode", lambda: self.one_group(2, "WARN")
        )
        assert shared["incident"]["id"] == id_
        assert shared["incident"]["acknowledgement_revision"] == revision
        assert shared["counts"]["shared_acknowledged"] == 2
        assert all(
            row["coverage"]["shared_acknowledgement"] for row in shared["contributions"]
        )
        assert self.occurrence(id_, "severity", "WARN")["id"] == warning["id"]

        # Unknown collection and old OK evidence are not measured recovery.
        boundary = self.samples({ELASTICSEARCH: {"available": False}})
        self.eventually(
            "peer collection unavailable",
            lambda: self.uncertain(ELASTICSEARCH, "UNKNOWN", "unavailable", boundary),
        )
        assert self.group(id_)["counts"]["open"] == 2
        boundary = self.samples(
            {
                ELASTICSEARCH: {
                    "available": True,
                    "used_percent": 40,
                    "sample_age_seconds": 30,
                }
            }
        )
        self.eventually(
            "old OK does not close contribution",
            lambda: self.uncertain(ELASTICSEARCH, "OK", "stale", boundary),
        )
        assert self.group(id_)["counts"]["open"] == 2
        boundary = self.samples(
            {ELASTICSEARCH: {"used_percent": 92, "sample_age_seconds": 0}}
        )
        self.wait_measurements({ELASTICSEARCH: "WARN"}, boundary)

        boundary = self.samples({VOLUME: {"used_percent": 96}})
        self.wait_measurements({VOLUME: "CRIT"}, boundary)
        critical = self.group(id_)
        assert not critical["incident"]["acknowledgement_active"]
        assert critical["incident"]["acknowledgement_revision"] > revision
        self.acknowledge(critical)
        boundary = self.samples({ELASTICSEARCH: {"writes_blocked": True}})
        self.wait_measurements({ELASTICSEARCH: "CRIT"}, boundary)
        impacted = self.group(id_)
        assert not impacted["incident"]["acknowledgement_active"]
        assert [impact["key"] for impact in impacted["incident"]["impacts"]] == [
            "writes-blocked"
        ]
        assert all(row["attempt_count"] == 0 for row in impacted["occurrences"])
        assert not self.receipt_rows(id_)
        held = self.acknowledge(impacted)
        for window in windows:
            self.end_window(window)
        boundary = datetime.now(UTC)
        self.wait_measurements(dict.fromkeys(SAMPLES, "CRIT"), boundary)
        assert self.group(id_)["counts"]["shared_acknowledged"] == 2
        assert not self.receipt_rows(id_)
        self.acknowledge(held, "end")
        self.eventually(
            "shared critical delivery", lambda: self.delivered(id_, "severity", "CRIT")
        )
        self.eventually(
            "explicit material impact delivery",
            lambda: self.delivered(id_, "impact", "writes-blocked"),
        )
        self.capture("acknowledgement-and-impacts", id_)
        closed = self.recover(id_)
        assert closed["incident"]["closure_reason"] == "measured_recovery"
        assert closed["counts"]["recovered"] == 2
        return {
            "condition_incident_id": id_,
            "warning_occurrence_id": warning["id"],
            "contributions": 2,
            "acknowledgement_invalidation": ["higher severity", "new material impact"],
        }

    def partial_maintenance(self) -> dict:
        window = self.save_window(
            self.seed_window(
                self.stream(VOLUME)["assignment_id"],
                name="Maintain only the volume observer",
            )
        )
        boundary = self.samples({VOLUME: {"used_percent": 96}})
        self.wait_measurements({VOLUME: "CRIT"}, boundary)
        opened = self.eventually(
            "maintained critical contribution opens an episode",
            lambda: self.one_group(1, "CRIT"),
        )
        id_ = opened["incident"]["id"]
        assert not opened["incident"]["acknowledgement_active"]
        boundary = self.samples({ELASTICSEARCH: {"used_percent": 92}})
        self.wait_measurements({ELASTICSEARCH: "WARN"}, boundary)
        shared = self.eventually(
            "warning remains uncovered beside maintained critical",
            lambda: self.one_group(2, "CRIT"),
        )
        assert shared["incident"]["id"] == id_
        assert shared["counts"]["maintained"] == 1
        assert shared["counts"]["uncovered"] == 1
        warning = self.eventually(
            "uncovered WARN delivery is not blocked by maintained CRIT",
            lambda: self.delivered(id_, "severity", "WARN"),
        )
        critical = self.occurrence(id_, "severity", "CRIT")
        assert critical["attempt_count"] == 0
        assert "maintenance" in critical["gates"]
        self.capture("partial-maintenance", id_)
        self.end_window(window)
        self.eventually(
            "ending partial maintenance releases original critical occurrence",
            lambda: self.delivered(id_, "severity", "CRIT"),
        )
        assert self.occurrence(id_, "severity", "CRIT")["id"] == critical["id"]
        self.recover(id_)
        return {
            "condition_incident_id": id_,
            "warning_occurrence_id": warning["id"],
            "critical_occurrence_id": critical["id"],
            "maintained": 1,
            "uncovered": 1,
        }

    def failure_exhaustion_and_retry(self) -> dict:
        self.mode(webhook="reject")
        boundary = self.samples({VOLUME: {"used_percent": 92}})
        self.wait_measurements({VOLUME: "WARN"}, boundary)
        opened = self.eventually(
            "new shared failure with rejected delivery",
            lambda: self.one_group(1, "WARN"),
        )
        id_ = opened["incident"]["id"]
        original = self.occurrence(id_, "severity", "WARN")
        exhausted = self.eventually(
            "real 503 responses exhaust one bounded notification budget",
            lambda: (
                value
                if (value := self.occurrence(id_, "severity", "WARN"))["status"]
                == "exhausted"
                and value["can_retry"]
                else False
            ),
            timeout=90,
        )
        assert exhausted["attempt_count"] == 3
        assert not self.receipt_rows(id_)
        attempts = [
            row
            for row in self.group(id_)["attempts"]
            if row["occurrence_id"] == original["id"]
        ]
        assert len(attempts) == 3 and all(row["http_status"] == 503 for row in attempts)
        self.wait_measurements({VOLUME: "WARN"}, datetime.now(UTC))
        assert self.occurrence(id_, "severity", "WARN")["attempt_count"] == 3
        self.mode(webhook="ok")
        self.request(
            f"/api/v1/notifications/{original['id']}/retry",
            {
                "reason": "Local receiver recovered; retry the reviewed shared occurrence"
            },
        )
        delivered = self.eventually(
            "explicit retry reaches the real local receiver",
            lambda: self.delivered(id_, "severity", "WARN"),
        )
        assert delivered["id"] == original["id"]
        assert delivered["payload"] == original["payload"]
        assert delivered["attempt_count"] == 4
        assert delivered["latest_attempt"]["http_status"] == 202
        jobs = [
            row
            for row in self.snapshot()["jobs"]
            if row["args"]["occurrence_id"] == original["id"]
        ]
        assert len(jobs) == 2 and all(row["max_attempts"] == 3 for row in jobs)
        self.capture("exhaustion-and-explicit-retry", id_)
        self.recover(id_)
        return {
            "condition_incident_id": id_,
            "occurrence_id": original["id"],
            "rejected_attempts": 3,
            "accepted_retry_attempts": 1,
            "immutable_payload": original["payload"],
        }

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
        # Mutate only the installed package in this invocation's owned container.
        script = (
            "from pathlib import Path; import importlib.util; p=Path(importlib.util.find_spec('mondek_examples.grouped').origin); "
            + f"p.write_text({source!r})"
        )
        self.compose("exec", "-T", "--user", "0", service, "python", "-c", script)
        self.compose("restart", service)

    def offline_cohort(self, boundary: datetime) -> dict | bool:
        sample = self.node_journal(VOLUME_SERVICE)
        reports = [
            report
            for report in sample["reports"]
            if after_boundary(report["started_at"], boundary)
        ]
        return sample if len(reports) >= 3 else False

    def restart_reconnect_and_withdrawal(self) -> dict:
        windows = [
            self.save_window(
                self.seed_window(
                    self.stream(target)["assignment_id"],
                    name="Establish pending grouped delivery before restart",
                )
            )
            for target in SAMPLES
        ]
        boundary = self.samples({target: {"used_percent": 92} for target in SAMPLES})
        rows = self.wait_measurements(dict.fromkeys(SAMPLES, "WARN"), boundary)
        opened = self.eventually(
            "shared failure before restart", lambda: self.one_group(2, "WARN")
        )
        id_ = opened["incident"]["id"]
        held = self.acknowledge(self.group(id_))
        acknowledgement_revision = held["incident"]["acknowledgement_revision"]
        for window in windows:
            self.end_window(window)
        pending_before = self.eventually(
            "original pending warning is held only by shared acknowledgement",
            lambda: self.pending_warning(id_),
        )
        assert pending_before["job"]["attempt"] == 0
        assert pending_before["job"]["max_attempts"] == 3
        assert not self.receipt_rows(id_)
        runner_id = rows[VOLUME]["runner_id"]
        baseline = self.node_journal(VOLUME_SERVICE)
        samples = [baseline]
        original: list[dict] = []
        try:
            self.mode(offline_installations=[runner_id])
            boundary = datetime.now(UTC)
            buffered = self.eventually(
                "disconnected observer continues executing and journals original evidence",
                lambda: self.offline_cohort(boundary),
            )
            samples.append(buffered)
            original = [
                row
                for row in buffered["reports"]
                if after_boundary(row["started_at"], boundary)
            ]
            self.eventually(
                "offline contributor is stale while its peer advances",
                lambda: (
                    self.stream(VOLUME)["current"]["knowledge"] == "stale"
                    and self.measured(ELASTICSEARCH, "WARN", boundary)
                ),
            )
            self.compose("restart", "controller")
            persisted = self.eventually(
                "shared episode survives controller restart", lambda: self.group(id_)
            )
            assert (
                persisted["incident"]["acknowledgement_revision"]
                == acknowledgement_revision
            )
            assert persisted["counts"]["open"] == 2
            pending_restarted = self.eventually(
                "controller reconstructs the original pending warning job",
                lambda: self.pending_warning(id_),
            )
            assert_preserved_pending_delivery(pending_before, pending_restarted)
            self.compose("restart", VOLUME_SERVICE)
            restarted = self.eventually(
                "restarted disconnected runner has a new durable session and fresh execution",
                lambda: (
                    value
                    if (value := self.node_journal(VOLUME_SERVICE))["status"]["boot"]
                    > baseline["status"]["boot"]
                    and any(
                        row["session_id"] == value["status"]["session_id"]
                        for row in value["reports"]
                    )
                    else False
                ),
            )
            samples.append(restarted)
            assert restarted["status"]["installation_id"] == runner_id
            assert restarted["status"]["session_id"] != baseline["status"]["session_id"]
            queued = {row["id"]: row for row in restarted["reports"]}
            assert all(queued[row["id"]] == row for row in original)
        finally:
            self.mode(offline_installations=[])
        ids = [row["id"] for row in original]
        stored = self.eventually(
            "every captured pre-restart report is retained exactly",
            lambda: (
                value if len(value := self.stored_reports(ids)) == len(ids) else False
            ),
        )
        witness = exact_buffered_evidence(original, stored)
        assert witness["historical"] == len(original)
        recovered = self.eventually(
            "current measurements use the new runner session",
            lambda: (
                row
                if (row := self.measured(VOLUME, "WARN"))
                and row["current"]["session_id"] == restarted["status"]["session_id"]
                else False
            ),
        )
        for key in (
            "id",
            "assignment_id",
            "runner_id",
            "desired_generation",
            "source_revision",
        ):
            assert recovered[key] == rows[VOLUME][key], f"Restart changed {key}"
        after = self.group(id_)
        assert after["incident"]["acknowledgement_revision"] == acknowledgement_revision
        assert after["counts"]["shared_acknowledged"] == 2
        assert {item["incident"]["id"] for item in after["contributions"]} == {
            item["incident"]["id"] for item in opened["contributions"]
        }
        pending_after = self.eventually(
            "replayed evidence leaves the original pending delivery and budget intact",
            lambda: self.pending_warning(id_),
        )
        assert_preserved_pending_delivery(pending_before, pending_after)
        assert not self.receipt_rows(id_)
        self.capture("restarted-pending-delivery", id_)

        self.acknowledge(after, "end")
        delivered = self.eventually(
            "ending the restored acknowledgement delivers the original occurrence",
            lambda: self.delivered(id_, "severity", "WARN"),
        )
        assert delivered["id"] == pending_before["occurrence"]["id"]
        assert delivered["payload"] == pending_before["occurrence"]["payload"]
        assert delivered["attempt_count"] == 1
        completed_job = self.eventually(
            "the original job completes with its first actual HTTP attempt",
            lambda: (
                value
                if (value := self.notification_job(delivered["id"]))["state"]
                == "completed"
                else False
            ),
        )
        assert completed_job["id"] == pending_before["job"]["id"]
        assert completed_job["max_attempts"] == pending_before["job"]["max_attempts"]
        assert completed_job["attempt"] == pending_before["job"]["attempt"] + 1

        restart_acknowledgement_revision = acknowledgement_revision
        held = self.acknowledge(self.group(id_))
        acknowledgement_revision = held["incident"]["acknowledgement_revision"]
        samples.append(self.node_journal(VOLUME_SERVICE))
        assert samples[-1]["status"]["dropped"] == baseline["status"]["dropped"]
        (self.output / "grouped-journal.json").write_text(
            json.dumps(
                {
                    "samples": samples,
                    "stored": stored,
                    "proof": witness,
                    "pending_delivery": {
                        "before_restart": pending_before,
                        "after_restart": pending_restarted,
                        "after_replay": pending_after,
                        "delivered": delivered,
                        "completed_job": completed_job,
                    },
                },
                indent=2,
            )
        )

        source = self.installed_source(VOLUME_SERVICE)
        try:
            self.deploy_source(
                VOLUME_SERVICE,
                source
                + "\n# Explicit complete source withdrawal in this disposable installation.\napp.bindings.clear()\n",
            )
            withdrawn = self.eventually(
                "source removal withdraws only its contribution",
                lambda: (
                    value
                    if (value := self.group(id_))["counts"]["withdrawn"] == 1
                    else False
                ),
            )
            assert withdrawn["incident"]["status"] == "open"
            assert withdrawn["counts"]["open"] == 1
            removed = next(
                item
                for item in withdrawn["contributions"]
                if item["contribution_state"] == "withdrawn"
            )
            assert removed["incident"]["closure_reason"] == "source_removed"
            assert removed["evidence_ids"]["closing"] is None
            assert self.request("/api/v1/checks/" + rows[VOLUME]["id"])["stream"][
                "retired"
            ]
            self.capture("withdrawn-contributor", id_)
        finally:
            self.deploy_source(VOLUME_SERVICE, source)
        restored = self.eventually(
            "restored source starts a new measured contribution",
            lambda: self.measured(VOLUME, "WARN"),
            timeout=90,
        )
        assert restored["id"] != rows[VOLUME]["id"]
        rejoined = self.eventually(
            "restored equivalent contribution stays in shared acknowledged episode",
            lambda: self.one_group(2, "WARN"),
        )
        assert rejoined["incident"]["id"] == id_
        assert rejoined["counts"]["withdrawn"] == 1
        assert rejoined["counts"]["shared_acknowledged"] == 2
        assert (
            rejoined["incident"]["acknowledgement_revision"] == acknowledgement_revision
        )
        closed = self.recover(id_)
        assert closed["counts"]["recovered"] == 2
        assert closed["counts"]["withdrawn"] == 1
        # Measured recovery does not erase the earlier source withdrawal. The
        # terminal reason retains the one non-recovery reason in this episode.
        assert closed["incident"]["closure_reason"] == "source_removed"
        return {
            "condition_incident_id": id_,
            "buffered_evidence": witness,
            "old_stream": rows[VOLUME]["id"],
            "restored_stream": restored["id"],
            "restarted_pending_occurrence_id": delivered["id"],
            "preserved_job_id": completed_job["id"],
            "restart_acknowledgement_revision": restart_acknowledgement_revision,
            "acknowledgement_revision": acknowledgement_revision,
            "closure_reason": "source_removed",
        }

    def run(self) -> None:
        print(
            f"Grouped incident project: {self.project}; UI: {self.base}; evidence: {self.output}",
            flush=True,
        )
        success = False
        try:
            for label, function in (
                (
                    "two installed independent observers declare one condition",
                    self.clean_start,
                ),
                (
                    "corroboration, collection uncertainty and shared acknowledgement scope",
                    self.corroboration_and_acknowledgement,
                ),
                (
                    "partial maintenance leaves lower-severity uncovered evidence eligible",
                    self.partial_maintenance,
                ),
                (
                    "real notification rejection, exhaustion and explicit immutable retry",
                    self.failure_exhaustion_and_retry,
                ),
                (
                    "controller/runner restart, original-age replay, source withdrawal and recovery",
                    self.restart_reconnect_and_withdrawal,
                ),
            ):
                self.run_step(label, function)
            closed = self.incident_list(status="closed")
            assert closed["total"] == len(self.group_ids) == 4
            assert {row["id"] for row in closed["items"]} == set(self.group_ids)
            success = True
        finally:
            self.finish(success)
            print(f"Evidence: {self.output}", flush=True)
        print("All real grouped-incident scenarios passed.", flush=True)


if __name__ == "__main__":
    GroupedAcceptance().run()
