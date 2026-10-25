#!/usr/bin/env python3
# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Scheduled maintenance with real clocks, services, notifications and moving targets."""

from __future__ import annotations

import json
import time
from datetime import datetime, timedelta, timezone
from typing import Any

from acknowledgements import AcknowledgementAcceptance
from durable_rules import DEFAULTS, NODE_A, NODE_B, TARGET, DurableRulesAcceptance


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


def local_utc(value: datetime) -> str:
    return value.replace(tzinfo=None).isoformat(timespec="seconds")


def series_intervals(rows: list[dict]) -> list[tuple[int, str, str]]:
    """Compare exact reviewed instants, never newly computed dates after restart."""
    indexes = [row["index"] for row in rows]
    assert len(indexes) == len(set(indexes)), "Repeated series window index"
    intervals = []
    for row in rows:
        start = datetime.fromisoformat(row["starts_at"])
        end = datetime.fromisoformat(row["ends_at"])
        assert start.utcoffset() == end.utcoffset() == timedelta(), (
            "Expected resolved UTC"
        )
        assert end > start, "Series window must have positive resolved duration"
        intervals.append(
            (
                row["index"],
                start.isoformat(timespec="microseconds"),
                end.isoformat(timespec="microseconds"),
            )
        )
    return sorted(intervals)


def remaining_attempts(job: dict) -> int:
    # Oban snoozes can extend both counters together; their difference is the
    # remaining dispatch budget, unlike the absolute maximum attempt counter.
    return job["max_attempts"] - job["attempt"]


def assert_held_notification(
    before: dict, after: dict, old_job: dict, job: dict
) -> None:
    assert after["id"] == before["id"]
    assert after["payload"] == before["payload"]
    assert after["attempt_count"] == before["attempt_count"]
    assert after["gates"] == ["maintenance"]
    assert job["id"] == old_job["id"]
    assert remaining_attempts(job) == remaining_attempts(old_job), (
        "Maintenance changed the original notification's remaining retry budget"
    )


class MaintenanceClient:
    """Shared HTTP actions; execution and evidence come from the real consumer runners."""

    def window(self, id_: str) -> dict:
        return self.request(f"/api/v1/maintenance/{id_}")

    def seed_window(self, assignment_id: str, **changes: Any) -> dict:
        seeded = self.request(
            f"/api/v1/maintenance/seed/{self.assignment(assignment_id)['id']}"
        )
        scope = next(
            option
            for option in seeded["scope_options"]
            if option["scope"] == changes.get("scope", "check")
        )
        return (
            seeded["proposal"]
            | {key: value for key, value in scope.items() if key != "label"}
            | {
                "name": "Real-service maintenance",
                "reason": "Verify scheduled local notification controls",
                "timezone": "UTC",
                "start_mode": "now",
                "ends_local": local_utc(utc_now() + timedelta(days=90)),
            }
            | changes
        )

    def save_window(self, proposal: dict) -> dict:
        preview = self.request("/api/v1/maintenance/preview", {"proposal": proposal})
        saved = self.request(
            "/api/v1/maintenance/apply",
            {"proposal": preview["proposal"], "review_token": preview["review_token"]},
        )
        assert saved["starts_at"] == preview["starts_at"]
        assert saved["ends_at"] == preview["ends_at"]
        return saved

    def selection_window(self, *proposals: dict, name: str) -> dict:
        fields = (
            "scope",
            "assignment_id",
            "source_id",
            "environment",
            "target_kind",
            "target_key",
        )
        return proposals[0] | {
            **dict.fromkeys(fields),
            "scope": "selection",
            "selections": [
                {field: proposal.get(field) for field in fields}
                for proposal in proposals
            ],
            "name": name,
        }

    def end_window(self, window: dict, *, code: int = 200) -> dict:
        return self.request(
            f"/api/v1/maintenance/{window['id']}/cancel",
            {"revision": window["revision"], "reason": "Finished acceptance work"},
            code=code,
        )

    def series(self, id_: str) -> dict:
        return self.request(f"/api/v1/maintenance-series/{id_}")

    def save_series(self, proposal: dict) -> tuple[dict, dict]:
        preview = self.request(
            "/api/v1/maintenance-series/preview", {"proposal": proposal}
        )
        saved = self.request(
            "/api/v1/maintenance-series/apply",
            {"proposal": preview["proposal"], "review_token": preview["review_token"]},
        )
        assert series_intervals(saved["occurrences"]) == series_intervals(
            preview["occurrences"]
        )
        return preview, saved

    def cancel_series_upcoming(self, series: dict, reason: str) -> tuple[dict, dict]:
        preview = self.request(
            f"/api/v1/maintenance-series/{series['id']}/cancel-preview",
            {"revision": series["revision"], "reason": reason},
        )
        saved = self.request(
            f"/api/v1/maintenance-series/{series['id']}/cancel",
            {"review_token": preview["review_token"], "reason": reason},
        )
        return preview, saved

    def save_maintenance_evidence(self) -> None:
        for view in ("current", "history"):
            (self.output / f"maintenance-{view}.json").write_text(
                json.dumps(self.request(f"/api/v1/maintenance?status={view}"), indent=2)
            )


