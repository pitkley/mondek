# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Bounded read cache shared by the disposable workers of one runner session."""

from __future__ import annotations

import contextlib
import hashlib
import json
import os
import sqlite3
import time
from collections.abc import Iterator
from pathlib import Path
from typing import Any

_MAX_ENTRIES = 48
_MAX_READ_ADDRESSES = 192
_MAX_AGE = 86_400
_LOCAL_TIMEOUT = 0.05


def prepare_cache(state_directory: Path, session: str, enabled: bool) -> Path | None:
    directory = state_directory / "consumer-state-cache"
    if not enabled and not directory.exists():
        return None
    directory.mkdir(mode=0o700, exist_ok=True)
    directory.chmod(0o700)
    for old in directory.glob("*.sqlite3*"):
        old.unlink()
    if not enabled:
        return None

    path = directory / f"{session}.sqlite3"
    os.close(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600))
    with contextlib.closing(sqlite3.connect(path)) as db:
        db.executescript(
            """
            CREATE TABLE control (epoch INTEGER NOT NULL, pending INTEGER NOT NULL);
            INSERT INTO control VALUES (0, 0);
            CREATE TABLE entries (
                identity TEXT PRIMARY KEY, address TEXT NOT NULL,
                observed REAL NOT NULL,
                usable_until REAL, version TEXT NOT NULL, payload TEXT NOT NULL
            );
            CREATE INDEX entries_address ON entries (address);
            CREATE TABLE reads (
                address TEXT PRIMARY KEY, settled REAL NOT NULL, version TEXT
            );
            """
        )
    return path


def cache_identity(
    url: str, identity: dict[str, Any], scope: str, key: str
) -> tuple[str, str]:
    assignment = identity["assignment_id"] if scope == "check" else None
    address = [url, identity["source_id"], assignment, key]
    return _digest([address, identity]), _digest(address)


def _digest(value: Any) -> str:
    return hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()


class StateCache:
    def __init__(self, path: Path):
        self.path = path
        self.disabled = path.with_suffix(".sqlite3.disabled")

    @contextlib.contextmanager
    def _transaction(self, deadline: float) -> Iterator[sqlite3.Connection]:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise sqlite3.OperationalError("state cache deadline exceeded")
        uri = self.path.resolve().as_uri() + "?mode=rw"
        with (
            contextlib.closing(
                sqlite3.connect(uri, uri=True, timeout=min(_LOCAL_TIMEOUT, remaining))
            ) as db,
            db,
        ):
            db.execute("PRAGMA max_page_count=2048")
            db.execute("BEGIN IMMEDIATE")
            yield db

    @staticmethod
    def _epoch(db: sqlite3.Connection) -> int | None:
        row = db.execute("SELECT epoch FROM control WHERE pending = 0").fetchone()
        return row[0] if row else None

    def snapshot(self, deadline: float) -> int | None:
        if self.disabled.exists():
            return None
        try:
            with self._transaction(deadline) as db:
                return self._epoch(db)
        except (OSError, sqlite3.Error):
            return None

    def begin_mutation(self, address: str, deadline: float) -> bool:
        if self.disabled.exists():
            return False
        try:
            with self._transaction(deadline) as db:
                db.execute(
                    "UPDATE control SET epoch = epoch + 1, pending = pending + 1"
                )
                db.execute("DELETE FROM entries WHERE address = ?", (address,))
        except (OSError, sqlite3.Error):
            # Each reader checks this even if it already captured an epoch.
            self.disabled.touch()
            return False
        return True

    def finish_mutation(self) -> None:
        try:
            with self._transaction(time.monotonic() + _LOCAL_TIMEOUT) as db:
                db.execute("UPDATE control SET pending = pending - 1")
        except (OSError, sqlite3.Error):
            # The durable marker stays set after a local failure or worker exit.
            pass

    def invalidate(self, address: str, deadline: float) -> None:
        if self.disabled.exists():
            return
        try:
            with self._transaction(deadline) as db:
                db.execute("UPDATE control SET epoch = epoch + 1")
                db.execute("DELETE FROM entries WHERE address = ?", (address,))
        except (OSError, sqlite3.Error):
            self.disabled.touch()

    def observe_entry(
        self,
        identity: str,
        address: str,
        version: str,
        epoch: int,
        observed: float,
        usable_until: float | None,
        payload: dict[str, Any] | None,
        deadline: float,
    ) -> None:
        if self.disabled.exists():
            return
        try:
            with self._transaction(deadline) as db:
                if self._epoch(db) != epoch:
                    db.execute("UPDATE control SET epoch = epoch + 1")
                    db.execute("DELETE FROM entries WHERE address = ?", (address,))
                    return
                previous = db.execute(
                    "SELECT settled, version FROM reads WHERE address = ?", (address,)
                ).fetchone()
                settled = time.monotonic()
                if (
                    previous is not None
                    and observed < previous[0]
                    and previous[1] != version
                ):
                    # Overlapping reads can reach the controller in either order.
                    db.execute("DELETE FROM entries WHERE address = ?", (address,))
                    db.execute(
                        "UPDATE reads SET settled = ?, version = NULL "
                        "WHERE address = ?",
                        (settled, address),
                    )
                    return
                db.execute(
                    "INSERT OR REPLACE INTO reads VALUES (?, ?, ?)",
                    (address, settled, version),
                )
                db.execute(
                    "DELETE FROM entries WHERE address = ? AND version != ?",
                    (address, version),
                )
                if payload is not None:
                    db.execute(
                        "INSERT OR REPLACE INTO entries VALUES (?, ?, ?, ?, ?, ?)",
                        (
                            identity,
                            address,
                            observed,
                            usable_until,
                            version,
                            json.dumps(payload, separators=(",", ":"), allow_nan=False),
                        ),
                    )
                    db.execute(
                        "DELETE FROM entries WHERE identity IN ("
                        "SELECT identity FROM entries ORDER BY observed DESC "
                        "LIMIT -1 OFFSET ?)",
                        (_MAX_ENTRIES,),
                    )
                pruned = db.execute(
                    "DELETE FROM reads WHERE address IN ("
                    "SELECT address FROM reads ORDER BY settled DESC "
                    "LIMIT -1 OFFSET ?)",
                    (_MAX_READ_ADDRESSES,),
                ).rowcount
                if pruned:
                    db.execute("UPDATE control SET epoch = epoch + 1")
        except (OSError, sqlite3.Error):
            self.disabled.touch()

    def load(
        self, identity: str, epoch: int, max_age: float, deadline: float
    ) -> tuple[dict[str, Any], float] | None:
        if self.disabled.exists():
            return None
        try:
            with self._transaction(deadline) as db:
                if self._epoch(db) != epoch:
                    return None
                row = db.execute(
                    "SELECT payload, observed, usable_until FROM entries "
                    "WHERE identity = ?",
                    (identity,),
                ).fetchone()
                now = time.monotonic()
                if row is None or now >= deadline or self.disabled.exists():
                    return None
                payload, observed, expiry = row
                age = now - observed
                if 0 <= age <= min(max_age, _MAX_AGE) and (
                    expiry is None or now < expiry
                ):
                    return json.loads(payload), age
        except (OSError, sqlite3.Error, ValueError):
            pass
        return None
