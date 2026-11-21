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
import signal
import sys
import threading
import time
from collections.abc import Callable
from pathlib import Path
from typing import Any

from . import environment
from ._text import diagnostic_text
from .api import (
    MAX_DETAILS_BYTES,
    Result,
    evaluate,
    timestamp,
    validate_details,
    validate_invocation_scope,
    validate_source_at,
    validate_summary,
)
from .authoring import validate_params
from .bundle import load_snapshot, verify_snapshot
from .config import validate
from .consumer_state import CheckContext, _StateClient
from .consumer_state_cache import StateCache
from .worker_evidence import EvidenceWriter, encode_record
from .worker_limits import PREPARATION_TIMEOUT_SECONDS, WATCHDOG_GRACE_SECONDS


def emit(value: dict[str, Any]) -> None:
    sys.__stdout__.buffer.write(encode_record(value))
    sys.__stdout__.buffer.flush()


async def run(
    assignment: dict[str, Any],
    prepare: bool = False,
    *,
    preloaded: Callable[[str, str], tuple[Any, dict[str, Any]]] | None = None,
    execution: dict[str, Any] | None = None,
) -> None:
    seen: set[str] = set()
    evidence = EvidenceWriter(emit, MAX_DETAILS_BYTES)
    try:
        context = None
        if not prepare and preloaded is None:
            raw_context = os.environ.pop("MONDEK_EXECUTION_CONTEXT", None)
            execution = json.loads(raw_context) if raw_context else None
        if not prepare and execution is not None:
            cache_path = execution.get("state_cache")
            context = CheckContext(
                _StateClient(
                    execution["url"],
                    execution["identity"],
                    deadline=execution["deadline"],
                    cache=StateCache(Path(cache_path)) if cache_path else None,
                )
            )
        assignment = validate(assignment)
        with contextlib.redirect_stdout(sys.stderr):
            if preloaded is None:
                app, inventory = load_snapshot(
                    Path(environment.require("MONDEK_BUNDLE_DIR")),
                    assignment["source_revision"],
                    check_key=assignment["source_key"],
                )
            else:
                app, inventory = preloaded(
                    assignment["source_revision"], assignment["source_key"]
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
            kwargs = app.arguments(
                entry["key"], params, instantiate=not prepare, context=context
            )
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
                validate_source_at(result.source_at, timestamp())
                validate_details(result.details)
                serialized = result.to_dict()
                validate_invocation_scope(serialized)
                evidence.result(serialized)
                seen.add(result.key)
    except Exception as error:
        complete = False
        diagnostic = diagnostic_text(f"{type(error).__name__}: {error}")
    else:
        complete = seen == set(assignment["expected_keys"])
        diagnostic = None if complete else "missing expected output"

    if prepare:
        emit({"complete": False, "diagnostic": diagnostic})
    else:
        evidence.finish(complete, diagnostic)


def acquire_execution_lock(path: str | None):
    if path is None:
        return None
    lock = open(path, "a+")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        lock.close()
        emit(
            {
                "complete": False,
                "diagnostic": "previous worker still owns execution slot",
            }
        )
        raise
    return lock


def main() -> None:
    parser = argparse.ArgumentParser()
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--prepare", action="store_true")
    mode.add_argument("--verify-snapshot", action="store_true")
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
    try:
        lock = acquire_execution_lock(args.lock)
    except BlockingIOError:
        return
    if args.parent_pid:
        deadline = time.monotonic() + (
            (
                PREPARATION_TIMEOUT_SECONDS
                if args.prepare or args.verify_snapshot
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
        if args.verify_snapshot:
            try:
                verify_snapshot(
                    Path(environment.require("MONDEK_BUNDLE_DIR")),
                    assignment["source_revision"],
                )
                emit({"prepared": True})
            except Exception as error:
                emit({"prepared": False, "diagnostic": diagnostic_text(str(error))})
        else:
            asyncio.run(run(assignment, args.prepare))
    finally:
        if lock:
            lock.close()


if __name__ == "__main__":
    main()
