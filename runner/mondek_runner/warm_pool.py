# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Runner-side ownership and capture for the optional Linux fork broker."""

from __future__ import annotations

import array
import asyncio
import contextlib
import json
import os
import signal
import socket
import struct
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, BinaryIO

from .bundle import MAX_INVENTORY
from .runtime import MAX_ASSIGNMENT, capture_worker
from .worker_limits import PREPARATION_TIMEOUT_SECONDS

MAX_BROKERS = 2
MAX_ACK = 1024
MAX_CONTEXT = 4096
MAX_BROKER_OUTPUT = 4096
RETRY_SECONDS = 15


@dataclass
class Broker:
    process: asyncio.subprocess.Process
    control: socket.socket
    logs: asyncio.Task[None] | None = None
    in_flight: int = 0
    healthy: bool = True
    failure_recorded: bool = False
    closing: bool = False
    stalled: bool = False

    def serving(self) -> bool:
        return not self.closing and self.healthy and self.process.returncode is None

    def ready(self) -> bool:
        return self.serving() and not self.stalled

    def kill_group(self) -> None:
        with contextlib.suppress(ProcessLookupError):
            os.killpg(self.process.pid, signal.SIGKILL)

    async def watch_logs(self) -> None:
        assert self.process.stdout is not None
        seen = 0
        while chunk := await self.process.stdout.read(MAX_BROKER_OUTPUT):
            seen += len(chunk)
            if seen > MAX_BROKER_OUTPUT:
                self.healthy = False
                self.kill_group()
                # Drain buffered output so the child watcher can close the pipe.
                while await self.process.stdout.read(MAX_BROKER_OUTPUT):
                    pass
                return

    async def close(self) -> None:
        self.closing = True
        self.control.close()
        try:
            async with asyncio.timeout(0.5):
                await self.process.wait()
                if self.logs:
                    await asyncio.shield(self.logs)
        except TimeoutError:
            self.kill_group()
            with contextlib.suppress(TimeoutError):
                async with asyncio.timeout(0.25):
                    await self.process.wait()
        finally:
            if self.logs:
                self.logs.cancel()
                await asyncio.gather(self.logs, return_exceptions=True)


def _has_opt_in_marker(directory: Path, revision: str) -> bool:
    if len(revision) != 64 or any(ch not in "0123456789abcdef" for ch in revision):
        return False
    try:
        with (directory / revision / "manifest.json").open("rb") as manifest:
            raw = manifest.read(MAX_INVENTORY + 1)
        if len(raw) > MAX_INVENTORY:
            return False
        data = json.loads(raw)
        # This is only a hint. The broker authenticates it before importing.
        return isinstance(data, dict) and data.get("warm_worker_safe") is True
    except (OSError, ValueError):
        return False


def _error(packet: bytes, fallback: str) -> ConnectionError:
    detail = packet[1:].decode("utf-8", "replace") if packet.startswith(b"E") else ""
    return ConnectionError(detail or fallback)


def _pipe(stack: contextlib.ExitStack) -> tuple[BinaryIO, BinaryIO]:
    read_fd, write_fd = os.pipe2(os.O_CLOEXEC)
    read = stack.enter_context(os.fdopen(read_fd, "rb", buffering=0))
    write = stack.enter_context(os.fdopen(write_fd, "wb", buffering=0))
    return read, write


async def _reader(
    stream: BinaryIO, stack: contextlib.ExitStack
) -> asyncio.StreamReader:
    reader = asyncio.StreamReader()
    transport, _ = await asyncio.get_running_loop().connect_read_pipe(
        lambda: asyncio.StreamReaderProtocol(reader), stream
    )
    stack.callback(transport.close)
    return reader


