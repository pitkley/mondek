# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Single-threaded Linux fork broker for one authenticated consumer snapshot."""

from __future__ import annotations

import argparse
import array
import asyncio
import contextlib
import ctypes
import json
import math
import os
import select
import selectors
import signal
import socket
import struct
import sys
import threading
import time
from pathlib import Path
from typing import Any

from .bundle import construct_verified_app, validate_loaded_app, verify_snapshot
from .worker import acquire_execution_lock, run

MAX_ASSIGNMENT = 4 * 1024 * 1024
MAX_CONTEXT = 4096
LAUNCH = struct.Struct("!cd")
STATUS = struct.Struct("!ci")
LENGTHS = struct.Struct("!II")
FD_COUNT = 5


class Refusal(Exception):
    """A fixed public diagnostic. Consumer exception messages stay private."""


def descriptors() -> dict[int, tuple[int, int, int]]:
    handles = {}
    for name in os.listdir("/proc/self/fd"):
        fd = int(name)
        try:
            stat = os.fstat(fd)
        except OSError:
            # The transient /proc directory descriptor closed after listdir.
            continue
        handles[fd] = (stat.st_dev, stat.st_ino, stat.st_mode)
    return handles


def fork_safe(expected: dict[int, tuple[int, int, int]], dynamic: set[int]) -> bool:
    current = descriptors()
    for fd in dynamic:
        current.pop(fd, None)
    return len(os.listdir("/proc/self/task")) == 1 and current == expected


def owned_children() -> set[int]:
    # Linux attributes a child to its creating thread. An unsafe import can
    # create the process on a native thread before the fork-safety check.
    children = set()
    for entry in Path("/proc/self/task").iterdir():
        try:
            children.update(
                int(pid) for pid in (entry / "children").read_text().split()
            )
        except FileNotFoundError:
            continue
    return children


def send(sock: socket.socket, packet: bytes) -> bool:
    try:
        return sock.send(packet, socket.MSG_DONTWAIT) == len(packet)
    except OSError:
        return False