class MaintenanceAcceptance(MaintenanceClient, AcknowledgementAcceptance):
    def recurring_windows_preserve_real_delivery(self) -> dict:
        self.mode(ready=True, backlog=2, processing_enabled=True, webhook="ok")
        start = utc_now() + timedelta(seconds=35)
        proposal = self.selection_window(
            self.seed_window("http"),
            self.seed_window("consumer"),
            name="Finite weekly service deployment",
        ) | {
            "start_mode": "scheduled",
            "starts_local": local_utc(start),
            "ends_local": local_utc(start + timedelta(minutes=5)),
            "recurrence": {
                "frequency": "weekly",
                "interval": 1,
                "end_mode": "count",
                "count": 3,
                "until_date": None,
            },
        }
        preview, scheduled = self.save_series(proposal)
        assert preview["occurrence_total"] == 3
        assert preview["counts"] == {"matched_results": 2, "matched_checks": 2}
        reviewed_instants = series_intervals(preview["occurrences"])
        windows = sorted(scheduled["occurrences"], key=lambda row: row["index"])
        assert len(windows) == 3
        active_id = windows[0]["id"]
        resolved_start = datetime.fromisoformat(windows[0]["starts_at"])
        for previous, later in zip(windows, windows[1:]):
            assert datetime.fromisoformat(later["starts_at"]) - datetime.fromisoformat(
                previous["starts_at"]
            ) == timedelta(weeks=1)

        self.mode(ready=False)
        early = self.eventually(
            "a real failure before the first recurring window",
            lambda: self.incident("http"),
        )
        delivered_early = self.eventually(
            "a future series does not hold an early notification",
            lambda: self.receipts(early["id"]),
        )
        assert (
            datetime.fromisoformat(delivered_early[0]["received_at"]) < resolved_start
        )
        self.mode(ready=True)
        self.eventually(
            "pre-series HTTP failure recovers", lambda: self.incident("http") is None
        )

        self.mode(backlog=12, processing_enabled=False, webhook="reject")
        retry_incident = self.eventually(
            "a real consumer failure before the series",
            lambda: self.incident("consumer"),
        )
        retry_before_restart = self.eventually(
            "a local webhook rejects the original consumer delivery",
            lambda: (
                occurrence
                if (occurrence := self.occurrence(retry_incident["id"]))[
                    "attempt_count"
                ]
                >= 1
                and occurrence["status"] == "retrying"
                else False
            ),
        )
        retry_job_before_restart = self.job(retry_before_restart["id"])
        self.compose("stop", "controller")
        # Real wall-clock crossing: the installed runner keeps its accepted
        # schedule while the controller is stopped. No clock injection is used.
        while utc_now() < resolved_start + timedelta(seconds=1):
            time.sleep(0.5)
        self.mode(ready=False, webhook="ok")
        self.compose("start", "controller")
        restored = self.eventually(
            "persisted recurring windows return after controller restart",
            lambda: self.series(scheduled["id"]),
        )
        assert series_intervals(restored["occurrences"]) == reviewed_instants
        assert restored["active_count"] == 1 and restored["upcoming_count"] == 2
        http_incident = self.eventually(
            "a distinct HTTP failure during the active first window",
            lambda: self.incident("http"),
        )
        assert http_incident["id"] != early["id"]
        held = {}
        for key, incident in (("http", http_incident), ("consumer", retry_incident)):
            self.more_measurements(key)
            current = self.assignment(key)["current"]
            assert current["knowledge"] == "fresh" and current["health"] == "CRIT"
            assert datetime.fromisoformat(current["source_at"]) >= resolved_start
            occurrence = self.occurrence(incident["id"])
            assert occurrence["gates"] == ["maintenance"]
            assert not self.receipts(incident["id"])
            job = self.eventually(
                f"the existing {key} job is parked until the active child ends",
                lambda occurrence=occurrence: (
                    job
                    if (job := self.job(occurrence["id"]))["state"] == "scheduled"
                    and "mondek_hold_revision" in job["args"]
                    else False
                ),
            )
            held[key] = (occurrence, job)
        assert held["http"][0]["attempt_count"] == 0
        assert held["consumer"][0]["attempt_count"] >= 1
        assert held["consumer"][0]["id"] == retry_before_restart["id"]
        assert held["consumer"][0]["payload"] == retry_before_restart["payload"]
        assert held["consumer"][1]["id"] == retry_job_before_restart["id"]

        cancel_review, cancelled = self.cancel_series_upcoming(
            restored, "Cancel the remaining deployment dates, keep today's work active"
        )
        assert cancel_review["active_count"] == 1
        assert cancel_review["upcoming_count"] == 2
        assert cancelled["active_count"] == 1 and cancelled["upcoming_count"] == 0
        assert self.window(active_id)["status"] == "active"
        for window in windows[1:]:
            assert self.window(window["id"])["status"] == "cancelled"
        for key, incident in (("http", http_incident), ("consumer", retry_incident)):
            self.more_measurements(key)
            before, old_job = held[key]
            assert_held_notification(
                before,
                self.occurrence(incident["id"]),
                old_job,
                self.job(before["id"]),
            )
            assert not self.receipts(incident["id"])

        active = self.window(active_id)
        expiry = utc_now() + timedelta(seconds=12)
        changed = self.save_window(
            active["proposal"]
            | {
                "reason": "Today's deployment finishes early; later windows remain cancelled",
                "ends_local": local_utc(expiry),
            }
        )
        assert changed["starts_at"] == windows[0]["starts_at"]
        assert self.window(active_id)["exception"] is True
        for key, incident in (("http", http_incident), ("consumer", retry_incident)):
            self.eventually(
                f"the original {key} notification resumes at the edited child's end",
                lambda incident=incident: self.receipts(incident["id"]),
                timeout=35,
            )
            before, old_job = held[key]
            delivered = self.occurrence(incident["id"])
            assert delivered["id"] == before["id"]
            assert delivered["payload"] == before["payload"]
            assert delivered["attempt_count"] == before["attempt_count"] + 1
            job = self.job(delivered["id"])
            assert job["id"] == old_job["id"]
            assert remaining_attempts(job) == remaining_attempts(old_job) - 1
            assert datetime.fromisoformat(
                self.receipts(incident["id"])[0]["received_at"]
            ) >= (datetime.fromisoformat(changed["ends_at"]))
        final = self.series(scheduled["id"])
        (self.output / "recurring-maintenance.json").write_text(
            json.dumps(
                {
                    "review": preview,
                    "saved": scheduled,
                    "after_restart": restored,
                    "cancellation_review": cancel_review,
                    "final": final,
                },
                indent=2,
            )
        )
        self.mode(ready=True, backlog=2, processing_enabled=True)
        for key in ("http", "consumer"):
            self.eventually(
                f"{key} recovery is still measured",
                lambda key=key: self.incident(key) is None,
            )
        return {
            "series": scheduled["id"],
            "windows": [window["id"] for window in windows],
            "persisted_instants": reviewed_instants,
            "pre_window_incident": early["id"],
            "held_incidents": {
                "http": http_incident["id"],
                "consumer": retry_incident["id"],
            },
            "held_attempts": {
                key: item[0]["attempt_count"] for key, item in held.items()
            },
            "exact_child_expiry": changed["ends_at"],
            "future_cancel_kept_active": True,
            "original_delivery_budgets_preserved": True,
        }

    def composite_window_preserves_independent_holds(self) -> dict:
        proposal = self.selection_window(
            self.seed_window("http"),
            self.seed_window("consumer"),
            self.seed_window("http", scope="target"),
            name="One deployment across selected checks and targets",
        )
        preview = self.request("/api/v1/maintenance/preview", {"proposal": proposal})
        assert preview["counts"] == {"matched_results": 2, "matched_checks": 2}
        assert len(preview["selection_summary"]) == 3
        window = self.request(
            "/api/v1/maintenance/apply",
            {"proposal": preview["proposal"], "review_token": preview["review_token"]},
        )
        overlap = self.save_window(
            self.seed_window("http", name="Independent HTTP work")
        )
        original_disk = self.assignment("filesystem")
        self.request(
            f"/api/v1/assignments/{self.assignment('filesystem')['id']}",
            {
                "revision": original_disk["revision"],
                "params": original_disk["params"]
                | {"warn_percent": 0, "crit_percent": 0.01},
            },
            method="PUT",
        )
        self.mode(ready=False, backlog=12, processing_enabled=False, webhook="ok")
        incidents = {
            key: self.eventually(
                f"real {key} failure", lambda key=key: self.incident(key)
            )
            for key in ("http", "consumer", "filesystem")
        }
        self.eventually(
            "unselected disk failure still delivers",
            lambda: self.receipts(incidents["filesystem"]["id"]),
        )
        held = {}
        for key in ("http", "consumer"):
            self.more_measurements(key)
            occurrence = self.occurrence(incidents[key]["id"])
            assert occurrence["gates"] == ["maintenance"]
            assert occurrence["attempt_count"] == 0
            assert not self.receipts(incidents[key]["id"])
            job = self.eventually(
                f"{key} maintenance hold snoozes the original job",
                lambda occurrence=occurrence: self.sleeping_job(occurrence["id"]),
            )
            held[key] = (occurrence, job)

        self.compose("restart", "controller")
        self.eventually(
            "composite intent survives restart", lambda: self.window(window["id"])
        )
        assert self.window(window["id"])["match_count"] == 2
        assert len(self.window(window["id"])["selection_summary"]) == 3
        self.acknowledge(
            self.current_incident(incidents["consumer"]["id"]), "until_incident_ends"
        )
        self.end_window(window)
        self.end_window(window, code=409)
        self.more_measurements("consumer")
        assert self.occurrence(incidents["consumer"]["id"])["gates"] == [
            "acknowledgement"
        ]
        assert self.occurrence(incidents["http"]["id"])["gates"] == ["maintenance"]
        for key in ("http", "consumer"):
            assert self.occurrence(incidents[key]["id"])["attempt_count"] == 0
            assert not self.receipts(incidents[key]["id"])

        self.end_window(overlap)
        self.acknowledge(self.current_incident(incidents["consumer"]["id"]), "end")
        for key in ("http", "consumer"):
            self.eventually(
                f"original {key} notification releases",
                lambda key=key: self.receipts(incidents[key]["id"]),
            )
            delivered = self.occurrence(incidents[key]["id"])
            before, job = held[key]
            assert delivered["id"] == before["id"]
            assert delivered["payload"] == before["payload"]
            assert delivered["attempt_count"] == 1
            assert self.job(delivered["id"])["id"] == job["id"]
            assert self.job(delivered["id"])["max_attempts"] == job["max_attempts"]

        disk = self.assignment("filesystem")
        self.request(
            f"/api/v1/assignments/{self.assignment('filesystem')['id']}",
            {"revision": disk["revision"], "params": original_disk["params"]},
            method="PUT",
        )
        self.mode(ready=True, backlog=2, processing_enabled=True)
        for key in ("http", "consumer"):
            self.eventually(
                f"new {key} measurement recovers",
                lambda key=key: self.incident(key) is None,
            )
        self.eventually(
            "original disk configuration is measured",
            lambda: self.assignment("filesystem")["current"]["health"] == "OK",
        )
        return {
            "window": window["id"],
            "selectors": 3,
            "distinct_results": 2,
            "incidents": {key: item["id"] for key, item in incidents.items()},
            "original_jobs_preserved": True,
        }

    def future_activation_restart_and_expiry(self) -> dict:
        start = utc_now() + timedelta(seconds=35)
        scheduled = self.save_window(
            self.seed_window(
                "http",
                name="Future deployment window",
                start_mode="scheduled",
                starts_local=local_utc(start),
                ends_local=local_utc(start + timedelta(minutes=5)),
            )
        )
        self.mode(ready=False)
        before = self.eventually(
            "failure before the future window", lambda: self.incident("http")
        )
        early = self.eventually(
            "future maintenance does not suppress early delivery",
            lambda: self.receipts(before["id"]),
        )
        assert datetime.fromisoformat(early[0]["received_at"]) < datetime.fromisoformat(
            scheduled["starts_at"]
        )
        self.mode(ready=True)
        self.eventually(
            "pre-window failure recovers", lambda: self.incident("http") is None
        )
        self.compose("stop", "controller")
        # The runner continues independently while the controller crosses the start.
        while utc_now() < start + timedelta(seconds=1):
            time.sleep(0.5)
        self.mode(ready=False)
        self.compose("start", "controller")
        incident = self.eventually(
            "controller returns during scheduled maintenance",
            lambda: self.incident("http"),
        )
        self.more_measurements("http")
        held = self.occurrence(incident["id"])
        assert held["gates"] == ["maintenance"]
        assert held["attempt_count"] == 0 and not self.receipts(incident["id"])
        job_id = self.job(held["id"])["id"]
        assert self.window(scheduled["id"])["starts_at"] == scheduled["starts_at"]

        expiry = utc_now() + timedelta(seconds=12)
        changed = self.save_window(
            self.window(scheduled["id"])["proposal"] | {"ends_local": local_utc(expiry)}
        )
        self.eventually(
            "same durable notification releases at shortened expiry",
            lambda: self.receipts(incident["id"]),
            timeout=30,
        )
        delivered = self.occurrence(incident["id"])
        assert delivered["id"] == held["id"] and delivered["payload"] == held["payload"]
        assert delivered["attempt_count"] == 1
        assert self.job(held["id"])["id"] == job_id
        receipt = self.receipts(incident["id"])[0]
        assert datetime.fromisoformat(receipt["received_at"]) >= datetime.fromisoformat(
            changed["ends_at"]
        )
        self.mode(ready=True)
        self.eventually(
            "scheduled episode recovers", lambda: self.incident("http") is None
        )
        return {
            "window": scheduled["id"],
            "pre_window_incident": before["id"],
            "held_incident": incident["id"],
            "job": job_id,
            "exact_expiry": changed["ends_at"],
        }

    def independent_overlaps_and_acknowledgement(self) -> dict:
        first = self.save_window(self.seed_window("http", name="Ninety-day window"))
        second = self.save_window(
            self.seed_window("http", name="Independent overlapping window")
        )
        self.mode(ready=False)
        incident = self.eventually(
            "failure under independent windows", lambda: self.incident("http")
        )
        self.more_measurements("http")
        held = self.occurrence(incident["id"])
        assert held["gates"] == ["maintenance"] and held["attempt_count"] == 0
        self.eventually(
            "long windows actually park the original job",
            lambda: self.sleeping_job(held["id"]),
        )
        self.end_window(first)
        self.end_window(first, code=409)
        self.more_measurements("http")
        assert self.occurrence(incident["id"])["attempt_count"] == 0
        assert self.occurrence(incident["id"])["gates"] == ["maintenance"]
        assert not self.receipts(incident["id"])
        self.maintenance("http", 7200)
        self.acknowledge(self.current_incident(incident["id"]), "until_incident_ends")
        self.end_window(second)
        self.more_measurements("http")
        assert self.occurrence(incident["id"])["gates"] == [
            "acknowledgement",
            "maintenance",
        ]
        self.maintenance("http", 0)
        self.more_measurements("http")
        assert self.occurrence(incident["id"])["gates"] == ["acknowledgement"]
        assert not self.receipts(incident["id"])
        self.acknowledge(self.current_incident(incident["id"]), "end")
        self.eventually(
            "last independent hold releases original work",
            lambda: self.receipts(incident["id"]),
            timeout=20,
        )
        delivered = self.occurrence(incident["id"])
        assert delivered["id"] == held["id"] and delivered["attempt_count"] == 1
        self.mode(ready=True)
        self.eventually(
            "overlap episode recovers", lambda: self.incident("http") is None
        )
        return {
            "windows": [first["id"], second["id"]],
            "incident": incident["id"],
            "independent_gates_preserved": True,
        }

    def retries_recovery_and_cancelled_future(self) -> dict:
        future = self.save_window(
            self.seed_window(
                "http",
                name="Cancelled future work",
                start_mode="scheduled",
                starts_local=local_utc(utc_now() + timedelta(seconds=20)),
            )
        )
        self.end_window(future)
        self.mode(ready=False, webhook="reject")
        incident = self.eventually(
            "real rejection episode", lambda: self.incident("http")
        )
        self.eventually(
            "actual HTTP attempt rejected",
            lambda: self.occurrence(incident["id"])["attempt_count"] >= 1,
        )
        active = self.save_window(self.seed_window("http", name="Hold existing retry"))
        self.eventually(
            "in-flight rejection finishes",
            lambda: self.occurrence(incident["id"])["status"] == "retrying",
        )
        held = self.occurrence(incident["id"])
        job_before = self.job(held["id"])
        self.compose("restart", "controller")
        self.eventually(
            "controller returns with the held retry",
            lambda: self.current_incident(incident["id"]),
        )
        self.more_measurements("http")
        assert self.occurrence(incident["id"])["attempt_count"] == held["attempt_count"]
        self.mode(webhook="ok")
        while utc_now() <= datetime.fromisoformat(future["starts_at"]):
            time.sleep(0.5)
        self.end_window(active)
        self.eventually(
            "existing failed work resumes",
            lambda: self.receipts(incident["id"]),
            timeout=20,
        )
        delivered = self.occurrence(incident["id"])
        assert delivered["payload"] == held["payload"]
        assert delivered["attempt_count"] == held["attempt_count"] + 1
        assert self.job(held["id"])["id"] == job_before["id"]
        assert self.job(held["id"])["max_attempts"] == job_before["max_attempts"]
        recovery_window = self.save_window(
            self.seed_window("http", name="Recovery stays eligible")
        )
        self.mode(ready=True)
        self.eventually(
            "measured recovery during maintenance",
            lambda: self.incident("http") is None,
        )
        self.eventually(
            "real recovery notification remains eligible",
            lambda: any(
                r["payload"]["kind"] == "resolved"
                for r in self.receipts(incident["id"])
            ),
        )
        self.mode(ready=False)
        suppressed = self.eventually(
            "new fully held episode", lambda: self.incident("http")
        )
        self.more_measurements("http")
        assert self.occurrence(suppressed["id"])["attempt_count"] == 0
        self.mode(ready=True)
        self.eventually(
            "fully held episode recovers", lambda: self.incident("http") is None
        )
        self.end_window(recovery_window)
        self.more_measurements("http")
        assert not self.receipts(suppressed["id"])
        assert self.occurrence(suppressed["id"])["status"] == "superseded"
        return {
            "retry_incident": incident["id"],
            "same_job": job_before["id"],
            "obsolete_incident": suppressed["id"],
            "future_cancelled": future["id"],
        }

    def run(self) -> None:
        success = False
        try:
            for label, scenario in [
                ("packaged startup and three fresh checks", self.clean_start),
                (
                    "one composite window preserves uncovered results, overlaps and acknowledgement across restart",
                    self.composite_window_preserves_independent_holds,
                ),
                (
                    "finite weekly windows preserve exact UTC, active holds and original retry budgets",
                    self.recurring_windows_preserve_real_delivery,
                ),
                (
                    "future activation across restart and exact shortened expiry",
                    self.future_activation_restart_and_expiry,
                ),
                (
                    "long overlapping windows preserve other maintenance and acknowledgement",
                    self.independent_overlaps_and_acknowledgement,
                ),
                (
                    "cancelled schedules, existing retries and truthful recovery",
                    self.retries_recovery_and_cancelled_future,
                ),
            ]:
                self.run_step(label, scenario)
            self.save_maintenance_evidence()
            success = True
        finally:
            self.finish(success)
            print(f"Evidence: {self.output}", flush=True)


