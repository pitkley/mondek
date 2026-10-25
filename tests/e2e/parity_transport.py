# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Real isolated-node transport, durable retries and restart acceptance."""

from __future__ import annotations

import json
import uuid
from datetime import datetime, timezone
from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:
    from parity import ParityAcceptance


JOURNAL_SCRIPT = """
import json, sqlite3
from datetime import datetime, timezone
db = sqlite3.connect('file:/state/runner.sqlite3?mode=ro', uri=True)
db.execute('BEGIN')
metadata = dict(db.execute('SELECT key,value FROM metadata'))
rows = db.execute('SELECT payload,bytes FROM spool ORDER BY sequence').fetchall()
status = {key:metadata.get(key) for key in ('installation_id','session_id')}
status.update({key:int(metadata.get(key,0)) for key in ('boot','sequence','dropped')})
status.update(queue_count=len(rows),queue_bytes=sum(row[1] for row in rows))
print(json.dumps({'captured_at':datetime.now(timezone.utc).isoformat(),
                  'status':status,'reports':[json.loads(row[0]) for row in rows]}))
db.close()
"""


def exact_buffered_evidence(
    reports: list[dict[str, Any]], observations: list[dict[str, Any]]
) -> dict[str, int]:
    """Assert durable controller evidence equals the captured journal cohort."""
    assert reports, "No original offline runner evidence was captured"
    stored = {item["id"]: item for item in observations}
    assert len(stored) == len(observations), "Duplicate durable observation identities"
    for report in reports:
        item = stored[report["id"]]
        assert item["payload"] == report, "Reconnect rewrote original buffered evidence"
        received = datetime.fromisoformat(item["received_at"])
        # Ecto's utc_datetime column is PostgreSQL timestamp without time zone.
        # The direct SQL witness therefore returns an implicit UTC timestamp.
        if received.tzinfo is None:
            received = received.replace(tzinfo=timezone.utc)
        evaluated = datetime.fromisoformat(report["evaluated_at"])
        assert evaluated.tzinfo is not None, (
            "Original execution time lacks its UTC offset"
        )
        assert received > evaluated, (
            "Offline execution age was replaced by its arrival time"
        )
    return {
        "captured": len(reports),
        "historical": sum(item["disposition"] == "historical" for item in observations),
    }