def kill_group(pid: int) -> None:
    try:
        os.killpg(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass


def read_exact(fd: int, size: int) -> bytes:
    data = bytearray()
    while len(data) < size:
        chunk = os.read(fd, size - len(data))
        if not chunk:
            raise ValueError("short worker input")
        data.extend(chunk)
    return bytes(data)


def child(
    fds: list[int],
    runner_fd: int,
    broker_fd: int,
    deadline: float,
    app: Any,
    manifest: dict[str, Any],
    settings: dict[str, Any],
) -> int:
    os.setpgid(0, 0)
    signal.set_wakeup_fd(-1)
    signal.signal(signal.SIGCHLD, signal.SIG_DFL)
    input_fd, stdout_fd, stderr_fd, gate, _status_fd = fds
    os.dup2(stdout_fd, 1)
    os.dup2(stderr_fd, 2)
    keep = {0, 1, 2, input_fd, gate, runner_fd, broker_fd}
    for fd in descriptors():
        if fd not in keep:
            os.close(fd)

    def watchdog() -> None:
        poll = select.poll()
        poll.register(runner_fd, select.POLLIN)
        poll.register(broker_fd, select.POLLIN)
        poll.register(gate, select.POLLHUP)
        while time.monotonic() < deadline:
            remaining = deadline - time.monotonic()
            if poll.poll(min(250, max(0, math.ceil(remaining * 1000)))):
                break
        kill_group(os.getpid())

    threading.Thread(target=watchdog, daemon=True).start()
    if os.read(gate, 1) != b"G":
        return 1
    # Keep the gate open: the runner owns its write end for the full execution.
    assignment_len, context_len = LENGTHS.unpack(read_exact(input_fd, LENGTHS.size))
    if not (0 < assignment_len <= MAX_ASSIGNMENT and 0 < context_len <= MAX_CONTEXT):
        return 1
    assignment = json.loads(read_exact(input_fd, assignment_len))
    context = json.loads(read_exact(input_fd, context_len))
    if os.read(input_fd, 1) or time.monotonic() >= deadline:
        return 1
    os.close(input_fd)
    if not isinstance(context, dict) or set(context) != {
        "prepare",
        "lock_path",
        "execution_context",
    }:
        return 1
    prepare, lock_path, execution = (
        context["prepare"],
        context["lock_path"],
        context["execution_context"],
    )
    if (
        type(prepare) is not bool
        or (lock_path is not None and not isinstance(lock_path, str))
        or (execution is not None and not isinstance(execution, dict))
    ):
        return 1
    try:
        lock = acquire_execution_lock(lock_path)
    except BlockingIOError:
        return 0

    def load(revision: str, key: str):
        return validate_loaded_app(app, manifest, settings, revision, key)

    with lock if lock is not None else contextlib.nullcontext():
        asyncio.run(run(assignment, prepare, preloaded=load, execution=execution))
    return 0


def fork_request(
    fds: list[int],
    runner_fd: int,
    broker_fd: int,
    deadline: float,
    app: Any,
    manifest: dict[str, Any],
    settings: dict[str, Any],
) -> int:
    pid = os.fork()
    if pid == 0:
        try:
            code = child(fds, runner_fd, broker_fd, deadline, app, manifest, settings)
        except BaseException:
            code = 1
        os._exit(code)
    try:
        # Both sides establish the same group, removing the scheduling race.
        os.setpgid(pid, pid)
    except BaseException:
        with contextlib.suppress(ProcessLookupError):
            os.kill(pid, signal.SIGKILL)
        os.waitpid(pid, 0)
        raise
    return pid


def unwatch(selector: selectors.BaseSelector, status: socket.socket) -> None:
    # A cancelled request stops watching for commands, but keeps the status
    # socket to deliver X once the leader is reaped.
    with contextlib.suppress(KeyError):
        selector.unregister(status)


def reap(
    children: dict[int, socket.socket], selector: selectors.BaseSelector | None
) -> None:
    while True:
        try:
            info = os.waitid(os.P_ALL, 0, os.WEXITED | os.WNOHANG | os.WNOWAIT)
        except ChildProcessError:
            return
        if info is None:
            return
        pid = info.si_pid
        status = children.pop(pid, None)
        if status is not None:
            if selector is not None:
                unwatch(selector, status)
            # An unreaped leader pins the PGID until all descendants are signalled.
            kill_group(pid)
        _, raw = os.waitpid(pid, 0)
        if status is not None:
            with status:
                send(status, STATUS.pack(b"X", os.waitstatus_to_exitcode(raw)))


def launch(
    control: socket.socket,
    selector: selectors.BaseSelector,
    children: dict[int, socket.socket],
    expected: dict[int, tuple[int, int, int]],
    runner_fd: int,
    broker_fd: int,
    directory: Path,
    revision: str,
    app: Any,
    manifest: dict[str, Any],
    settings: dict[str, Any],
) -> None:
    descriptor_size = array.array("i").itemsize
    packet, ancillary, flags, _ = control.recvmsg(
        LAUNCH.size,
        socket.CMSG_SPACE(FD_COUNT * descriptor_size),
        socket.MSG_CMSG_CLOEXEC,
    )
    fds: list[int] = []
    try:
        for level, kind, data in ancillary:
            if (level, kind) == (socket.SOL_SOCKET, socket.SCM_RIGHTS):
                rights = array.array("i")
                rights.frombytes(data[: len(data) - len(data) % descriptor_size])
                fds.extend(rights)
        if not packet or flags & (socket.MSG_TRUNC | socket.MSG_CTRUNC):
            raise Refusal("broker control closed or truncated")
        if len(fds) != FD_COUNT or len(packet) != LAUNCH.size:
            raise Refusal("invalid broker launch")
        tag, deadline = LAUNCH.unpack(packet)
        if tag != b"L" or not math.isfinite(deadline):
            raise Refusal("invalid broker deadline")
        status = socket.socket(fileno=fds[-1])
        fds.pop()
        try:
            try:
                verified, _ = verify_snapshot(directory, revision)
                if verified != manifest:
                    raise ValueError("changed manifest")
            except Exception:
                raise Refusal("snapshot verification failed") from None
            if not fork_safe(
                expected,
                set(fds) | {status.fileno()} | {s.fileno() for s in children.values()},
            ):
                raise Refusal("consumer is not fork-safe")
            if time.monotonic() >= deadline:
                send(status, b"Eworker deadline elapsed")
                return
            pid = fork_request(
                [*fds, status.fileno()],
                runner_fd,
                broker_fd,
                deadline,
                app,
                manifest,
                settings,
            )
            children[pid] = status
            selector.register(status, selectors.EVENT_READ, pid)
            if not send(status, STATUS.pack(b"P", pid)):
                kill_group(pid)
        except Exception as error:
            message = (
                str(error) if isinstance(error, Refusal) else "worker launch failed"
            )
            send(status, b"E" + message.encode())
            raise
        finally:
            if status not in children.values():
                status.close()
    finally:
        for fd in fds:
            os.close(fd)


def serve(
    control: socket.socket, runner_pid: int, directory: Path, revision: str
) -> None:
    # Reap orphaned execution descendants as well as direct child leaders.
    if ctypes.CDLL(None).prctl(36, 1, 0, 0, 0) != 0:  # PR_SET_CHILD_SUBREAPER
        raise Refusal("broker startup failed")
    runner_fd = os.pidfd_open(runner_pid)
    broker_fd = os.pidfd_open(os.getpid())
    children: dict[int, socket.socket] = {}
    wake_read, wake_write = os.pipe2(os.O_NONBLOCK | os.O_CLOEXEC)
    signal.signal(signal.SIGCHLD, lambda *_: None)
    signal.set_wakeup_fd(wake_write, warn_on_full_buffer=False)
    try:
        if os.getppid() != runner_pid:
            raise Refusal("runner exited")
        with selectors.DefaultSelector() as selector:
            selector.register(wake_read, selectors.EVENT_READ)
            selector.register(control, selectors.EVENT_READ)
            selector.register(runner_fd, selectors.EVENT_READ)
            expected = descriptors()
            try:
                manifest, settings = verify_snapshot(directory, revision)
            except Exception:
                raise Refusal("snapshot verification failed") from None
            if manifest.get("warm_worker_safe") is not True:
                raise Refusal("consumer has not opted into warm workers")
            with contextlib.redirect_stdout(sys.stderr):
                app = construct_verified_app(directory, revision, manifest, settings)
            sys.stdout.flush()
            sys.stderr.flush()
            # No workers exist yet. All later forks are broker-managed
            # and their status descriptors are explicitly accounted for.
            if owned_children() or not fork_safe(expected, set()):
                raise Refusal("consumer is not fork-safe")
            if not send(control, b"R"):
                return
            while True:
                reap(children, selector)
                for key, _ in selector.select():
                    if key.fd == wake_read:
                        os.read(wake_read, 4096)
                        continue
                    if key.fd == runner_fd:
                        return
                    if key.data is not None:
                        pid = key.data
                        status = children.get(pid)
                        if status is key.fileobj:
                            # The sole request command is K. EOF, a reset, or
                            # malformed input also revokes this request only.
                            with contextlib.suppress(OSError):
                                status.recv(2, socket.MSG_DONTWAIT)
                            unwatch(selector, status)
                            kill_group(pid)
                        continue
                    launch(
                        control,
                        selector,
                        children,
                        expected,
                        runner_fd,
                        broker_fd,
                        directory,
                        revision,
                        app,
                        manifest,
                        settings,
                    )
    finally:
        for pid in children:
            kill_group(pid)
        # Direct import children and orphaned execution descendants are
        # ours as subreaper. Give SIGKILL a bounded window to reap successive
        # generations; a child stuck in uninterruptible I/O cannot hold exit.
        cutoff = time.monotonic() + 0.35
        while time.monotonic() < cutoff:
            reap(children, None)
            owned = owned_children()
            if not owned:
                break
            for pid in owned:
                with contextlib.suppress(ProcessLookupError):
                    os.kill(pid, signal.SIGKILL)
            time.sleep(0.005)
        for status in children.values():
            status.close()
        signal.set_wakeup_fd(-1)
        os.close(wake_read)
        os.close(wake_write)
        os.close(broker_fd)
        os.close(runner_fd)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--fd", required=True, type=int)
    parser.add_argument("--runner-pid", required=True, type=int)
    parser.add_argument("--bundle-dir", required=True, type=Path)
    parser.add_argument("--revision", required=True)
    args = parser.parse_args()
    with socket.socket(fileno=args.fd) as control:
        try:
            serve(control, args.runner_pid, args.bundle_dir, args.revision)
        except Exception as error:
            reason = str(error) if type(error) is Refusal else "broker startup failed"
            send(control, b"E" + reason.encode()[:1023])


if __name__ == "__main__":
    main()
