#!/usr/bin/env python3
# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Local controllable probe target and durable webhook recorder, never an external relay."""

from __future__ import annotations

import json
import os
import re
import socket
import sqlite3
import time
import urllib.error
import urllib.parse
import urllib.request
from contextlib import closing
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from uuid import UUID

STATE_PATH = Path(os.environ.get("FIXTURE_STATE_DIR", "/state")) / "fixture.sqlite3"
GROUPED_SAMPLE_DEFAULTS = {
    "used_percent": 40,
    "writes_blocked": False,
    "available": True,
    "sample_age_seconds": 0,
}
GROUPED_SAMPLE_KEY = re.compile(
    r"[A-Za-z0-9][A-Za-z0-9_.:/@-]{0,127}/(?:volume|elasticsearch)"
)
DEFAULT_MODE = {
    "ready": True,
    "secondary_ready": True,
    "backlog": 2,
    "processing_enabled": True,
    "webhook": "ok",
    "data_mode": "ok",
    "ingest_reply": "ok",
    "offline_installations": [],
    "ingest_reply_installation": None,
    "grouped_samples": {
        "node-a/volume": dict(GROUPED_SAMPLE_DEFAULTS),
        "service-a/elasticsearch": dict(GROUPED_SAMPLE_DEFAULTS),
        "service-b/elasticsearch": dict(GROUPED_SAMPLE_DEFAULTS),
        "node-b/volume": dict(GROUPED_SAMPLE_DEFAULTS),
        "coverage-service-a-staging/elasticsearch": dict(GROUPED_SAMPLE_DEFAULTS),
        "coverage-service-a-production/elasticsearch": dict(GROUPED_SAMPLE_DEFAULTS),
        "coverage-service-b-staging/elasticsearch": dict(GROUPED_SAMPLE_DEFAULTS),
        "coverage-service-b-production/elasticsearch": dict(GROUPED_SAMPLE_DEFAULTS),
    },
}
MAX_BODY = 262144
MAX_INVENTORY_BODY = 4 * 1024 * 1024


def database() -> sqlite3.Connection:
    connection = sqlite3.connect(STATE_PATH, timeout=10)
    connection.row_factory = sqlite3.Row
    return connection


def initialize() -> None:
    STATE_PATH.parent.mkdir(parents=True, exist_ok=True)
    with closing(database()) as db, db:
        db.execute("PRAGMA journal_mode=WAL")
        db.execute(
            "CREATE TABLE IF NOT EXISTS settings (id INTEGER PRIMARY KEY, mode TEXT NOT NULL)"
        )
        db.execute(
            "INSERT OR IGNORE INTO settings VALUES (1, ?)", (json.dumps(DEFAULT_MODE),)
        )
        db.execute(
            "CREATE TABLE IF NOT EXISTS receipts "
            "(id INTEGER PRIMARY KEY, received_at TEXT NOT NULL, payload TEXT NOT NULL, behavior TEXT NOT NULL)"
        )
        db.execute(
            "CREATE TABLE IF NOT EXISTS transport_events "
            "(id INTEGER PRIMARY KEY, request TEXT NOT NULL, response TEXT NOT NULL, dropped INTEGER NOT NULL)"
        )


def mode() -> dict[str, Any]:
    with closing(database()) as db, db:
        return read_mode(db)


def read_mode(db: sqlite3.Connection) -> dict[str, Any]:
    persisted = json.loads(
        db.execute("SELECT mode FROM settings WHERE id=1").fetchone()[0]
    )
    current = DEFAULT_MODE | persisted
    current["grouped_samples"] = DEFAULT_MODE["grouped_samples"] | persisted.get(
        "grouped_samples", {}
    )
    return current


def update_mode(changes: dict[str, Any]) -> dict[str, Any]:
    """Serialize operator mode edits with the one-shot transport fault reset."""
    if set(changes) - set(DEFAULT_MODE):
        raise ValueError("unknown mode field")
    with closing(database()) as db, db:
        db.execute("BEGIN IMMEDIATE")
        previous = read_mode(db)
        current = previous | changes
        if "grouped_samples" in changes:
            current["grouped_samples"] = patch_grouped_samples(
                previous["grouped_samples"], changes["grouped_samples"]
            )
        if not isinstance(current["ready"], bool):
            raise ValueError("ready must be boolean")
        if not isinstance(current["secondary_ready"], bool):
            raise ValueError("secondary_ready must be boolean")
        if type(current["backlog"]) is not int or not 0 <= current["backlog"] <= 10000:
            raise ValueError("backlog must be an integer in 0..10000")
        if type(current["processing_enabled"]) is not bool:
            raise ValueError("processing_enabled must be boolean")
        if current["webhook"] not in {"ok", "reject", "drop", "slow"}:
            raise ValueError("invalid webhook mode")
        if current["data_mode"] not in {"ok", "slow", "crash", "oversize"}:
            raise ValueError("invalid data mode")
        if current["ingest_reply"] not in {"ok", "drop_once"}:
            raise ValueError("invalid ingestion reply mode")
        offline = current["offline_installations"]
        if not isinstance(offline, list) or len(offline) > 16:
            raise ValueError("offline_installations must contain at most 16 UUIDs")
        selected = current["ingest_reply_installation"]
        for installation in offline + ([] if selected is None else [selected]):
            if (
                not isinstance(installation, str)
                or str(UUID(installation)) != installation
            ):
                raise ValueError("installation filters must be canonical UUIDs")
        db.execute("UPDATE settings SET mode=? WHERE id=1", (json.dumps(current),))
    return current


