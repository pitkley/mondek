# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Kernel-backed connection races with controlled unreachable candidates."""

import errno
import socket
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from unittest.mock import patch

from mondek_runner import connections
from mondek_runner.transport import exchange


class BlackHole:
    """A real non-writable descriptor standing in for an unanswered SYN."""

    def __init__(self):
        self.writer, self.reader = socket.socketpair()
        self.writer.setblocking(False)
        try:
            while True:
                self.writer.send(b"x" * 65536)
        except BlockingIOError:
            pass
        self.closed = False

    def fileno(self):
        return self.writer.fileno()

    def setblocking(self, value):
        self.writer.setblocking(value)

    def connect_ex(self, _):
        return errno.EINPROGRESS

    def close(self):
        self.closed = True
        self.writer.close()
        self.reader.close()


def candidate(family, port):
    address = ("::1", port, 0, 0) if family == socket.AF_INET6 else ("127.0.0.1", port)
    return (family, socket.SOCK_STREAM, socket.IPPROTO_TCP, "", address)


class ConnectionTests(unittest.TestCase):
    def test_blackholed_first_family_falls_back_and_posts_once(self):
        for working in (socket.AF_INET, socket.AF_INET6):
            with self.subTest(working=working):
                calls = []

                class Handler(BaseHTTPRequestHandler):
                    def do_POST(self, calls=calls):
                        calls.append(
                            self.rfile.read(int(self.headers["Content-Length"]))
                        )
                        body = b'{"version":1}'
                        self.send_response(200)
                        self.send_header("Content-Length", str(len(body)))
                        self.end_headers()
                        self.wfile.write(body)

                    def log_message(self, *_):
                        pass

                class Server(ThreadingHTTPServer):
                    address_family = working

                try:
                    server = Server(
                        ("::1" if working == socket.AF_INET6 else "127.0.0.1", 0),
                        Handler,
                    )
                except OSError:
                    if working == socket.AF_INET6:
                        self.skipTest("IPv6 loopback unavailable")
                    raise
                thread = threading.Thread(target=server.serve_forever, daemon=True)
                thread.start()
                hole = BlackHole()
                other = socket.AF_INET6 if working == socket.AF_INET else socket.AF_INET
                real_socket = socket.socket

                def create(
                    family,
                    *args,
                    hole=hole,
                    other=other,
                    real_socket=real_socket,
                    **kwargs,
                ):
                    return (
                        hole
                        if family == other
                        else real_socket(family, *args, **kwargs)
                    )

                try:
                    with (
                        patch.dict("os.environ", {"no_proxy": "*"}),
                        patch.object(
                            connections.socket,
                            "getaddrinfo",
                            return_value=[
                                candidate(other, server.server_port),
                                candidate(other, server.server_port + 1),
                                candidate(working, server.server_port),
                            ],
                        ),
                        patch.object(connections.socket, "socket", side_effect=create),
                    ):
                        start = time.monotonic()
                        result = exchange(
                            "http://controller.invalid/api/v1/control", b"{}", 2
                        )
                        elapsed = time.monotonic() - start
                    self.assertEqual(result, {"version": 1})
                    self.assertEqual(calls, [b"{}"])
                    self.assertGreaterEqual(elapsed, connections.STAGGER_SECONDS * 0.8)
                    self.assertLess(elapsed, 1.5)
                    self.assertTrue(hole.closed)
                finally:
                    hole.close()
                    server.shutdown()
                    server.server_close()
                    thread.join()

    def test_all_pending_attempts_respect_total_deadline_and_close(self):
        holes = [BlackHole(), BlackHole()]
        try:
            with (
                patch.object(
                    connections.socket,
                    "getaddrinfo",
                    return_value=[
                        candidate(socket.AF_INET6, 1),
                        candidate(socket.AF_INET, 1),
                    ],
                ),
                patch.object(connections.socket, "socket", side_effect=holes),
            ):
                start = time.monotonic()
                with self.assertRaises(TimeoutError):
                    connections.connect(("controller.invalid", 443), 0.4)
                self.assertLess(time.monotonic() - start, 1)
            self.assertTrue(all(hole.closed for hole in holes))
        finally:
            for hole in holes:
                hole.close()

    def test_cancellation_closes_pending_socket(self):
        hole = BlackHole()
        try:
            with (
                patch.object(
                    connections.socket,
                    "getaddrinfo",
                    return_value=[candidate(socket.AF_INET6, 1)],
                ),
                patch.object(connections.socket, "socket", return_value=hole),
                patch.object(
                    connections.selectors.DefaultSelector,
                    "select",
                    side_effect=KeyboardInterrupt,
                ),
            ):
                with self.assertRaises(KeyboardInterrupt):
                    connections.connect(("controller.invalid", 443), 1)
            self.assertTrue(hole.closed)
        finally:
            hole.close()

    def test_failure_accelerates_next_attempt_and_empty_dns_is_explicit(self):
        with patch.object(connections.socket, "getaddrinfo", return_value=[]):
            with self.assertRaisesRegex(OSError, "No controller addresses"):
                connections.connect(("controller.invalid", 443), 1)

        class Refused(BlackHole):
            def connect_ex(self, _):
                return errno.ECONNREFUSED

        holes = [Refused(), Refused()]
        try:
            with (
                patch.object(
                    connections.socket,
                    "getaddrinfo",
                    return_value=[
                        candidate(socket.AF_INET6, 1),
                        candidate(socket.AF_INET, 1),
                    ],
                ),
                patch.object(connections.socket, "socket", side_effect=holes),
            ):
                start = time.monotonic()
                with self.assertRaises(ConnectionRefusedError):
                    connections.connect(("controller.invalid", 443), 2)
                self.assertLess(time.monotonic() - start, 0.2)
            self.assertTrue(all(hole.closed for hole in holes))
        finally:
            for hole in holes:
                hole.close()
