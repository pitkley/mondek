# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Real TLS requests through the bounded runner and policy subprocesses."""

import asyncio
import json
import os
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest.mock import patch

from test_connections import BlackHole, candidate
from test_runner import assignment, outcome

from mondek_runner.api import timestamp
from mondek_runner.connection_diagnostics import ConnectionEvents, failure_details
from mondek_runner.controller_auth import controller_headers
from mondek_runner.doctor import probe
from mondek_runner.policy import PolicyError, request
from mondek_runner.runtime import Runner
from mondek_runner.state import State
from mondek_runner.transport import exchange, post_json


class ControllerAuthenticationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        cert, key = self.root / "cert.pem", self.root / "key.pem"
        subprocess.run(
            [
                "openssl",
                "req",
                "-x509",
                "-newkey",
                "rsa:2048",
                "-nodes",
                "-keyout",
                str(key),
                "-out",
                str(cert),
                "-days",
                "1",
                "-subj",
                "/CN=localhost",
                "-addext",
                "subjectAltName=DNS:localhost",
            ],
            check=True,
            capture_output=True,
        )
        self.calls = []
        self.accepted = []
        self.expected = "test-secret-one"
        self.status = 200
        self.body = None
        self.ray = None
        self.methods = []
        owner = self

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                self.payload = json.loads(
                    self.rfile.read(int(self.headers.get("Content-Length", "0")))
                )
                self.do_GET()

            def do_GET(self):
                owner.calls.append((self.path, self.headers.get("Authorization")))
                owner.methods.append(self.command)
                code = (
                    owner.status
                    if self.headers.get("Authorization") == owner.expected
                    else 403
                )
                self.send_response(code, owner.expected)
                if code == 302:
                    self.send_header("Location", "/stolen")
                if owner.ray:
                    self.send_header("CF-Ray", owner.ray)
                self.end_headers()
                reply = {"version": 1, "error": owner.expected}
                if (
                    code == 200
                    and self.path == "/api/v1/observations"
                    and "reports" in getattr(self, "payload", {})
                ):
                    owner.accepted.extend(self.payload["reports"])
                    reply = {
                        "version": 1,
                        "dispositions": [
                            {"id": report["id"], "disposition": "current"}
                            for report in self.payload["reports"]
                        ],
                    }
                self.wfile.write(
                    owner.body if owner.body is not None else json.dumps(reply).encode()
                )

            def log_message(self, *args):
                pass

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(cert, key)
        self.server.socket = context.wrap_socket(self.server.socket, server_side=True)
        thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        self.origin = f"https://localhost:{self.server.server_port}"
        self.path = self.root / "headers.json"
        self.configure()
        env = patch.dict(
            os.environ,
            {
                "MONDEK_CONTROLLER_HEADERS_FILE": str(self.path),
                "SSL_CERT_FILE": str(cert),
            },
        )
        env.start()
        self.addCleanup(env.stop)

    def configure(self, **changes):
        document = {"origin": self.origin, "headers": {"Authorization": self.expected}}
        document.update(changes)
        self.path.write_text(json.dumps(document))
        self.path.chmod(0o600)

    def test_tls_and_auth_survive_unreachable_ipv6_without_duplicate_post(self):
        hole = BlackHole()
        real_socket = socket.socket

        def create(family, *args, **kwargs):
            return (
                hole
                if family == socket.AF_INET6
                else real_socket(family, *args, **kwargs)
            )

        try:
            with (
                patch.dict(os.environ, {"no_proxy": "*"}),
                patch(
                    "mondek_runner.connections.socket.getaddrinfo",
                    return_value=[
                        candidate(socket.AF_INET6, self.server.server_port),
                        candidate(socket.AF_INET, self.server.server_port),
                    ],
                ),
                patch("mondek_runner.connections.socket.socket", side_effect=create),
            ):
                result = exchange(self.origin + "/api/v1/control", b"{}", 3)
            self.assertEqual(result["version"], 1)
            self.assertEqual(self.calls, [("/api/v1/control", self.expected)])
            self.assertTrue(hole.closed)
        finally:
            hole.close()

    def test_all_runner_endpoints_and_policy_use_headers_and_rotation(self):
        for endpoint in ("inventory", "control", "observations"):
            self.assertEqual(
                post_json(self.origin + "/api/v1/" + endpoint, {}, 5)["version"], 1
            )
        request(self.origin, "policy/plan", {})
        self.expected = "rotated-secret"
        # Rejection must not echo the gateway's reason/body or lose ability to retry.
        with self.assertRaises(Exception) as raised:
            post_json(self.origin + "/api/v1/control", {}, 5)
        self.assertNotIn(self.expected, str(raised.exception))
        self.assertIn("access denied", str(raised.exception))
        self.configure()
        post_json(self.origin + "/api/v1/control", {}, 5)
        request(self.origin, "policy/export?project=test")
        self.assertEqual(self.calls[-1][1], self.expected)

    def test_redirects_and_gateway_errors_do_not_leak_secrets(self):
        for status in (302, 401, 403, 500):
            self.status = status
            for call in (
                lambda: post_json(self.origin + "/api/v1/control", {}, 5),
                lambda: request(self.origin, "policy/plan", {}),
            ):
                with self.assertRaises(Exception) as raised:
                    call()
                self.assertNotIn(self.expected, str(raised.exception))
        self.assertFalse(any(path == "/stolen" for path, _ in self.calls))

    def test_insecure_wrong_origin_and_malformed_files_fail_before_network(self):
        for url in (
            "http://localhost",
            "https://other.invalid",
            "https://user@localhost",
        ):
            with self.assertRaises(ValueError):
                controller_headers(url)
        for headers in (
            {"Host": "bad"},
            {"X-Test": "secret\r\nInjected: yes"},
            {"Authorization": "a", "authorization": "b"},
        ):
            self.configure(headers=headers)
            with self.assertRaises(ValueError):
                controller_headers(self.origin)
        for raw in ('{"headers": "secret"}', '{"origin":1,"origin":2}', "x" * 17000):
            self.path.write_text(raw)
            with self.assertRaises(ValueError) as raised:
                controller_headers(self.origin)
            self.assertNotIn(raw, str(raised.exception))
        self.configure()
        self.path.chmod(0o644)
        with self.assertRaises(PolicyError):
            request(self.origin, "policy/plan", {})
        self.path.unlink()
        with self.assertRaises(ValueError):
            controller_headers(self.origin)
        self.assertEqual(self.calls, [])

    def test_auth_outage_preserves_journal_across_restart_and_reconnect(self):
        async def exercise():
            state_path = self.root / "state"
            state = State(state_path)
            state.adopt(assignment(), 0)
            first = outcome(state.allocate(assignment(), 0, timestamp()))
            state.complete(first)
            self.expected = "rotated-secret"
            runner = Runner(state, self.origin, consumer="demo_checks.app:app")
            runner.registered.set()
            task = asyncio.create_task(runner.upload())

            async def wait_for(predicate):
                async with asyncio.timeout(5):
                    while not predicate():
                        await asyncio.sleep(0.02)

            try:
                await wait_for(
                    lambda: "access denied" in (state.get("diagnostic") or "")
                )
                self.assertEqual(state.batch(), [first])
                # Another measurement can be journalled while access is rejected.
                second = outcome(state.allocate(assignment(), 3, timestamp()))
                state.complete(second)
            finally:
                runner.stopped.set()
                await task
                state.close()
            state = State(state_path)
            try:
                self.assertEqual(state.batch(), [first, second])
                self.configure()
                runner = Runner(state, self.origin, consumer="demo_checks.app:app")
                runner.registered.set()
                task = asyncio.create_task(runner.upload())
                try:
                    await wait_for(lambda: not state.batch())
                    self.assertEqual(self.accepted, [first, second])
                finally:
                    runner.stopped.set()
                    await task
            finally:
                state.close()

        asyncio.run(exercise())

    def test_no_auth_configuration_preserves_local_http(self):
        with patch.dict(os.environ):
            os.environ.pop("MONDEK_CONTROLLER_HEADERS_FILE")
            self.assertEqual(controller_headers("http://localhost:4000"), {})

    def test_doctor_cli_probes_all_routes_without_post_or_journal(self):
        self.status = 404
        completed = subprocess.run(
            [
                sys.executable,
                "-m",
                "mondek_runner",
                "doctor",
                "--controller",
                self.origin,
            ],
            capture_output=True,
            text=True,
            timeout=15,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        report = json.loads(completed.stdout)
        self.assertTrue(report["read_only"])
        self.assertFalse(report["registration_tested"])
        self.assertEqual(
            [item["endpoint"] for item in report["results"]],
            ["/api/v1/" + name for name in ("inventory", "control", "observations")],
        )
        self.assertTrue(
            all(item["outcome"] == "reachable_unverified" for item in report["results"])
        )
        self.assertEqual(self.methods, ["GET"] * 3)
        self.assertNotIn(self.expected, completed.stdout + completed.stderr)

    def test_doctor_gateway_evidence_redirects_and_private_file_errors(self):
        self.ray = "a3d1999bcdd8d963-TXL"
        self.status = 403
        self.body = b"secret reflected error code: 1010"
        report = probe(self.origin + "/api/v1/control", 3, dict(os.environ), {})
        self.assertEqual(report["cf_error_code"], 1010)
        self.assertEqual(report["cf_ray"], self.ray)
        self.assertEqual(report["outcome"], "blocked")
        with self.assertRaises(Exception) as failure:
            post_json(self.origin + "/api/v1/inventory", {}, 3)
        details = failure_details(failure.exception)
        self.assertEqual(details["cf_error_code"], 1010)
        self.assertEqual(details["cf_ray"], self.ray)
        self.assertNotIn("secret", json.dumps(details))
        self.body = b"Forbidden"
        report = probe(self.origin + "/api/v1/control", 3, dict(os.environ), {})
        self.assertEqual(report["outcome"], "denied")
        self.assertIn("tunnel JWT audiences", report["message"])
        self.status = 302
        report = probe(self.origin + "/api/v1/control", 3, dict(os.environ), {})
        self.assertEqual(report["outcome"], "redirect")
        self.assertFalse(any(path == "/stolen" for path, _ in self.calls))
        before = len(self.calls)
        self.path.chmod(0o644)
        report = probe(self.origin + "/api/v1/control", 3, dict(os.environ), {})
        self.assertEqual(report["kind"], "authentication_file")
        self.assertEqual(len(self.calls), before)
        self.assertNotIn(self.expected, json.dumps(report))

    def test_transport_preserves_certificate_failure_classification(self):
        with patch.dict(os.environ):
            os.environ.pop("SSL_CERT_FILE")
            with self.assertRaises(Exception) as failure:
                post_json(self.origin + "/api/v1/control", {}, 3)
        self.assertEqual(failure_details(failure.exception)["kind"], "tls_certificate")

    def test_upload_logs_auth_failure_and_recovery_and_clears_diagnostic(self):
        async def exercise():
            state = State(self.root / "recovery-state")
            state.adopt(assignment(), 0)
            original = outcome(state.allocate(assignment(), 0, timestamp()))
            state.complete(original)
            runner = Runner(state, self.origin, consumer="demo_checks.app:app")
            events = []
            runner.connection_events = ConnectionEvents(emit=events.append)
            runner.registered.set()
            self.status = 403
            task = asyncio.create_task(runner.upload())
            try:
                async with asyncio.timeout(8):
                    while not events:
                        await asyncio.sleep(0.02)
                    self.assertEqual(events[0]["event"], "controller_unavailable")
                    self.assertEqual(events[0]["channel"], "observations")
                    self.assertEqual(state.batch(), [original])
                    self.status = 200
                    while state.batch():
                        await asyncio.sleep(0.02)
                self.assertEqual(self.accepted, [original])
                self.assertTrue(events[-1]["recovered"])
                self.assertIsNone(state.get("diagnostic"))
                self.assertNotIn(self.expected, json.dumps(events))
            finally:
                runner.stopped.set()
                await task
                state.close()

        asyncio.run(exercise())