class WarmPool:
    """At most two verified revision brokers, with exec fallback before dispatch."""

    def __init__(self) -> None:
        self.supported = sys.platform == "linux" and hasattr(os, "pidfd_open")
        self.brokers: dict[str, Broker] = {}
        self.starting: dict[str, asyncio.Task[Broker | None]] = {}
        self.retry_at: dict[str, float] = {}
        self.diagnostic: str | None = None
        self.requests = 0
        self.registry = asyncio.Lock()

    def _failed(
        self, revision: str, broker: Broker, diagnostic: str, *, stalled: bool = False
    ) -> None:
        if stalled:
            broker.stalled = True
        else:
            broker.healthy = False
        if not broker.failure_recorded:
            broker.failure_recorded = True
            self.retry_at[revision] = time.monotonic() + RETRY_SECONDS
            self.diagnostic = diagnostic

    def _ready(self, revision: str) -> Broker | None:
        broker = self.brokers.get(revision)
        if broker and broker.closing:
            return None
        if broker and not broker.serving():
            self._failed(revision, broker, "warm broker exited")
        return broker if broker and broker.ready() else None

    def should_prepare(self, revision: str) -> bool:
        if not self.supported or self._ready(revision):
            return False
        if self.retry_at.get(revision, 0) > time.monotonic():
            return False
        if revision in self.starting:
            return True
        old = self.brokers.get(revision)
        if old:
            return not old.in_flight
        return len(self.brokers) + len(self.starting) < MAX_BROKERS

    def pid_for(self, revision: str) -> int | None:
        broker = self._ready(revision)
        return broker.process.pid if broker else None

    def references(self) -> set[str]:
        return self.brokers.keys() | self.starting.keys()

    def status(self) -> dict[str, Any]:
        return {
            "requested": "warm",
            "supported": self.supported,
            "ready_revisions": sum(broker.ready() for broker in self.brokers.values()),
            "in_flight": sum(broker.in_flight for broker in self.brokers.values()),
            "warm_requests": self.requests,
            "diagnostic": self.diagnostic,
        }

    async def _start(
        self, revision: str, directory: Path, deadline: float
    ) -> Broker | None:
        broker: Broker | None = None
        try:
            remaining = max(0.0, deadline - time.monotonic())
            async with asyncio.timeout(remaining):
                if not await asyncio.to_thread(_has_opt_in_marker, directory, revision):
                    self.retry_at[revision] = time.monotonic() + RETRY_SECONDS
                    self.diagnostic = "snapshot has no warm-worker opt-in"
                    return None
                driver, control = socket.socketpair(
                    socket.AF_UNIX, socket.SOCK_SEQPACKET
                )
                driver.setblocking(False)
                try:
                    with control:
                        process = await asyncio.create_subprocess_exec(
                            sys.executable,
                            "-m",
                            "mondek_runner.warm_broker",
                            "--fd",
                            str(control.fileno()),
                            "--runner-pid",
                            str(os.getpid()),
                            "--bundle-dir",
                            str(directory),
                            "--revision",
                            revision,
                            pass_fds=(control.fileno(),),
                            stdin=asyncio.subprocess.DEVNULL,
                            stdout=asyncio.subprocess.PIPE,
                            stderr=asyncio.subprocess.STDOUT,
                            start_new_session=True,
                            env={
                                key: value
                                for key, value in os.environ.items()
                                if key != "MONDEK_EXECUTION_CONTEXT"
                            },
                        )
                except BaseException:
                    driver.close()
                    raise
                broker = Broker(process, driver)
                broker.logs = asyncio.create_task(broker.watch_logs())
                ack = await asyncio.get_running_loop().sock_recv(driver, MAX_ACK)
                if ack != b"R" or not broker.ready():
                    raise _error(ack, "warm broker did not become ready")
                self.brokers[revision] = broker
                self.diagnostic = None
                return broker
        except (OSError, TimeoutError) as error:
            self.retry_at[revision] = time.monotonic() + RETRY_SECONDS
            self.diagnostic = (
                str(error)
                if isinstance(error, ConnectionError)
                else "warm broker startup failed"
            )
            return None
        finally:
            if broker and self.brokers.get(revision) is not broker:
                await broker.close()
            self.starting.pop(revision, None)

    async def prepare(
        self,
        assignment: dict[str, Any],
        *,
        bundle_dir: Path,
        timeout: float = PREPARATION_TIMEOUT_SECONDS,
    ) -> bool:
        if not self.supported or timeout <= 0:
            return False
        revision = assignment["source_revision"]
        deadline = time.monotonic() + min(timeout, PREPARATION_TIMEOUT_SECONDS)
        task = None
        async with self.registry:
            broker = self._ready(revision)
            if not broker and self.should_prepare(revision):
                task = self.starting.get(revision)
                if not task:
                    old = self.brokers.get(revision)
                    if old:
                        await old.close()
                        self.brokers.pop(revision, None)
                    task = asyncio.create_task(
                        self._start(revision, bundle_dir, deadline)
                    )
                    self.starting[revision] = task
        if task:
            try:
                broker = await asyncio.wait_for(
                    asyncio.shield(task), max(0.0, deadline - time.monotonic())
                )
            except TimeoutError:
                return False
        if not broker or deadline <= time.monotonic():
            return False
        outcome = await self._request(broker, assignment, deadline, prepare=True)
        return bool(outcome.get("prepared"))

    async def execute(
        self,
        assignment: dict[str, Any],
        *,
        bundle_dir: Path,
        lock_path: Path,
        execution_context: dict[str, Any] | None = None,
    ) -> dict[str, Any] | None:
        revision = assignment["source_revision"]
        broker = self._ready(revision)
        if not broker:
            return None
        deadline = time.monotonic() + assignment["timeout_seconds"]
        return await self._request(
            broker,
            assignment,
            deadline,
            lock_path=lock_path,
            execution_context=execution_context,
        )

    async def _request(
        self,
        broker: Broker,
        assignment: dict[str, Any],
        deadline: float,
        *,
        prepare: bool = False,
        lock_path: Path | None = None,
        execution_context: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        serialized = json.dumps(assignment, allow_nan=False).encode()
        context = json.dumps(
            {
                "prepare": prepare,
                "lock_path": str(lock_path) if lock_path else None,
                "execution_context": (
                    {**execution_context, "deadline": deadline}
                    if execution_context
                    else None
                ),
            },
            allow_nan=False,
        ).encode()
        if len(serialized) > MAX_ASSIGNMENT or len(context) > MAX_CONTEXT:
            raise ValueError(
                "warm worker input exceeds its bounded assignment or context limit"
            )

        broker.in_flight += 1
        try:
            return await self._capture(
                broker, assignment, serialized, context, deadline, prepare
            )
        finally:
            broker.in_flight -= 1

    async def _capture(
        self,
        broker: Broker,
        assignment: dict[str, Any],
        serialized: bytes,
        context: bytes,
        deadline: float,
        prepare: bool,
    ) -> dict[str, Any]:
        loop = asyncio.get_running_loop()
        acknowledged = False
        launch_sent = False
        launch_answered = False
        revision = assignment["source_revision"]
        with contextlib.ExitStack() as stack:
            feed, child_input = map(
                stack.enter_context,
                socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM),
            )
            status, child_status = map(
                stack.enter_context,
                socket.socketpair(socket.AF_UNIX, socket.SOCK_SEQPACKET),
            )
            feed.setblocking(False)
            status.setblocking(False)
            out, child_out = _pipe(stack)
            err, child_err = _pipe(stack)
            child_gate, gate = _pipe(stack)
            stdout, stderr = await _reader(out, stack), await _reader(err, stack)
            handed = (child_input, child_out, child_err, child_gate, child_status)

            async def start() -> None:
                nonlocal acknowledged, launch_sent, launch_answered
                packet = b"L" + struct.pack("!d", deadline)
                rights = array.array("i", [stream.fileno() for stream in handed])
                try:
                    if broker.control.sendmsg(
                        [packet], [(socket.SOL_SOCKET, socket.SCM_RIGHTS, rights)]
                    ) != len(packet):
                        raise ConnectionError("incomplete warm broker dispatch")
                    self.requests += 1
                    launch_sent = True
                except OSError as error:
                    self._failed(revision, broker, "warm broker launch failed")
                    raise ConnectionError("warm broker launch failed") from error
                finally:
                    for stream in handed:
                        stream.close()
                ack = await loop.sock_recv(status, MAX_ACK)
                launch_answered = True
                if ack == b"Eworker deadline elapsed":
                    raise TimeoutError
                if not ack.startswith(b"P") or len(ack) != 5:
                    error = _error(
                        ack, "warm broker failed before acknowledging launch"
                    )
                    self._failed(revision, broker, str(error))
                    raise error
                if struct.unpack("!i", ack[1:])[0] <= 1:
                    raise ConnectionError("invalid warm worker process group")
                acknowledged = True
                if deadline <= time.monotonic():
                    raise TimeoutError
                gate.write(b"G")
                try:
                    await loop.sock_sendall(
                        feed, struct.pack("!II", len(serialized), len(context))
                    )
                    await loop.sock_sendall(feed, serialized)
                    await loop.sock_sendall(feed, context)
                finally:
                    feed.close()

            async def wait() -> int:
                nonlocal acknowledged
                ack = await loop.sock_recv(status, MAX_ACK)
                if ack.startswith(b"X") and len(ack) == 5:
                    acknowledged = False
                    return struct.unpack("!i", ack[1:])[0]
                error = _error(ack, "warm broker lost while collecting")
                self._failed(revision, broker, str(error))
                raise error

            def terminate() -> None:
                gate.close()
                feed.close()
                if acknowledged:
                    with contextlib.suppress(OSError):
                        status.send(b"K")

            outcome = await capture_worker(
                assignment,
                stdout=stdout,
                stderr=stderr,
                start=start,
                wait=wait,
                terminate=terminate,
                timeout=max(0.0, deadline - time.monotonic()),
                checking=prepare,
                liveness=broker.serving,
            )

            if (
                launch_sent
                and not launch_answered
                and "timed out" in (outcome["diagnostic"] or "")
            ):
                self._failed(
                    revision, broker, "warm broker missed launch deadline", stalled=True
                )
            return outcome

    async def prune(self, retained: set[str]) -> None:
        async with self.registry:
            retiring = {
                revision: broker
                for revision, broker in self.brokers.items()
                if revision not in retained and not broker.in_flight
            }
            # Reserve all retirements before yielding. Keep their bundle references
            # until the owned processes have drained.
            for broker in retiring.values():
                broker.closing = True
            await asyncio.gather(*(broker.close() for broker in retiring.values()))
            for revision in retiring:
                self.brokers.pop(revision)
            for revision in self.retry_at.keys() - retained - self.references():
                del self.retry_at[revision]

    async def close(self) -> None:
        async with self.registry:
            starting = list(self.starting.values())
            for task in starting:
                task.cancel()
            await asyncio.gather(*starting, return_exceptions=True)
            self.starting.clear()
            await asyncio.gather(*(broker.close() for broker in self.brokers.values()))
            self.brokers.clear()
