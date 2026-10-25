# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""One isolated check execution. Stdout is a bounded JSON-lines protocol."""

from __future__ import annotations

import argparse
import asyncio
import contextlib
import fcntl
import json
import math
import os
import re
import signal
import sys
import threading
import time
from datetime import datetime
from pathlib import Path
from typing import Any

from . import environment
from ._text import diagnostic_text
from .api import (
    Result,
    evaluate,
    timestamp,
    validate_details,
    validate_invocation_scope,
    validate_summary,
)
from .authoring import validate_params
from .bundle import load_snapshot
from .config import validate
from .worker_limits import PREPARATION_TIMEOUT_SECONDS, WATCHDOG_GRACE_SECONDS


def emit(value: dict[str, Any]) -> None:
    sys.__stdout__.write(json.dumps(value, allow_nan=False) + "\n")
    sys.__stdout__.flush()


def validate_source_at(source_at: str | None) -> None:
    """Reject unusable source evidence before it can invalidate the whole report."""
    if source_at is None:
        return
    if not isinstance(source_at, str) or not re.fullmatch(
        r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}(?:Z|\+00:00)", source_at
    ):
        raise ValueError("source_at must be a UTC timestamp with six fractional digits")
    source = datetime.fromisoformat(source_at)
    if source.year < 2000 or source > datetime.fromisoformat(timestamp()):
        raise ValueError("source_at must be between year 2000 and collection time")


async def run(assignment: dict[str, Any], prepare: bool = False) -> None:
    seen: set[str] = set()
    try:
        assignment = validate(assignment)
        with contextlib.redirect_stdout(sys.stderr):
            app, inventory = load_snapshot(
                Path(environment.require("MONDEK_BUNDLE_DIR")),
                assignment["source_revision"],
                check_key=assignment["source_key"],
            )
            entry = next(
                (
                    item
                    for item in inventory["checks"]
                    if item["key"] == assignment["source_key"]
                ),
                None,
            )
            if (
                entry is None
                or inventory["source_id"] != assignment["source_id"]
                or entry["definition_revision"] != assignment["definition_revision"]
            ):
                raise ValueError("check differs from the prepared consumer revision")
            if [output["key"] for output in entry["outputs"]] != assignment[
                "expected_keys"
            ]:
                raise ValueError("check registration differs from expected membership")
            for field in (
                "outputs",
                "parameter_schema",
                "params_owner",
                "parameter_contract",
            ):
                if field in assignment and assignment[field] != entry.get(field):
                    raise ValueError(f"{field} differs from the prepared consumer")
            params = validate_params(
                assignment["params"], entry["parameter_schema"], entry["params"]
            )
            if entry["params_owner"] == "source" and params != entry["params"]:
                raise ValueError("parameters are owned by the consumer source")
            function = app.bindings[entry["key"]].function
            kwargs = app.arguments(entry["key"], params, instantiate=not prepare)
        if prepare:
            emit({"prepared": True})
            return
        with contextlib.redirect_stdout(sys.stderr):
            async for result in evaluate(function, **kwargs):
                if not isinstance(result, Result):
                    raise ValueError("consumer must return Result values")
                if result.key not in assignment["expected_keys"] or result.key in seen:
                    raise ValueError("unexpected or duplicate result key")
                if result.health not in ("OK", "WARN", "CRIT", "UNKNOWN"):
                    raise ValueError("invalid measured health")
                validate_summary(result.summary)
                if result.value is not None and (
                    type(result.value) not in (int, float)
                    or not math.isfinite(result.value)
                ):
                    raise ValueError("result value must be finite number or null")
                validate_source_at(result.source_at)
                validate_details(result.details)
                serialized = result.to_dict()
                validate_invocation_scope(serialized)
                seen.add(result.key)
                emit({"result": serialized})
        complete = seen == set(assignment["expected_keys"])
        emit(
            {
                "complete": complete,
                "diagnostic": None if complete else "missing expected output",
            }
        )
    except Exception as error:
        emit(
            {
                "complete": False,
                "diagnostic": diagnostic_text(f"{type(error).__name__}: {error}"),
            }
        )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--prepare", action="store_true")
    parser.add_argument("--lock")
    parser.add_argument("--parent-pid", type=int)
    args = parser.parse_args()
    raw = sys.stdin.buffer.read(4 * 1024 * 1024 + 1)
    if len(raw) > 4 * 1024 * 1024:
        emit(
            {
                "complete": False,
                "diagnostic": "assignment exceeds 4 MiB worker input cap",
            }
        )
        return
    assignment = json.loads(raw)
    # The execution lock covers orphaned workers during a supervisor restart.
    # The watchdog bounds their life on macOS as well as Linux.
    lock = open(args.lock, "a+") if args.lock else None
    if lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            emit(
                {
                    "complete": False,
                    "diagnostic": "previous worker still owns execution slot",
                }
            )
            return
    if args.parent_pid:
        deadline = time.monotonic() + (
            (
                PREPARATION_TIMEOUT_SECONDS
                if args.prepare
                else assignment["timeout_seconds"]
            )
            + WATCHDOG_GRACE_SECONDS
        )

        def watchdog() -> None:
            while True:
                if os.getppid() != args.parent_pid or time.monotonic() > deadline:
                    os.killpg(os.getpgrp(), signal.SIGKILL)
                time.sleep(0.1)

        threading.Thread(target=watchdog, daemon=True).start()
    try:
        asyncio.run(run(assignment, args.prepare))
    finally:
        if lock:
            lock.close()


if __name__ == "__main__":
    main()