class MovingMaintenanceAcceptance(MaintenanceClient, DurableRulesAcceptance):
    def logical_target_survives_replacement(self) -> dict:
        first = self.stream(TARGET)
        target_window = self.save_window(
            self.selection_window(
                self.seed_window(first["assignment_id"], scope="target"),
                self.seed_window(first["assignment_id"], scope="check"),
                name="Orders volume and original observer maintenance",
            )
        )
        check_window = self.save_window(
            self.seed_window(
                first["assignment_id"], scope="check", name="Only original observer"
            )
        )
        self.compose(
            "run",
            "--rm",
            "--no-deps",
            "rules-files",
            "python",
            "-c",
            "from pathlib import Path; Path('/volume/orders.queue').write_text('120\\n')",
        )
        row = self.eventually(
            "real volume is failing under maintenance",
            lambda: self.measured(DEFAULTS, "CRIT"),
        )
        incident = self.open_incident(row)
        self.eventually(
            "a second real measurement under maintenance",
            lambda: (
                self.stream(TARGET)["current"].get("observation_id")
                != row["current"].get("observation_id")
            ),
        )
        assert not any(
            r["payload"].get("incident_id") == incident["id"] for r in self.records()
        )
        self.set_membership("a", False)
        self.eventually("target intentionally absent", self.empty_coverage)
        assert self.window(target_window["id"])["match_count"] == 0
        self.compose("restart", "controller")
        self.eventually(
            "maintenance persists with no current matches",
            lambda: self.window(target_window["id"]),
        )
        self.set_membership("b", True)
        replacement = self.eventually(
            "replacement observer measures real failing volume",
            lambda: self.measured(DEFAULTS, "CRIT"),
        )
        assert replacement["runner_id"] != first["runner_id"]
        assert replacement["id"] != first["id"]
        new_incident = self.open_incident(replacement)
        assert new_incident["id"] != incident["id"]
        self.eventually(
            "replacement measures again while held",
            lambda: (
                self.stream(TARGET)["current"].get("observation_id")
                != replacement["current"].get("observation_id")
            ),
        )
        detail = self.detail(replacement)
        firing = next(
            o
            for o in detail["occurrences"]
            if o["incident_id"] == new_incident["id"] and o["kind"] == "firing"
        )
        assert firing["gates"] == ["maintenance"] and firing["attempt_count"] == 0
        assert self.window(check_window["id"])["match_count"] == 0
        summary = self.window(target_window["id"])["selection_summary"]
        assert (
            next(item for item in summary if item["scope"] == "check")[
                "matched_results"
            ]
            == 0
        )
        assert (
            next(item for item in summary if item["scope"] == "target")[
                "matched_results"
            ]
            == 1
        )
        self.end_window(target_window)
        self.eventually(
            "replacement notification releases despite old check-only window",
            lambda: any(
                r["payload"].get("incident_id") == new_incident["id"]
                for r in self.records()
            ),
        )
        self.compose(
            "run",
            "--rm",
            "--no-deps",
            "rules-files",
            "python",
            "-c",
            "from pathlib import Path; Path('/volume/orders.queue').write_text('12\\n')",
        )
        self.eventually(
            "replacement measures real recovery", lambda: self.measured(DEFAULTS, "OK")
        )
        self.end_window(check_window)
        return {
            "target_window": target_window["id"],
            "old_stream": first["id"],
            "new_stream": replacement["id"],
            "old_incident": incident["id"],
            "new_incident": new_incident["id"],
            "observers": [NODE_A, NODE_B],
        }

    def run(self) -> None:
        success = False
        try:
            self.run_step(
                "identical installed consumers measure a real declared volume",
                self.clean_start,
            )
            self.run_step(
                "target-scoped maintenance survives absence, restart and observer replacement",
                self.logical_target_survives_replacement,
            )
            self.save_maintenance_evidence()
            success = True
        finally:
            self.finish(success)
            print(f"Evidence: {self.output}", flush=True)


if __name__ == "__main__":
    MaintenanceAcceptance().run()
    MovingMaintenanceAcceptance().run()