class ParityTransportMixin:
    def node_journal(
        self: ParityAcceptance, service: str = "node-a-runner"
    ) -> dict[str, Any]:
        return json.loads(
            self.compose(
                "exec",
                "-T",
                service,
                "python",
                "-c",
                JOURNAL_SCRIPT,
                capture=True,
                timeout=10,
            )
        )

    def stored_reports(self: ParityAcceptance, ids: list[str]) -> list[dict[str, Any]]:
        # These IDs come from the owned runner journal. Canonical UUID conversion
        # makes the SQL literal list independent of arbitrary consumer text.
        literals = ",".join("'" + str(uuid.UUID(value)) + "'" for value in ids)
        query = (
            "SELECT COALESCE(json_agg(row_to_json(e)), '[]'::json) FROM "
            "(SELECT id,payload,received_at,disposition FROM observations "
            f"WHERE id IN ({literals}) ORDER BY id) e"
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

    def multi_runner_transport(self: ParityAcceptance) -> dict[str, Any]:
        target = "node:node-a/export"
        self.node_mode("node-a", export="missing")
        failed = self.eventually(
            "node A failure before transport outage", lambda: self.fresh(target, "CRIT")
        )
        incident = next(
            item
            for item in self.detail(failed)["incidents"]
            if item["status"] == "open"
        )
        self.eventually(
            "real local firing delivery before disconnect",
            lambda: any(
                row["payload"].get("incident_id") == incident["id"]
                and row["payload"].get("kind") == "firing"
                for row in self.records()
            ),
        )
        node_id = failed["runner_id"]
        identities = {
            row["target"]["key"]: row["id"]
            for row in self.streams(runner_id=node_id)["items"]
        }
        generation = failed["desired_generation"]
        baseline = self.node_journal()
        peers = {
            name: self.stream(name)["current"]["observation_id"]
            for name in ("node:node-b/export", "service:primary")
        }
        samples: list[dict[str, Any]] = [baseline]
        try:
            self.mode(offline_installations=[node_id])
            blocked_at = datetime.now(timezone.utc)
            print("  transport: only Node A is disconnected", flush=True)
            queued = self.eventually(
                "Node A keeps executing while its transport is blocked",
                lambda: (
                    sample
                    if (sample := self.node_journal())
                    and len(
                        [
                            report
                            for report in sample["reports"]
                            if datetime.fromisoformat(report["started_at"])
                            >= blocked_at
                        ]
                    )
                    >= 6
                    and sample["status"]["sequence"] > baseline["status"]["sequence"]
                    else False
                ),
            )
            samples.append(queued)
            original = [
                report
                for report in queued["reports"]
                if datetime.fromisoformat(report["started_at"]) >= blocked_at
            ]
            original_ids = [report["id"] for report in original]
            assert queued["status"]["dropped"] == baseline["status"]["dropped"]
            self.eventually(
                "Node A becomes stale while Node B and the dedicated runner advance",
                lambda: (
                    self.stream(target)["current"]["knowledge"] == "stale"
                    and all(
                        (row := self.fresh(name))
                        and row["current"]["observation_id"] != previous
                        for name, previous in peers.items()
                    )
                ),
            )
            stale = self.detail(failed)
            assert stale["stream"]["current"]["health"] == "CRIT"
            assert any(
                row["id"] == incident["id"] and row["status"] == "open"
                for row in stale["incidents"]
            )
            expected = self.overview()["coverage"]["expected_count"]

            self.compose("restart", "controller")
            self.eventually("controller restarted with durable state", self.overview)
            self.eventually(
                "unblocked runners resume while Node A stays disconnected",
                lambda: all(self.fresh(name) for name in peers),
            )
            assert self.overview()["coverage"]["expected_count"] == expected
            self.compose("restart", "node-a-runner")
            restarted = self.eventually(
                "restarted offline Node A executes under a new durable session",
                lambda: (
                    sample
                    if (sample := self.node_journal())["status"]["boot"]
                    > baseline["status"]["boot"]
                    and any(
                        report["session_id"] == sample["status"]["session_id"]
                        for report in sample["reports"]
                    )
                    else False
                ),
            )
            samples.append(restarted)
            assert restarted["status"]["installation_id"] == node_id
            assert restarted["status"]["session_id"] != baseline["status"]["session_id"]
            buffered = {report["id"]: report for report in restarted["reports"]}
            assert all(buffered[report["id"]] == report for report in original)
            assert restarted["status"]["dropped"] == baseline["status"]["dropped"]

            self.mode(offline_installations=[])
            print("  transport: reconnecting the original journal", flush=True)
            committed = self.eventually(
                "all sampled old-session evidence commits with original payloads",
                lambda: (
                    rows
                    if len(rows := self.stored_reports(original_ids))
                    == len(original_ids)
                    else False
                ),
                timeout=90,
            )
            buffered_proof = exact_buffered_evidence(original, committed)
            assert buffered_proof["historical"] == len(original)
            fresh = self.eventually(
                "new-session evidence restores current Node A visibility",
                lambda: (
                    row
                    if (row := self.fresh(target, "CRIT"))
                    and row["current"]["session_id"]
                    == restarted["status"]["session_id"]
                    else False
                ),
                timeout=90,
            )
            assert fresh["desired_generation"] == generation
            assert {
                row["target"]["key"]: row["id"]
                for row in self.streams(runner_id=node_id)["items"]
            } == identities
            detail = self.detail(fresh)
            assert any(
                row["id"] == incident["id"] and row["status"] == "open"
                for row in detail["incidents"]
            )
            assert sum(row["status"] == "open" for row in detail["incidents"]) == 1
            samples.append(self.node_journal())

            events = self.request("/transport-records", fixture=True)["records"]
            last_event = max((row["id"] for row in events), default=0)
            self.mode(ingest_reply="drop_once", ingest_reply_installation=node_id)
            dropped = self.eventually(
                "Node A ingestion reply is dropped only after real controller commit",
                lambda: next(
                    (
                        row
                        for row in self.request("/transport-records", fixture=True)[
                            "records"
                        ]
                        if row["id"] > last_event
                        and row["dropped"]
                        and row["request"]["installation_id"] == node_id
                    ),
                    None,
                ),
            )
            dropped_reports = dropped["request"]["reports"]
            dropped_ids = {row["id"] for row in dropped_reports}
            retried = self.eventually(
                "the runner automatically retries unchanged evidence and receives duplicates",
                lambda: next(
                    (
                        row
                        for row in self.request("/transport-records", fixture=True)[
                            "records"
                        ]
                        if row["id"] > dropped["id"]
                        and not row["dropped"]
                        and dropped_ids.issubset(
                            {
                                entry["id"]
                                for entry in row["response"]["dispositions"]
                                if entry["disposition"] == "duplicate"
                            }
                        )
                    ),
                    None,
                ),
            )
            retry_payloads = {row["id"]: row for row in retried["request"]["reports"]}
            assert all(retry_payloads[row["id"]] == row for row in dropped_reports)
            stored = self.stored_reports(sorted(dropped_ids))
            assert len(stored) == len(dropped_ids)
            assert {row["id"]: row["payload"] for row in stored} == {
                row["id"]: row for row in dropped_reports
            }
            assert len(self.detail(fresh)["incidents"]) == len(detail["incidents"])
            assert len(self.detail(fresh)["occurrences"]) == len(detail["occurrences"])

            self.node_mode("node-a", export="healthy")
            recovered = self.eventually(
                "fresh recovery closes the original pre-outage episode",
                lambda: self.fresh(target),
            )
            closed = next(
                row
                for row in self.detail(recovered)["incidents"]
                if row["id"] == incident["id"]
            )
            assert closed["status"] == "closed"
            assert closed["closure_reason"] == "measured_recovery"
            assert closed["closing_observation_id"]
            self.eventually(
                "local terminal delivery identifies the real closing measurement",
                lambda: any(
                    row["payload"].get("incident_id") == incident["id"]
                    and row["payload"].get("kind") == "resolved"
                    and row["payload"].get("observation_id")
                    == closed["closing_observation_id"]
                    for row in self.records()
                ),
            )
            (self.output / "transport-journal.json").write_text(
                json.dumps(samples, indent=2)
            )
            (self.output / "transport-retry.json").write_text(
                json.dumps({"dropped": dropped, "retry": retried}, indent=2)
            )
            return {
                "isolated_runner_id": node_id,
                "unaffected_targets_advanced": list(peers),
                "original_buffered_evidence": buffered_proof,
                "stream_ids_preserved": identities,
                "incident_id_preserved": incident["id"],
                "new_session_id": restarted["status"]["session_id"],
                "real_automatic_duplicate_report_ids": sorted(dropped_ids),
                "closing_observation_id": closed["closing_observation_id"],
            }
        finally:
            self.mode(
                offline_installations=[],
                ingest_reply="ok",
                ingest_reply_installation=None,
            )
            self.node_mode("node-a", export="healthy")
            (self.output / "transport-journal.json").write_text(
                json.dumps(samples, indent=2)
            )
