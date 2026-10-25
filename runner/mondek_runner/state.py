# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Small durable SQLite journal; bounded evidence, stable identity and run order."""

from __future__ import annotations

import fcntl
import json
import sqlite3
import uuid
from pathlib import Path
from typing import Any

from ._text import diagnostic_text
from .api import timestamp


def inventory_summary(inventory: dict[str, Any] | None) -> dict[str, Any] | None:
    """Public operational facts only; never include catalog or binding settings."""
    if inventory is None:
        return None
    return {
        "source_id": inventory["source_id"],
        "source_revision": inventory["source_revision"],
        "inventory_revision": inventory["inventory_revision"],
        "check_count": len(inventory["checks"]),
        "result_count": sum(len(check["outputs"]) for check in inventory["checks"]),
    }


class State:
    def __init__(
        self,
        directory: str | Path,
        *,
        max_reports: int = 1000,
        max_bytes: int = 2 * 1024 * 1024,
    ):
        if max_reports < 1 or max_bytes < 4096:
            raise ValueError("spool needs at least 1 report and 4096 bytes")
        self.directory = Path(directory)
        self.directory.mkdir(parents=True, exist_ok=True)
        self.lock = (self.directory / "runner.lock").open("a+")
        try:
            fcntl.flock(self.lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            self.lock.close()
            raise RuntimeError("another runner owns this state directory") from None
        self.db = sqlite3.connect(self.directory / "runner.sqlite3")
        self.db.row_factory = sqlite3.Row
        self.db.executescript(
            """
            PRAGMA journal_mode=WAL;
            PRAGMA synchronous=FULL;
            PRAGMA wal_autocheckpoint=128;
            PRAGMA journal_size_limit=1048576;
            CREATE TABLE IF NOT EXISTS metadata(key TEXT PRIMARY KEY, value TEXT);
            CREATE TABLE IF NOT EXISTS assignments(
              id TEXT PRIMARY KEY, payload TEXT NOT NULL, next_due REAL NOT NULL);
            CREATE TABLE IF NOT EXISTS inflight(
              assignment_id TEXT PRIMARY KEY, payload TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS spool(
              id TEXT PRIMARY KEY, sequence INTEGER UNIQUE NOT NULL,
              started_at TEXT NOT NULL, payload TEXT NOT NULL, bytes INTEGER NOT NULL);
            """
        )
        self.max_reports, self.max_bytes = max_reports, max_bytes
        with self.db:
            self.installation_id = self.get("installation_id") or str(uuid.uuid4())
            self.boot = int(self.get("boot") or 0) + 1
            self.session_id = str(uuid.uuid4())
            self.set("installation_id", self.installation_id)
            self.set("boot", str(self.boot))
            self.set("session_id", self.session_id)
            self.set("diagnostic", "runner restarted; missed intervals skipped")
            # A previously allocated run remains evidence of incomplete collection.
            interrupted = self.db.execute("SELECT payload FROM inflight").fetchall()
            for row in interrupted:
                report = json.loads(row["payload"])
                report.update(
                    evaluated_at=timestamp(),
                    results=[],
                    complete=False,
                    diagnostic="runner restart interrupted this execution",
                )
                self._enqueue(report)
            self.db.execute("DELETE FROM inflight")

    def close(self) -> None:
        self.db.close()
        self.lock.close()

    def get(self, key: str) -> str | None:
        row = self.db.execute(
            "SELECT value FROM metadata WHERE key=?", (key,)
        ).fetchone()
        return row["value"] if row else None

    def set(self, key: str, value: str) -> None:
        self.db.execute(
            "INSERT INTO metadata VALUES(?, ?) "
            "ON CONFLICT(key) DO UPDATE SET value=excluded.value",
            (key, value),
        )

    def diagnostic(self, message: str) -> None:
        with self.db:
            self.set("diagnostic", diagnostic_text(message))

    def assignments(self) -> dict[str, dict[str, Any]]:
        return {
            row["id"]: json.loads(row["payload"])
            for row in self.db.execute("SELECT id, payload FROM assignments")
        }

    def inventory(self) -> dict[str, Any] | None:
        value = self.get("inventory")
        return json.loads(value) if value else None

    def record_inventory(
        self,
        inventory: dict[str, Any],
        *,
        minimum_revision: int = 1,
        restoration_revision: int | None = None,
        discovery: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        """Persist a successful discovery once, including explicit restoration."""
        if type(minimum_revision) is not int or not 1 <= minimum_revision <= 2**63 - 2:
            raise ValueError("invalid minimum inventory revision")
        if restoration_revision is not None and (
            type(restoration_revision) is not int
            or not 1 <= restoration_revision <= 2**63 - 2
        ):
            raise ValueError("invalid restoration revision")
        old = self.inventory()
        if old and old["source_id"] != inventory["source_id"]:
            raise ValueError("source_id changed; use a separate runner state directory")
        previous = {
            key: value
            for key, value in (old or {}).items()
            if key not in ("inventory_revision", "restoration_revision")
        }
        if (
            previous == inventory
            and old["inventory_revision"] >= minimum_revision
            and (
                restoration_revision is None
                or old.get("restoration_revision") == restoration_revision
            )
        ):
            if discovery is not None:
                with self.db:
                    self.set("discovery", json.dumps(discovery, allow_nan=False))
            return old
        revision = max(int(self.get("inventory_revision") or 0) + 1, minimum_revision)
        if revision > 2**63 - 2:
            raise ValueError("inventory revision limit reached")
        result = {
            **inventory,
            "inventory_revision": revision,
        }
        marker = restoration_revision or (old or {}).get("restoration_revision")
        if marker is not None:
            result["restoration_revision"] = marker
        with self.db:
            self.set("inventory", json.dumps(result, allow_nan=False))
            self.set("inventory_revision", str(result["inventory_revision"]))
            if discovery is not None:
                self.set("discovery", json.dumps(discovery, allow_nan=False))
        return result

    def adopt(self, assignment: dict[str, Any], next_due: float) -> None:
        with self.db:
            self.db.execute(
                "INSERT INTO assignments VALUES(?, ?, ?) "
                "ON CONFLICT(id) DO UPDATE SET payload=excluded.payload, "
                "next_due=excluded.next_due",
                (assignment["id"], json.dumps(assignment), next_due),
            )

    def reconcile_assignments(
        self, assignments: dict[str, dict[str, Any]], next_due: float
    ) -> None:
        """Commit the accepted membership together; keep allocated evidence intact."""
        with self.db:
            for row in self.db.execute("SELECT id FROM assignments").fetchall():
                if row["id"] not in assignments:
                    self.db.execute("DELETE FROM assignments WHERE id=?", (row["id"],))
            for id_, assignment in assignments.items():
                self.db.execute(
                    "INSERT INTO assignments VALUES(?, ?, ?) "
                    "ON CONFLICT(id) DO UPDATE SET payload=excluded.payload, "
                    "next_due=excluded.next_due "
                    "WHERE assignments.payload != excluded.payload",
                    (id_, json.dumps(assignment), next_due),
                )

    def allocate(
        self, assignment: dict[str, Any], next_due: float, started_at: str
    ) -> dict[str, Any]:
        """Commit ID, monotonic sequence and schedule progress before any execution."""
        with self.db:
            sequence = int(self.get("sequence") or 0) + 1
            report = {
                "id": str(uuid.uuid4()),
                "assignment_id": assignment["id"],
                "installation_id": self.installation_id,
                "session_id": self.session_id,
                "generation": assignment["generation"],
                "sequence": sequence,
                "started_at": started_at,
            }
            self.db.execute(
                "INSERT INTO inflight VALUES(?, ?)",
                (assignment["id"], json.dumps(report)),
            )
            self.set("sequence", str(sequence))
            self.db.execute(
                "UPDATE assignments SET next_due=? WHERE id=?",
                (next_due, assignment["id"]),
            )
        return report

    def complete(self, report: dict[str, Any]) -> None:
        with self.db:
            self._enqueue(report)
            self.db.execute(
                "DELETE FROM inflight WHERE assignment_id=?", (report["assignment_id"],)
            )

    def _enqueue(self, report: dict[str, Any]) -> None:
        payload = json.dumps(report, separators=(",", ":"), allow_nan=False)
        size = len(payload.encode())
        # A single oversized item is explicitly lost rather than blocking all uploads.
        if size > self.max_bytes:
            self._loss(1)
            return
        self.db.execute(
            "INSERT INTO spool VALUES(?, ?, ?, ?, ?)",
            (report["id"], report["sequence"], report["started_at"], payload, size),
        )
        while True:
            row = self.db.execute(
                "SELECT COUNT(*) count, COALESCE(SUM(bytes),0) bytes FROM spool"
            ).fetchone()
            if row["count"] <= self.max_reports and row["bytes"] <= self.max_bytes:
                break
            self.db.execute(
                "DELETE FROM spool WHERE id="
                "(SELECT id FROM spool ORDER BY sequence LIMIT 1)"
            )
            self._loss(1)

    def _loss(self, count: int) -> None:
        self.set("dropped", str(int(self.get("dropped") or 0) + count))
        self.set("loss_at", timestamp())
        self.set(
            "diagnostic", "spool overflow; oldest evidence dropped; continuity unknown"
        )

    def batch(self, limit: int = 32, byte_limit: int = 240000) -> list[dict[str, Any]]:
        reports, size = [], 0
        for row in self.db.execute(
            "SELECT payload, bytes FROM spool ORDER BY sequence LIMIT ?",
            (min(limit, 32),),
        ):
            if size + row["bytes"] > byte_limit:
                break
            reports.append(json.loads(row["payload"]))
            size += row["bytes"]
        return reports

    def acknowledge(self, ids: list[str]) -> None:
        with self.db:
            self.db.executemany("DELETE FROM spool WHERE id=?", ((id_,) for id_ in ids))

    def status(self, running: list[str] | None = None) -> dict[str, Any]:
        row = self.db.execute(
            "SELECT COUNT(*) count, COALESCE(SUM(bytes),0) bytes, "
            "MIN(started_at) oldest FROM spool"
        ).fetchone()
        diagnostic = self.get("diagnostic")
        return {
            "queue_count": row["count"],
            "queue_bytes": row["bytes"],
            "oldest_at": row["oldest"],
            "dropped": int(self.get("dropped") or 0),
            "loss_at": self.get("loss_at"),
            "running": running or [],
            # Older installations may retain unsanitized generated diagnostics.
            # Normalize this display field without rewriting queued evidence.
            "diagnostic": diagnostic_text(diagnostic)
            if diagnostic is not None
            else None,
        }


def inspect(directory: str | Path) -> dict[str, Any]:
    """Read a running journal without acquiring ownership or advancing boot."""
    db = sqlite3.connect(f"file:{Path(directory) / 'runner.sqlite3'}?mode=ro", uri=True)
    db.row_factory = sqlite3.Row
    try:
        metadata = dict(
            db.execute(
                "SELECT key, value FROM metadata WHERE key IN "
                "('installation_id', 'session_id', 'boot', 'sequence', 'dropped', "
                "'loss_at', 'diagnostic')"
            )
        )
        if metadata.get("diagnostic") is not None:
            metadata["diagnostic"] = diagnostic_text(metadata["diagnostic"])
        stored_inventory = db.execute(
            "SELECT value FROM metadata WHERE key='inventory'"
        ).fetchone()
        inventory = json.loads(stored_inventory[0]) if stored_inventory else None
        spool = db.execute(
            "SELECT COUNT(*) queue_count, COALESCE(SUM(bytes),0) queue_bytes, "
            "MIN(started_at) oldest_at FROM spool"
        ).fetchone()
        return {
            **metadata,
            **dict(spool),
            **{
                key: int(metadata.get(key, 0))
                for key in ("boot", "sequence", "dropped")
            },
            "inventory": inventory_summary(inventory),
            "inflight": [
                row["assignment_id"]
                for row in db.execute(
                    "SELECT assignment_id FROM inflight ORDER BY assignment_id"
                )
            ],
            "active": {
                row["id"]: json.loads(row["payload"])["generation"]
                for row in db.execute("SELECT * FROM assignments")
            },
        }
    finally:
        db.close()