def patch_grouped_samples(
    existing: dict[str, dict[str, Any]], changes: Any
) -> dict[str, dict[str, Any]]:
    """Patch one observer atomically without resetting any peer's fixture values."""
    if not isinstance(changes, dict) or len(changes) > 32:
        raise ValueError("grouped_samples requires at most 32 sample patches")
    merged = dict(existing)
    for identity, patch in changes.items():
        if not isinstance(identity, str) or not GROUPED_SAMPLE_KEY.fullmatch(identity):
            raise ValueError("grouped sample keys require a stable observer and kind")
        if not isinstance(patch, dict) or set(patch) - set(GROUPED_SAMPLE_DEFAULTS):
            raise ValueError("unknown grouped sample field")
        sample = GROUPED_SAMPLE_DEFAULTS | merged.get(identity, {}) | patch
        for field, maximum in (("used_percent", 100), ("sample_age_seconds", 86400)):
            value = sample[field]
            if type(value) not in (int, float) or not 0 <= value <= maximum:
                raise ValueError(
                    f"grouped {field} must be a finite number in 0..{maximum}"
                )
        if (
            type(sample["writes_blocked"]) is not bool
            or type(sample["available"]) is not bool
        ):
            raise ValueError("grouped available and writes_blocked must be booleans")
        merged[identity] = sample
    if len(merged) > 32:
        raise ValueError("grouped_samples supports at most 32 independent samples")
    return merged


def grouped_sample(path: str, at: datetime | None = None) -> dict[str, Any] | None:
    """Return original fixture age as evidence time; never delay the server thread."""
    identity = urllib.parse.unquote(path.removeprefix("/grouped/"))
    if not GROUPED_SAMPLE_KEY.fullmatch(identity):
        return None
    sample = mode()["grouped_samples"].get(identity)
    if sample is None:
        return None
    measured_at = (at or datetime.now(timezone.utc)) - timedelta(
        seconds=sample["sample_age_seconds"]
    )
    return {
        "used_percent": sample["used_percent"],
        "writes_blocked": sample["writes_blocked"],
        "available": sample["available"],
        "source_at": measured_at.isoformat(timespec="microseconds").replace(
            "+00:00", "Z"
        ),
    }


