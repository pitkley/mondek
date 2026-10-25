#!/usr/bin/env python3
# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Acknowledgements against packaged services, real measurements and HTTP receipts."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from typing import Any

from acceptance import Acceptance


class AcknowledgementAcceptance(Acceptance):
    def current_incident(self, id_: str) -> dict:
        return next(i for i in self.snapshot()["incidents"] if i["id"] == id_)

    def acknowledge(self, incident: dict, mode: str, **options: Any) -> dict:
        return self.request(
            f"/api/v1/incidents/{incident['id']}/acknowledge",
            {
                "mode": mode,
                "revision": incident["acknowledgement_revision"],
                "attention_revision": incident["attention_revision"],
                "note": "Real-service acknowledgement acceptance",
            }
            | options,
        )

    def maintenance(self, assignment: str, seconds: int) -> None:
        self.reviewed_maintenance(
            assignment, seconds, "Isolate acknowledgement delivery scenario"
        )

    def occurrence(self, incident_id: str) -> dict:
        return next(
            o
            for o in self.snapshot()["occurrences"]
            if o["incident_id"] == incident_id and o["kind"] != "resolved"
        )

    def receipts(self, incident_id: str) -> list[dict]:
        return [
            r for r in self.records() if r["payload"].get("incident_id") == incident_id
        ]

    def job(self, occurrence_id: str) -> dict:
        return next(
            j
            for j in self.snapshot()["jobs"]
            if j["args"]["occurrence_id"] == occurrence_id
        )

    def sleeping_job(self, occurrence_id: str) -> dict | None:
        job = self.job(occurrence_id)
        if (
            job["state"] == "scheduled"
            and "mondek_hold_revision" in job["args"]
            and datetime.fromisoformat(job["scheduled_at"])
            > datetime.now(timezone.utc) + timedelta(hours=12)
        ):
            return job
        return None

    def more_measurements(self, assignment: str) -> None:
        sequence = self.assignment(assignment)["last_sequence"]
        self.eventually(
            "acknowledgement does not pause execution",
            lambda: self.assignment(assignment)["last_sequence"] >= sequence + 2,
        )

    def indefinite_restart_and_cancel(self) -> dict:
        self.maintenance("http", 7200)
        self.mode(ready=False)
        incident = self.eventually(
            "maintained HTTP failure", lambda: self.incident("http")
        )
        acknowledged = self.acknowledge(incident, "until_incident_ends")
        assert acknowledged["acknowledged_until"] is None
        self.maintenance("http", 0)
        self.more_measurements("http")
        held = self.occurrence(incident["id"])
        assert held["gates"] == ["acknowledgement"]
        assert held["next_retry_at"] is None
        assert held["attempt_count"] == 0 and not self.receipts(incident["id"])

        self.compose("restart", "controller")
        self.eventually(
            "controller returns with held incident",
            lambda: self.current_incident(incident["id"]),
        )
        self.more_measurements("http")
        persisted = self.current_incident(incident["id"])
        assert persisted["acknowledgement_mode"] == "until_incident_ends"
        assert (
            persisted["acknowledgement_revision"]
            == acknowledged["acknowledgement_revision"]
        )
        assert self.occurrence(incident["id"])["attempt_count"] == 0
        assert not self.receipts(incident["id"])

        # Ending one hold must leave the independent maintenance gate intact.
        self.maintenance("http", 7200)
        self.acknowledge(persisted, "end")
        self.more_measurements("http")
        assert self.occurrence(incident["id"])["gates"] == ["maintenance"]
        assert not self.receipts(incident["id"])
        self.maintenance("http", 0)
        self.eventually(
            "ending long hold wakes original occurrence",
            lambda: self.receipts(incident["id"]),
            timeout=20,
        )
        delivered = self.occurrence(incident["id"])
        assert delivered["id"] == held["id"]
        assert delivered["payload"] == held["payload"]
        assert delivered["attempt_count"] == 1
        self.mode(ready=True)
        self.eventually("HTTP measured recovery", lambda: self.incident("http") is None)
        return {
            "incident": incident["id"],
            "occurrence": held["id"],
            "restart_preserved_hold": True,
            "attempts": 1,
        }

    def long_duration_and_expiry(self) -> dict:
        self.maintenance("http", 7200)
        self.mode(ready=False)
        incident = self.eventually("second HTTP failure", lambda: self.incident("http"))
        long_ack = self.acknowledge(incident, "duration", seconds=90 * 86400)
        deadline = datetime.fromisoformat(long_ack["acknowledged_until"])
        assert deadline > datetime.now(timezone.utc) + timedelta(days=89)
        # Stale cancellation cannot silently overwrite the longer acknowledgement.
        self.request(
            f"/api/v1/incidents/{incident['id']}/acknowledge",
            {
                "mode": "end",
                "revision": incident["acknowledgement_revision"],
                "attention_revision": incident["attention_revision"],
                "note": "Stale cancellation",
            },
            code=409,
        )
        assert (
            self.current_incident(incident["id"])["acknowledged_until"]
            == long_ack["acknowledged_until"]
        )
        self.maintenance("http", 0)
        self.more_measurements("http")
        assert not self.receipts(incident["id"])
        original = self.occurrence(incident["id"])
        sleeping = self.eventually(
            "long hold durably sleeps without short polling",
            lambda: self.sleeping_job(original["id"]),
        )
        # Replacing a months-long hold must reschedule its existing sleeping job.
        expiry = datetime.now(timezone.utc) + timedelta(seconds=10)
        self.acknowledge(long_ack, "until", expires_at=expiry.isoformat())
        assert not self.receipts(incident["id"])
        received = self.eventually(
            "shortened explicit expiry releases delivery",
            lambda: self.receipts(incident["id"]),
            timeout=30,
        )
        assert all(
            datetime.fromisoformat(receipt["received_at"]) >= expiry
            for receipt in received
        )
        delivered = self.occurrence(incident["id"])
        assert (
            delivered["id"] == original["id"]
            and delivered["payload"] == original["payload"]
        )
        assert delivered["attempt_count"] == 1
        assert self.job(original["id"])["id"] == sleeping["id"]
        self.mode(ready=True)
        self.eventually(
            "second measured recovery", lambda: self.incident("http") is None
        )
        return {
            "incident": incident["id"],
            "original_days": 90,
            "expiry": expiry.isoformat(),
            "receipts": len(received),
            "stale_cancel_rejected": True,
        }

    def severity_and_recovery(self) -> dict:
        self.maintenance("consumer", 7200)
        self.mode(backlog=6, processing_enabled=True)
        incident = self.eventually(
            "consumer WARNING", lambda: self.incident("consumer")
        )
        assert incident["health"] == "WARN"
        self.acknowledge(incident, "until_incident_ends")
        self.maintenance("consumer", 0)
        self.more_measurements("consumer")
        assert not self.receipts(incident["id"])
        self.mode(backlog=12)
        self.eventually(
            "above-ceiling failure delivers", lambda: self.receipts(incident["id"])
        )
        escalated = self.current_incident(incident["id"])
        assert escalated["health"] == "CRIT"
        assert escalated["acknowledgement_mode"] is None
        ack = self.acknowledge(escalated, "until_incident_ends")
        receipts_before = len(self.receipts(incident["id"]))
        self.mode(backlog=6)
        self.eventually(
            "downgrade retains acknowledgement",
            lambda: self.current_incident(incident["id"])["health"] == "WARN",
        )
        self.mode(backlog=12)
        self.eventually(
            "return within original ceiling",
            lambda: self.current_incident(incident["id"])["health"] == "CRIT",
        )
        current = self.current_incident(incident["id"])
        assert current["acknowledgement_revision"] == ack["acknowledgement_revision"]
        assert current["acknowledgement_mode"] == "until_incident_ends"
        self.more_measurements("consumer")
        assert len(self.receipts(incident["id"])) == receipts_before
        updates = [
            o
            for o in self.snapshot()["occurrences"]
            if o["incident_id"] == incident["id"]
            and o["attention_revision"] > escalated["attention_revision"]
        ]
        assert len(updates) == 2 and all(o["attempt_count"] == 0 for o in updates)
        self.mode(backlog=2)
        self.eventually(
            "recovery ends acknowledgement", lambda: self.incident("consumer") is None
        )
        closed = self.current_incident(incident["id"])
        assert closed["acknowledgement_mode"] is None
        assert closed["acknowledged_until"] is None
        self.eventually(
            "acknowledgement permits terminal notice",
            lambda: any(
                r["payload"]["kind"] == "resolved"
                for r in self.receipts(incident["id"])
            ),
        )
        return {
            "incident": incident["id"],
            "above_ceiling_ended_hold": True,
            "within_ceiling_preserved_hold": True,
            "recovery_cleared_hold": True,
        }

    def retry_and_suppressed_recovery(self) -> dict:
        self.mode(ready=False, webhook="reject")
        incident = self.eventually(
            "retry incident opens", lambda: self.incident("http")
        )
        self.eventually(
            "real receiver rejection recorded",
            lambda: self.occurrence(incident["id"])["attempt_count"] >= 1,
        )
        self.acknowledge(self.current_incident(incident["id"]), "until_incident_ends")
        self.eventually(
            "in-flight attempt settles",
            lambda: self.occurrence(incident["id"])["status"] == "retrying",
        )
        held = self.occurrence(incident["id"])
        self.mode(webhook="ok")
        self.more_measurements("http")
        assert self.occurrence(incident["id"])["attempt_count"] == held["attempt_count"]
        self.acknowledge(self.current_incident(incident["id"]), "end")
        self.eventually(
            "existing retry resumes promptly",
            lambda: self.receipts(incident["id"]),
            timeout=20,
        )
        delivered = self.occurrence(incident["id"])
        assert delivered["id"] == held["id"] and delivered["payload"] == held["payload"]
        assert delivered["attempt_count"] == held["attempt_count"] + 1
        self.mode(ready=True)
        self.eventually("retry episode recovers", lambda: self.incident("http") is None)

        self.maintenance("http", 7200)
        self.mode(ready=False)
        suppressed = self.eventually(
            "never-delivered episode", lambda: self.incident("http")
        )
        self.acknowledge(suppressed, "until_incident_ends")
        self.maintenance("http", 0)
        self.mode(ready=True)
        self.eventually("held episode recovers", lambda: self.incident("http") is None)
        self.more_measurements("http")
        assert not self.receipts(suppressed["id"])
        assert self.occurrence(suppressed["id"])["status"] == "superseded"
        assert self.current_incident(suppressed["id"])["acknowledgement_mode"] is None
        return {
            "retry_incident": incident["id"],
            "same_payload_resumed": True,
            "suppressed_incident": suppressed["id"],
            "obsolete_firing_not_sent": True,
        }

    def run(self) -> None:
        success = False
        try:
            for label, scenario in [
                ("packaged startup and three fresh checks", self.clean_start),
                (
                    "indefinite hold survives restart and cancellation preserves maintenance",
                    self.indefinite_restart_and_cancel,
                ),
                (
                    "long duration, stale cancellation and explicit shortened expiry",
                    self.long_duration_and_expiry,
                ),
                ("severity ceiling and measured recovery", self.severity_and_recovery),
                (
                    "existing retries resume and recovered held alerts stay obsolete",
                    self.retry_and_suppressed_recovery,
                ),
            ]:
                self.run_step(label, scenario)
            success = True
        finally:
            self.finish(success)
            print(f"Evidence: {self.output}", flush=True)


if __name__ == "__main__":
    AcknowledgementAcceptance().run()
