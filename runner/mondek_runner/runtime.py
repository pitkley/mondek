# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Independent scheduling, worker supervision, configuration and evidence transport."""

from __future__ import annotations

import asyncio
import copy
import json
import math
import os
import shutil
import signal
import sys
import time
from pathlib import Path
from typing import Any

from . import environment
from ._text import DETAIL_OMISSION, diagnostic_text
from .api import (
    Impact,
    timestamp,
    validate_details,
    validate_impacts,
    validate_invocation_scope,
    validate_source_at,
    validate_summary,
)
from .authoring import label
from .bundle import snapshot
from .config import MAX_ASSIGNMENTS, assignment_id, validate
from .connection_diagnostics import ConnectionEvents
from .discovery import validate_discovery
from .state import State, inventory_summary
from .transport import post_json
from .worker_evidence import (
    MAX_CAPTURE_BYTES,
    MAX_COLLECTION_STDERR_BYTES,
    MAX_COLLECTION_STDOUT_BYTES,
)
from .worker_limits import PREPARATION_TIMEOUT_SECONDS

MAX_ASSIGNMENT = 4 * 1024 * 1024
DISCOVERY_RETRY_SECONDS = 60
SNAPSHOT_RETRY_SECONDS = 15


class OutputLimit(Exception):
    pass


def _validate_result_impacts(result: Any) -> None:
    """Validate worker claims without rewriting original evidence or impact order."""
    if not isinstance(result, dict):
        raise ValueError("worker result must be an object")
    validate_invocation_scope(result)
    if "impacts" not in result:
        return
    values = result["impacts"]
    if not isinstance(values, list) or len(values) > 16:
        raise ValueError("worker result impacts require a list of at most 16 entries")
    if any(
        not isinstance(item, dict) or set(item) != {"key", "label"} for item in values
    ):
        raise ValueError("worker result impacts require only key and label")
    validate_impacts(tuple(Impact(**item) for item in values))
    if result.get("health") == "OK" and values:
        raise ValueError("OK results cannot declare failure impacts")


