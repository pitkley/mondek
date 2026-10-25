# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Staggered TCP connection attempts for the controller transport only."""

from __future__ import annotations

import errno
import selectors
import socket
import time
from http.client import HTTPConnection, HTTPSConnection
from typing import Any
from urllib.request import HTTPHandler, HTTPSHandler, Request

STAGGER_SECONDS = 0.25
MAX_ADDRESSES = 16


def connect(
    address: tuple[str, int],
    timeout: float,
    source_address: tuple[str, int] | None = None,
) -> socket.socket:
    """Race TCP addresses, retaining one socket and closing every losing attempt.

    DNS and the entire HTTP/TLS exchange remain bounded by the transport helper's
    absolute process deadline. Only TCP is raced: no duplicate HTTP submissions.
    """
    deadline = time.monotonic() + timeout
    resolved = socket.getaddrinfo(*address, type=socket.SOCK_STREAM)
    unique = list(dict.fromkeys(resolved))
    if not unique:
        raise OSError("No controller addresses resolved")
    # Preserve resolver order within each family; try the alternate family next.
    first = unique[0][0]
    preferred = [item for item in unique if item[0] == first]
    alternate = [item for item in unique if item[0] != first]
    ordered = []
    while preferred or alternate:
        if preferred:
            ordered.append(preferred.pop(0))
        if alternate:
            ordered.append(alternate.pop(0))
    ordered = ordered[:MAX_ADDRESSES]
    pending: set[socket.socket] = set()
    winner = None
    last_error: OSError = OSError("No reachable controller address")
    next_start = time.monotonic()
    index = 0
    with selectors.DefaultSelector() as selector:
        try:
            while index < len(ordered) or pending:
                now = time.monotonic()
                if now >= deadline:
                    raise TimeoutError("Controller connection deadline exceeded")
                if index < len(ordered) and (not pending or now >= next_start):
                    family, kind, proto, _, destination = ordered[index]
                    index += 1
                    sock = None
                    try:
                        sock = socket.socket(family, kind, proto)
                        pending.add(sock)
                        sock.setblocking(False)
                        if source_address:
                            sock.bind(source_address)
                        code = sock.connect_ex(destination)
                        if code in (0, errno.EISCONN):
                            winner = sock
                            break
                        if code not in (
                            errno.EINPROGRESS,
                            errno.EWOULDBLOCK,
                            errno.EALREADY,
                            errno.EINTR,
                        ):
                            raise OSError(code, "Controller connection failed")
                        selector.register(sock, selectors.EVENT_WRITE)
                        next_start = now + STAGGER_SECONDS
                    except OSError as error:
                        last_error = error
                        if sock is not None:
                            pending.discard(sock)
                            sock.close()
                        next_start = now
                    # Fill another attempt immediately after a hard failure.
                    continue
                wait = deadline - time.monotonic()
                if index < len(ordered):
                    wait = min(wait, next_start - time.monotonic())
                for key, _ in selector.select(max(0, wait)):
                    sock = key.fileobj
                    code = sock.getsockopt(socket.SOL_SOCKET, socket.SO_ERROR)
                    selector.unregister(sock)
                    if code == 0:
                        winner = sock
                        break
                    last_error = OSError(code, "Controller connection failed")
                    pending.remove(sock)
                    sock.close()
                    next_start = time.monotonic()
                if winner is not None:
                    break
            if winner is None:
                raise last_error
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("Controller connection deadline exceeded")
            winner.settimeout(remaining)
            return winner
        except BaseException:
            if winner is not None:
                winner.close()
            raise
        finally:
            for sock in pending:
                if sock is not winner:
                    sock.close()


class ControllerHTTPConnection(HTTPConnection):
    def __init__(self, *args: Any, **kwargs: Any) -> None:
        super().__init__(*args, **kwargs)
        self._create_connection = connect


class ControllerHTTPSConnection(HTTPSConnection):
    def __init__(self, *args: Any, **kwargs: Any) -> None:
        super().__init__(*args, **kwargs)
        self._create_connection = connect


class ControllerHTTPHandler(HTTPHandler):
    def http_open(self, req: Request) -> Any:
        return self.do_open(ControllerHTTPConnection, req)


class ControllerHTTPSHandler(HTTPSHandler):
    def https_open(self, req: Request) -> Any:
        # The standard HTTPSConnection still performs TLS and hostname validation,
        # including its existing proxy CONNECT behavior. Never retry TLS errors.
        return self.do_open(ControllerHTTPSConnection, req, context=self._context)