class Handler(BaseHTTPRequestHandler):
    server_version = "MondekLocalFixture/1"

    def log_message(self, format: str, *args: object) -> None:
        # Do not log request bodies or user check output.
        pass

    def respond(self, status: int, body: object) -> None:
        payload = json.dumps(body, allow_nan=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        try:
            self.wfile.write(payload)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def read_body(self) -> Any:
        size = int(self.headers.get("Content-Length", "0"))
        limit = MAX_INVENTORY_BODY if self.path == "/api/v1/inventory" else MAX_BODY
        if size < 0 or size > limit:
            raise ValueError(f"request exceeds {limit} bytes")
        return json.loads(self.rfile.read(size))

    def do_GET(self) -> None:
        if self.path == "/health":
            self.respond(200, {"status": "ok"})
        elif self.path == "/mode":
            self.respond(200, mode())
        elif self.path.startswith("/grouped/"):
            sample = grouped_sample(self.path)
            self.respond(200, sample) if sample is not None else self.respond(
                404, {"error": "unknown grouped sample"}
            )
        elif self.path == "/ready":
            ready = mode()["ready"]
            self.respond(200 if ready else 503, {"ready": ready})
        elif self.path == "/ready-secondary":
            ready = mode()["secondary_ready"]
            self.respond(200 if ready else 503, {"ready": ready})
        elif self.path == "/metrics":
            current = mode()
            payload = (
                "# HELP mondek_fixture_service_ready Readiness of a local demonstration service.\n"
                "# TYPE mondek_fixture_service_ready gauge\n"
                f'mondek_fixture_service_ready{{service="primary"}} {int(current["ready"])}\n'
                f'mondek_fixture_service_ready{{service="secondary"}} {int(current["secondary_ready"])}\n'
                "# HELP mondek_fixture_queue_depth Items waiting in the local demonstration queue.\n"
                "# TYPE mondek_fixture_queue_depth gauge\n"
                f'mondek_fixture_queue_depth{{service="primary"}} {current["backlog"]}\n'
            ).encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            try:
                self.wfile.write(payload)
            except (BrokenPipeError, ConnectionResetError):
                pass
        elif self.path == "/data":
            current = mode()
            data = {
                "backlog": current["backlog"],
                "processing_enabled": current["processing_enabled"],
            }
            if current["data_mode"] == "slow":
                data["delay_seconds"] = 8
            elif current["data_mode"] == "crash":
                data["crash"] = True
            elif current["data_mode"] == "oversize":
                data["output_bytes"] = 300000
            self.respond(200, data)
        elif self.path == "/records":
            with closing(database()) as db, db:
                rows = db.execute(
                    "SELECT * FROM receipts ORDER BY id DESC LIMIT 500"
                ).fetchall()
                count = db.execute("SELECT count(*) FROM receipts").fetchone()[0]
            self.respond(
                200,
                {
                    "count": count,
                    "records": [
                        dict(row) | {"payload": json.loads(row["payload"])}
                        for row in rows
                    ],
                },
            )
        elif self.path == "/transport-records":
            with closing(database()) as db, db:
                rows = db.execute(
                    "SELECT * FROM transport_events ORDER BY id DESC LIMIT 100"
                ).fetchall()
            self.respond(
                200,
                {
                    "records": [
                        dict(row)
                        | {
                            "request": json.loads(row["request"]),
                            "response": json.loads(row["response"]),
                        }
                        for row in rows
                    ]
                },
            )
        else:
            self.respond(404, {"error": "unknown fixture path"})

    def do_POST(self) -> None:
        try:
            body = self.read_body()
            if not isinstance(body, dict):
                raise ValueError("body must be an object")
            if self.path == "/mode":
                self.respond(200, update_mode(body))
            elif self.path in {
                "/api/v1/control",
                "/api/v1/observations",
                "/api/v1/inventory",
            }:
                self.proxy(body)
            elif self.path == "/webhook":
                behavior = mode()["webhook"]
                if behavior == "reject":
                    self.respond(503, {"error": "intentional local receiver outage"})
                    return
                with closing(database()) as db, db:
                    db.execute(
                        "INSERT INTO receipts(received_at,payload,behavior) VALUES (?,?,?)",
                        (
                            datetime.now(timezone.utc).isoformat(),
                            json.dumps(body),
                            behavior,
                        ),
                    )
                    # The fixture bounds retained receipt bodies; IDs preserve visible progress.
                    db.execute(
                        "DELETE FROM receipts WHERE id <= (SELECT max(id)-2000 FROM receipts)"
                    )
                if behavior == "drop":
                    self.connection.shutdown(socket.SHUT_RDWR)
                    self.connection.close()
                    return
                if behavior == "slow":
                    time.sleep(8)
                self.respond(202, {"accepted": True})
            else:
                self.respond(404, {"error": "unknown fixture path"})
        except (ValueError, TypeError, json.JSONDecodeError) as exc:
            self.respond(400, {"error": str(exc)})

    def proxy(self, body: dict[str, Any]) -> None:
        """Local transport fault injection: drop only after real controller commit."""
        if body.get("installation_id") in mode()["offline_installations"]:
            self.respond(503, {"error": "local installation transport is offline"})
            return
        request = urllib.request.Request(
            "http://controller:4000" + self.path,
            json.dumps(body).encode(),
            {"Content-Type": "application/json"},
        )
        response_limit = (
            MAX_INVENTORY_BODY if self.path == "/api/v1/control" else MAX_BODY
        )
        try:
            with urllib.request.urlopen(request, timeout=15) as response:
                raw = response.read(response_limit + 1)
                if len(raw) > response_limit:
                    self.respond(
                        502, {"error": "controller response exceeds proxy cap"}
                    )
                    return
                status, result = response.status, json.loads(raw)
        except urllib.error.HTTPError as error:
            self.respond(error.code, json.loads(error.read(MAX_BODY + 1)))
            return
        except (OSError, urllib.error.URLError):
            self.respond(502, {"error": "local controller unavailable"})
            return
        drop = False
        if self.path == "/api/v1/observations":
            with closing(database()) as db, db:
                db.execute("BEGIN IMMEDIATE")
                current = read_mode(db)
                drop = current["ingest_reply"] == "drop_once" and (
                    current["ingest_reply_installation"] is None
                    or current["ingest_reply_installation"]
                    == body.get("installation_id")
                )
                if drop:
                    current["ingest_reply"] = "ok"
                    db.execute(
                        "UPDATE settings SET mode=? WHERE id=1", (json.dumps(current),)
                    )
                db.execute(
                    "INSERT INTO transport_events(request,response,dropped) VALUES (?,?,?)",
                    (json.dumps(body), json.dumps(result), int(drop)),
                )
                db.execute(
                    "DELETE FROM transport_events WHERE id <= (SELECT max(id)-100 FROM transport_events)"
                )
        if drop:
            self.connection.shutdown(socket.SHUT_RDWR)
            self.connection.close()
        else:
            self.respond(status, result)


if __name__ == "__main__":
    initialize()
    server = ThreadingHTTPServer(("0.0.0.0", 8080), Handler)
    server.daemon_threads = True
    server.serve_forever()