async def execute(
    assignment: dict[str, Any],
    *,
    prepare: bool = False,
    verify_snapshot: bool = False,
    lock_path: Path | None = None,
    bundle_dir: Path | None = None,
    execution_context: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """One bounded process; timeout/capture failure preserves partial emitted facts."""
    encoded_assignment = json.dumps(assignment, allow_nan=False).encode()
    if len(encoded_assignment) > MAX_ASSIGNMENT:
        raise ValueError("assignment exceeds 4 MiB worker input cap")
    args = [sys.executable, "-m", "mondek_runner.worker"]
    if verify_snapshot:
        args.append("--verify-snapshot")
    elif prepare:
        args.append("--prepare")
    checking = prepare or verify_snapshot
    if lock_path:
        args.extend(["--lock", str(lock_path)])
    args.extend(["--parent-pid", str(os.getpid())])
    worker_env = {
        k: v for k, v in os.environ.items() if k != "MONDEK_EXECUTION_CONTEXT"
    }
    if bundle_dir:
        worker_env["MONDEK_BUNDLE_DIR"] = str(bundle_dir)
    if execution_context and not prepare:
        worker_env["MONDEK_EXECUTION_CONTEXT"] = json.dumps(
            {
                **execution_context,
                "deadline": time.monotonic() + assignment["timeout_seconds"],
            }
        )
    process = await asyncio.create_subprocess_exec(
        *args,
        stdin=asyncio.subprocess.PIPE,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
        start_new_session=True,
        env=worker_env,
    )
    output = bytearray()
    captured = 0
    stderr_bytes = 0
    diagnostic = None
    readers: list[asyncio.Task[None]] = []
    assert process.stdout is not None and process.stderr is not None

    async def read(stream: asyncio.StreamReader, *, stdout: bool) -> None:
        nonlocal captured, stderr_bytes
        while chunk := await stream.read(4096):
            if checking:
                remaining = MAX_CAPTURE_BYTES - captured
                captured += len(chunk)
            elif stdout:
                remaining = MAX_COLLECTION_STDOUT_BYTES - len(output)
            else:
                remaining = MAX_COLLECTION_STDERR_BYTES - stderr_bytes
                stderr_bytes += len(chunk)
            if stdout:
                output.extend(chunk[: max(0, remaining)])
            if len(chunk) > remaining:
                if not checking and not stdout:
                    raise OutputLimit("worker output exceeded 4 KiB stderr allowance")
                if checking:
                    raise OutputLimit("worker output exceeded 64 KiB capture budget")
                raise OutputLimit("worker output exceeded 60 KiB stdout allowance")

    async def communicate() -> None:
        assert process.stdin is not None
        process.stdin.write(encoded_assignment)
        await process.stdin.drain()
        process.stdin.close()
        readers.extend(
            [
                asyncio.create_task(read(process.stdout, stdout=True)),
                asyncio.create_task(read(process.stderr, stdout=False)),
            ]
        )
        await asyncio.gather(*readers, process.wait())

    async def drain(stream: asyncio.StreamReader, *, retain: bool) -> None:
        while chunk := await stream.read(4096):
            if retain:
                remaining = MAX_COLLECTION_STDOUT_BYTES - len(output)
                output.extend(chunk[: max(0, remaining)])

    try:
        await asyncio.wait_for(
            communicate(),
            timeout=PREPARATION_TIMEOUT_SECONDS
            if checking
            else assignment["timeout_seconds"],
        )
        if process.returncode != 0:
            detail = "no collection attempted" if checking else "collection incomplete"
            diagnostic = f"worker crashed (exit {process.returncode}); {detail}"
    except TimeoutError:
        diagnostic = (
            f"worker preparation timed out after {PREPARATION_TIMEOUT_SECONDS}s; "
            "source loading or validation incomplete; no collection attempted"
            if checking
            else "worker execution timed out; collection incomplete"
        )
    except OutputLimit as error:
        diagnostic = str(error)
    finally:
        # Kill the process group even after the leader exits: inherited pipes and
        # descendants must never outlive the bounded execution slot.
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        for reader in readers:
            reader.cancel()
        await asyncio.gather(*readers, return_exceptions=True)
        if diagnostic is not None or process.returncode is None:
            # The other pipe can report its overflow before already-flushed result
            # frames have reached the stdout reader. Keep bounded space for those.
            try:
                await asyncio.wait_for(
                    asyncio.gather(
                        drain(process.stdout, retain=not checking),
                        drain(process.stderr, retain=False),
                        process.wait(),
                    ),
                    timeout=0.25,
                )
            except TimeoutError:
                pass
        await process.wait()

    results: dict[str, dict[str, Any]] = {}
    terminal: dict[str, Any] = {}
    replacements: set[str] = set()
    expected = set() if checking else set(assignment["expected_keys"])
    try:
        lines = output.split(b"\n")
        for line in lines[:-1]:
            item = json.loads(line)
            if not isinstance(item, dict) or terminal:
                raise ValueError("invalid worker frame ordering")
            if item.keys() == {"result"} and not checking:
                result = item["result"]
                _validate_result_impacts(result)
                key = result.get("key")
                if not isinstance(key, str) or key not in expected or key in results:
                    raise ValueError("unexpected or duplicate worker result key")
                if not {"health", "value", "source_at"} <= result.keys():
                    raise ValueError(
                        "worker result is missing required evidence fields"
                    )
                if result["health"] not in ("OK", "WARN", "CRIT", "UNKNOWN"):
                    raise ValueError("invalid worker result health")
                value = result["value"]
                if value is not None and (
                    type(value) not in (int, float) or not math.isfinite(value)
                ):
                    raise ValueError("invalid worker result value")
                validate_source_at(result["source_at"], timestamp())
                validate_summary(result.get("summary"))
                validate_details(result.get("details"))
                if "discovery" in result:
                    validate_discovery(result["discovery"])
                results[key] = result
            elif item.keys() == {"detail"} and not checking:
                detail = item["detail"]
                if not isinstance(detail, dict) or set(detail) != {"key", "text"}:
                    raise ValueError("invalid worker detail frame")
                key = detail["key"]
                if (
                    not isinstance(key, str)
                    or key not in results
                    or results[key].get("details") != DETAIL_OMISSION
                    or key in replacements
                    or not isinstance(detail["text"], str)
                ):
                    raise ValueError("unexpected or duplicate worker detail")
                validate_details(detail["text"])
                results[key]["details"] = detail["text"]
                replacements.add(key)
            else:
                field = "prepared" if checking and "prepared" in item else "complete"
                if (
                    not item.keys() <= {field, "diagnostic"}
                    or type(item.get(field)) is not bool
                ):
                    raise ValueError("unknown worker frame")
                detail = item.get("diagnostic")
                if detail is not None and (not isinstance(detail, str) or item[field]):
                    raise ValueError("invalid worker terminal diagnostic")
                terminal = item
        if lines[-1]:
            raise ValueError("unterminated worker frame")
    except (ValueError, TypeError, OverflowError) as error:
        diagnostic = diagnostic or diagnostic_text(
            f"worker returned malformed output: {error}"
        )
    if terminal.get("diagnostic") is not None:
        terminal["diagnostic"] = diagnostic_text(str(terminal["diagnostic"]))
    if checking:
        return {
            "prepared": bool(terminal.get("prepared")) and diagnostic is None,
            "diagnostic": diagnostic or terminal.get("diagnostic"),
        }
    complete = (
        terminal.get("complete") is True
        and diagnostic is None
        and results.keys() == expected
    )
    return {
        "results": list(results.values()),
        "complete": complete,
        "diagnostic": diagnostic
        or terminal.get("diagnostic")
        or (None if complete else "worker ended without complete coverage"),
    }


class Runner:
    def __init__(
        self,
        state: State,
        controller_url: str,
        *,
        max_concurrency: int = 3,
        monotonic=time.monotonic,
        wall_clock=time.time,
        worker=execute,
        transport=post_json,
        consumer: str,
    ):
        self.state = state
        self.controller_url = controller_url.rstrip("/")
        self.max_concurrency = max(1, min(max_concurrency, 16))
        self.monotonic, self.wall_clock = monotonic, wall_clock
        self.worker, self.transport = worker, transport
        self.connection_events = ConnectionEvents(clock=monotonic)
        self.connection_diagnostics: dict[str, str] = {}
        self.active = state.assignments()
        self.blocked_revisions: dict[str, str] = {}
        self.desired: dict[str, dict[str, Any]] = {}
        self.prepared: dict[str, dict[str, Any]] = {}
        self.running: dict[str, asyncio.Task] = {}
        # Restart schedules one new run per assignment; no obsolete catch-up jobs.
        self.due = {id_: monotonic() for id_ in self.active}
        self.registered = asyncio.Event()
        self.control_authoritative = False
        self.preparation_needed = asyncio.Event()
        self.stopped = asyncio.Event()
        self.preparation_errors: dict[str, str] = {}
        self.consumer = consumer
        self.bundle_dir = state.directory / "bundles"
        self.inventory = state.inventory()
        self.inventory_ready = asyncio.Event()
        self.inventory_refresh_needed = asyncio.Event()
        self.inventory_refresh_needed.set()
        self.inventory_refresh_floor = 0
        self.inventory_refresh_revision = 0
        self.inventory_refresh_status: dict[str, Any] | None = None
        self.discovery = json.loads(state.get("discovery") or "{}")
        self.inventory_error: str | None = None
        self.inventory_publish_error: str | None = None
        self.inventory_retry_at = 0.0
        self.inventory_sent_session: tuple[str, int] | None = None
        self.running_revisions: dict[str, str] = {}

    def connection_failed(
        self, channel: str, error: Exception, diagnostic: str
    ) -> None:
        self.connection_diagnostics[channel] = diagnostic_text(diagnostic)
        self.connection_events.failed(channel, error)

    def connection_ready(self, channel: str) -> None:
        self.connection_events.succeeded(channel)
        diagnostic = self.connection_diagnostics.pop(channel, None)
        if diagnostic is not None:
            with self.state.db:
                self.state.db.execute(
                    "DELETE FROM metadata WHERE key='diagnostic' AND value=?",
                    (diagnostic,),
                )

    def status(self) -> dict[str, Any]:
        status = self.state.status(sorted(self.running))
        status["scheduler"] = self.scheduler_status()
        if self.inventory:
            status["inventory"] = inventory_summary(self.inventory)
        if self.inventory_refresh_status:
            status["inventory_refresh"] = dict(self.inventory_refresh_status)
        if self.preparation_errors:
            status["diagnostic"] = diagnostic_text(
                "; ".join(self.preparation_errors.values())
            )
        if self.inventory_error:
            status["diagnostic"] = diagnostic_text(self.inventory_error)
        elif self.inventory_publish_error:
            status["diagnostic"] = diagnostic_text(self.inventory_publish_error)
        blocked = [
            self.blocked_revisions[assignment["source_revision"]]
            for assignment in self.active.values()
            if assignment.get("source_revision") in self.blocked_revisions
        ]
        if blocked:
            diagnostic = status.get("diagnostic")
            message = (
                f"{len(blocked)} checks blocked by saved snapshot verification: "
                f"{blocked[0]}"
            )
            status["diagnostic"] = diagnostic_text(
                f"{message}. {diagnostic}" if diagnostic else message
            )
        return status

    def scheduler_status(self) -> dict[str, int | float]:
        """Last-reported local scheduling pressure, separate from source freshness."""
        now = self.monotonic()
        waiting = [
            self.due.get(id_, now)
            for id_, assignment in self.active.items()
            if assignment.get("source_revision") not in self.blocked_revisions
            and id_ not in self.running
            and self.due.get(id_, now) <= now
        ]
        return {
            "active_checks": len(self.active),
            "running_checks": len(self.running),
            "max_concurrency": self.max_concurrency,
            "due_waiting_checks": len(waiting),
            "oldest_due_seconds": round(now - min(waiting), 3) if waiting else 0.0,
            "preparation_pending_checks": sum(
                candidate != self.prepared.get(id_)
                for id_, candidate in self.desired.items()
            ),
            "prepared_waiting_checks": sum(
                candidate == self.desired.get(id_) and candidate != self.active.get(id_)
                for id_, candidate in self.prepared.items()
            ),
        }

    async def step(self) -> None:
        """One controllable scheduler tick; allocation always precedes worker launch."""
        # Oldest due work gets the next free slot, including under saturation.
        for id_ in sorted(self.active, key=lambda key: self.due.get(key, 0)):
            assignment = self.active[id_]
            if id_ in self.running or len(self.running) >= self.max_concurrency:
                continue
            if assignment.get("source_revision") in self.blocked_revisions:
                continue
            if self.due.get(id_, 0) > self.monotonic():
                continue
            frozen = copy.deepcopy(assignment)
            interval = frozen["interval_seconds"]
            self.due[id_] = self.monotonic() + interval
            report = self.state.allocate(
                frozen, self.wall_clock() + interval, timestamp()
            )
            task = asyncio.create_task(self.collect(frozen, report))
            self.running[id_] = task

    async def collect(self, assignment: dict, report: dict) -> None:
        id_ = assignment["id"]
        if assignment.get("source_revision"):
            self.running_revisions[id_] = assignment["source_revision"]
        try:
            options = (
                {
                    "bundle_dir": self.bundle_dir,
                    "execution_context": {
                        "url": self.controller_url,
                        "identity": {
                            "installation_id": self.state.installation_id,
                            "session_id": self.state.session_id,
                            "boot": self.state.boot,
                            "assignment_id": assignment["id"],
                            "generation": assignment["generation"],
                            "source_id": assignment["source_id"],
                        },
                    },
                }
                if assignment["kind"] == "python"
                else {}
            )
            outcome = await self.worker(
                assignment,
                lock_path=self.state.directory / f"{id_}.worker.lock",
                **options,
            )
            report.update(outcome, evaluated_at=timestamp())
            self.state.complete(report)
        except asyncio.CancelledError:
            # Durable allocation becomes explicit incomplete evidence on restart.
            raise
        except Exception as error:
            report.update(
                results=[],
                complete=False,
                evaluated_at=timestamp(),
                diagnostic=diagnostic_text(
                    f"runner execution error: {type(error).__name__}: {error}"
                ),
            )
            self.state.complete(report)
        finally:
            self.running.pop(id_, None)
            self.running_revisions.pop(id_, None)

    async def verify_saved_revisions(self) -> None:
        """Allow compatible saved work to resume independently of control."""
        while self.blocked_revisions and not self.stopped.is_set():
            for revision in list(self.blocked_revisions):
                if self.stopped.is_set():
                    return
                if not any(
                    assignment.get("source_revision") == revision
                    for assignment in self.active.values()
                ):
                    del self.blocked_revisions[revision]
                    continue
                try:
                    outcome = await self.worker(
                        {"source_revision": revision},
                        verify_snapshot=True,
                        bundle_dir=self.bundle_dir,
                    )
                    if not outcome["prepared"]:
                        raise ValueError(
                            outcome.get("diagnostic") or "verification failed"
                        )
                except Exception as error:
                    self.blocked_revisions[revision] = diagnostic_text(str(error), 512)
                else:
                    del self.blocked_revisions[revision]
                    self.preparation_needed.set()
            if self.blocked_revisions:
                await self.pause(SNAPSHOT_RETRY_SECONDS)
        await self.stopped.wait()

    async def scheduler(self) -> None:
        while not self.stopped.is_set():
            await self.step()
            await self.pause(0.05)

    def reconcile(self, response: dict[str, Any]) -> None:
        refresh = response.get("inventory_refresh", {})
        if (
            not isinstance(refresh, dict)
            or len(refresh) > MAX_ASSIGNMENTS
            or any(
                not isinstance(source, str)
                or not 1 <= len(source.encode("utf-8")) <= 200
                or not isinstance(request, dict)
                or set(request) != {"after_revision", "lifecycle_revision"}
                or type(request["after_revision"]) is not int
                or not 1 <= request["after_revision"] < 2**63 - 2
                or type(request["lifecycle_revision"]) is not int
                or not 1 <= request["lifecycle_revision"] <= 2**63 - 2
                for source, request in refresh.items()
            )
        ):
            raise ValueError("controller returned invalid inventory refresh request")
        assignments = response.get("assignments")
        authorized = response.get("authorized")
        authoritative = response.get("assignments_authoritative", False)
        if not isinstance(assignments, list) or len(assignments) > MAX_ASSIGNMENTS:
            raise ValueError("controller returned invalid assignment list")
        if type(authoritative) is not bool:
            raise ValueError("controller returned invalid assignment authority marker")
        if not isinstance(authorized, dict) or len(authorized) > MAX_ASSIGNMENTS:
            raise ValueError("controller returned invalid authorization map")
        desired = {}
        for assignment in assignments:
            if not isinstance(assignment, dict):
                raise ValueError("controller returned invalid assignment")
            id_ = assignment.get("id")
            if not assignment_id(id_) or id_ in desired:
                raise ValueError("controller returned unknown or duplicate assignment")
            # Validate the complete baseline before absence can retire any check.
            # Code readiness still runs separately, without blocking collection.
            desired[id_] = validate(assignment)
        if any(
            id_ not in desired
            or type(generation) is not int
            or not 1 <= generation <= 2_147_483_647
            for id_, generation in authorized.items()
        ):
            raise ValueError("controller returned invalid authorization map")
        active = {
            id_: assignment
            for id_, assignment in self.active.items()
            if not authoritative or id_ in desired
        }
        if len(set(active) | set(desired)) > MAX_ASSIGNMENTS:
            raise ValueError("controller assignment membership exceeds 512 checks")
        prepared = {}
        for id_, candidate in list(self.prepared.items()):
            if candidate != desired.get(id_):
                continue
            prepared[id_] = candidate
            if authorized.get(id_) == candidate["generation"]:
                active[id_] = copy.deepcopy(candidate)
        # A crash sees either the old or new membership, never half a retirement.
        # In-flight allocations are separate and can finish under their frozen IDs.
        if active != self.active:
            self.state.reconcile_assignments(active, self.wall_clock())
        self.due = {
            id_: self.due.get(id_, self.monotonic())
            if candidate == self.active.get(id_)
            else self.monotonic()
            for id_, candidate in active.items()
        }
        self.active, self.desired, self.prepared = active, desired, prepared
        self.control_authoritative = authoritative
        self.preparation_errors = {
            id_: error
            for id_, error in self.preparation_errors.items()
            if id_ in desired
        }
        self.preparation_needed.set()
        if self.inventory:
            request = refresh.get(self.inventory["source_id"])
            if request and (
                request["after_revision"] >= self.inventory["inventory_revision"]
                or request["lifecycle_revision"]
                != self.inventory.get("restoration_revision")
            ):
                floor = request["after_revision"]
                revision = request["lifecycle_revision"]
                if (floor, revision) != (
                    self.inventory_refresh_floor,
                    self.inventory_refresh_revision,
                ):
                    self.inventory_refresh_status = {
                        "after_revision": floor,
                        "lifecycle_revision": revision,
                        "state": "pending",
                        "attempted_at": None,
                    }
                    self.inventory_refresh_needed.set()
                self.inventory_refresh_floor = floor
                self.inventory_refresh_revision = revision
            else:
                self.inventory_refresh_floor = 0
                self.inventory_refresh_revision = 0
                self.inventory_refresh_status = None

    async def prepare(self) -> None:
        while not self.stopped.is_set():
            await self.preparation_needed.wait()
            self.preparation_needed.clear()
            for id_, assignment in list(self.desired.items()):
                if (
                    self.desired.get(id_) != assignment
                    or self.prepared.get(id_) == assignment
                    or assignment.get("source_revision") in self.blocked_revisions
                ):
                    continue
                try:
                    candidate = validate(assignment)
                    options = (
                        {"bundle_dir": self.bundle_dir}
                        if candidate["kind"] == "python"
                        else {}
                    )
                    outcome = await self.worker(candidate, prepare=True, **options)
                    if not outcome["prepared"]:
                        raise ValueError(
                            outcome.get("diagnostic") or "preparation failed"
                        )
                    if self.desired.get(id_) == candidate:
                        self.prepared[id_] = candidate
                        self.preparation_errors.pop(id_, None)
                except Exception as error:
                    if self.desired.get(id_) == assignment:
                        self.preparation_errors[id_] = diagnostic_text(
                            f"{id_} preparation failed: {error}", 512
                        )

    def control_wait_seconds(self) -> int:
        """Longer idle wait only after complete adoption and accepted publication."""
        if (
            not self.registered.is_set()
            or not self.control_authoritative
            or self.desired != self.active
            or self.prepared != self.desired
        ):
            return 2
        if (
            not self.inventory
            or self.refresh_pending()
            or self.inventory_refresh_needed.is_set()
            or self.inventory_sent_session
            != (self.state.session_id, self.inventory["inventory_revision"])
        ):
            return 2
        return 5

    async def control(self) -> None:
        await self.inventory_ready.wait()
        while not self.stopped.is_set():
            try:
                if self.inventory:
                    submitted = self.inventory
                    identity = (
                        self.state.session_id,
                        submitted["inventory_revision"],
                    )
                    if (
                        self.inventory_sent_session != identity
                        and self.monotonic() >= self.inventory_retry_at
                    ):
                        try:
                            reply = await asyncio.to_thread(
                                self.transport,
                                self.controller_url + "/api/v1/runner/inventory",
                                {
                                    "version": 1,
                                    "installation_id": self.state.installation_id,
                                    "session_id": self.state.session_id,
                                    "boot": self.state.boot,
                                    "complete": True,
                                    **submitted,
                                },
                                15,
                            )
                            if (
                                reply.get("inventory_revision")
                                != submitted["inventory_revision"]
                            ):
                                raise ValueError(
                                    "controller did not accept the inventory revision"
                                )
                            self.connection_ready("inventory")
                            self.inventory_sent_session = identity
                            self.inventory_publish_error = None
                        except Exception as error:
                            self.inventory_publish_error = diagnostic_text(
                                "inventory not accepted; "
                                "controller membership unchanged: "
                                f"{type(error).__name__}: {error}"
                            )
                            self.connection_failed(
                                "inventory", error, self.inventory_publish_error
                            )
                            self.inventory_retry_at = self.monotonic() + 5
                response = await asyncio.to_thread(
                    self.transport,
                    self.controller_url + "/api/v1/runner/control",
                    {
                        "version": 1,
                        "installation_id": self.state.installation_id,
                        "session_id": self.state.session_id,
                        "boot": self.state.boot,
                        "status": self.status(),
                        "prepared": {
                            id_: value["generation"]
                            for id_, value in self.prepared.items()
                        },
                        "active": {
                            id_: value["generation"]
                            for id_, value in self.active.items()
                        },
                        "wait_seconds": self.control_wait_seconds(),
                    },
                    8,
                )
                self.reconcile(response)
                self.registered.set()
                self.connection_ready("control")
            except Exception as error:
                self.registered.clear()
                diagnostic = f"control unavailable: {type(error).__name__}: {error}"
                self.state.diagnostic(diagnostic)
                self.connection_failed("control", error, diagnostic)
                await self.pause(1)
            else:
                await self.pause(0.2)

    async def discover(self) -> None:
        """Discover on deployment, restore, and an opted-in catalog interval."""
        first = True
        while first or not self.stopped.is_set():
            if not first:
                interval = self.discovery.get("interval") or (
                    DISCOVERY_RETRY_SECONDS if self.inventory_error else None
                )
                if interval is None:
                    await self.inventory_refresh_needed.wait()
                else:
                    try:
                        await asyncio.wait_for(
                            self.inventory_refresh_needed.wait(), interval
                        )
                    except TimeoutError:
                        pass
            first = False
            self.inventory_refresh_needed.clear()
            minimum_revision = self.inventory_refresh_floor + 1
            restoration_revision = self.inventory_refresh_revision or None
            progress = self.inventory_refresh_status
            if progress:
                progress.update(state="pending", attempted_at=timestamp())
            previous_error = self.inventory_error
            try:
                prepared = await snapshot(
                    self.consumer,
                    self.bundle_dir,
                    discovery_state=self.discovery.get("state", {}),
                    policy_params={
                        assignment["source_key"]: assignment["params"]
                        for assignment in self.active.values()
                        if assignment.get("source_key")
                    },
                    policy_versions={
                        assignment["source_key"]: {
                            "assignment_id": assignment["id"],
                            "generation": assignment["generation"],
                        }
                        for assignment in self.active.values()
                        if assignment.get("source_key")
                    },
                    include_discovery=True,
                )
                candidate = prepared["inventory"]
                if environment.get("MONDEK_RUNNER_LABEL"):
                    candidate["runner_label"] = label(
                        environment.require("MONDEK_RUNNER_LABEL")
                    )
                self.inventory = self.state.record_inventory(
                    candidate,
                    minimum_revision=minimum_revision,
                    restoration_revision=restoration_revision,
                    discovery=prepared["discovery"],
                )
                self.discovery = prepared["discovery"]
                self.inventory_error = (
                    diagnostic_text("; ".join(self.discovery["errors"]))
                    if self.discovery["errors"]
                    else None
                )
                if self.inventory_error:
                    self.state.diagnostic(self.inventory_error)
                elif previous_error:
                    with self.state.db:
                        self.state.db.execute(
                            "DELETE FROM metadata WHERE key='diagnostic' AND value=?",
                            (previous_error,),
                        )
                self.inventory_retry_at = 0.0
                if progress and self.inventory_refresh_status is progress:
                    progress["state"] = "publishing"
            except Exception as error:
                if progress and self.inventory_refresh_status is progress:
                    progress["state"] = "failed"
                self.inventory_error = diagnostic_text(
                    "consumer discovery failed; last successful snapshot retained: "
                    f"{type(error).__name__}: {error}"
                )
                self.state.diagnostic(self.inventory_error)
            finally:
                if self.bundle_dir.exists():
                    try:
                        self.prune_bundles()
                    except OSError as error:
                        self.inventory_error = diagnostic_text(
                            f"consumer bundle cleanup failed: {error}"
                        )
                self.inventory_ready.set()
            # Operator restoration retries promptly. Other failures retry at the
            # bounded catalog interval or the conservative first-discovery delay.
            if self.refresh_pending():
                await self.pause(5)
                if self.refresh_pending():
                    self.inventory_refresh_needed.set()

    def refresh_pending(self) -> bool:
        return bool(self.inventory_refresh_revision) and (
            not self.inventory
            or self.inventory["inventory_revision"] <= self.inventory_refresh_floor
            or self.inventory.get("restoration_revision")
            != self.inventory_refresh_revision
        )

    def prune_bundles(self) -> None:
        retained = {
            entry.get("source_revision")
            for entry in [
                *self.active.values(),
                *self.desired.values(),
                *self.prepared.values(),
            ]
        }
        retained.update(self.running_revisions.values())
        if self.inventory:
            retained.add(self.inventory["source_revision"])
        for path in self.bundle_dir.iterdir():
            if (
                path.is_dir()
                and path.name not in retained
                and not path.name.startswith(".")
            ):
                shutil.rmtree(path)

    async def upload(self) -> None:
        while not self.stopped.is_set():
            if not self.registered.is_set():
                await self.pause(0.2)
                continue
            reports = self.state.batch()
            if not reports:
                await self.pause(0.2)
                continue
            try:
                response = await asyncio.to_thread(
                    self.transport,
                    self.controller_url + "/api/v1/runner/observations",
                    {
                        "version": 1,
                        "installation_id": self.state.installation_id,
                        "session_id": self.state.session_id,
                        "reports": reports,
                    },
                    5,
                )
                dispositions = response["dispositions"]
                ids = {report["id"] for report in reports}
                acknowledged = []
                for item in dispositions:
                    if item["id"] not in ids:
                        raise ValueError("disposition identifies an unsent report")
                    if item["disposition"] in ("current", "historical", "duplicate"):
                        acknowledged.append(item["id"])
                    elif item["disposition"] in ("rejected", "conflict"):
                        # A terminal disposition is visible and cannot poison the queue.
                        acknowledged.append(item["id"])
                        self.state.diagnostic(
                            f"report {item['id']} {item['disposition']} by controller"
                        )
                    else:
                        raise ValueError("unknown report disposition")
                self.state.acknowledge(acknowledged)
                self.connection_ready("observations")
            except Exception as error:
                diagnostic = f"upload unavailable: {type(error).__name__}: {error}"
                self.state.diagnostic(diagnostic)
                self.connection_failed("observations", error, diagnostic)
                await self.pause(1)
            else:
                await self.pause(0.1)

    async def pause(self, seconds: float) -> None:
        try:
            await asyncio.wait_for(self.stopped.wait(), timeout=seconds)
        except TimeoutError:
            pass

    async def run(self) -> None:
        # Startup discovery already proposes the installed consumer immediately.
        # Verify saved revisions separately so neither discovery nor control can
        # delay compatible offline collection or release an incompatible revision.
        self.blocked_revisions = {
            assignment["source_revision"]: "verification pending"
            for assignment in self.active.values()
            if assignment["kind"] == "python"
        }
        tasks = [
            asyncio.create_task(loop())
            for loop in (
                self.scheduler,
                self.verify_saved_revisions,
                self.prepare,
                self.control,
                self.upload,
                self.discover,
            )
        ]
        shutdown = asyncio.create_task(self.stopped.wait())
        try:
            done, _ = await asyncio.wait(
                [*tasks, shutdown], return_when=asyncio.FIRST_COMPLETED
            )
            for task in done:
                if task is not shutdown:
                    # A broken journal/scheduler must fail visibly, never leave a
                    # heartbeat-only process pretending the execution loop runs.
                    task.result()
                    if not self.stopped.is_set():
                        raise RuntimeError("runner background loop exited unexpectedly")
        finally:
            self.stopped.set()
            pending = [*tasks, shutdown, *self.running.values()]
            for task in pending:
                task.cancel()
            await asyncio.gather(*pending, return_exceptions=True)
