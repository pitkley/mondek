#!/usr/bin/env python3
# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Local-only SMTP acceptance fixture; no messages leave this process.

SMTP_PORT=2525, HTTP_PORT=8080, FIXTURE_BIND=0.0.0.0 by default.
Optional SMTP_STATE_DIR persists records across restart. Optional SMTP_CERT_FILE
and SMTP_KEY_FILE enable STARTTLS; SMTP_IMPLICIT_TLS=true enables direct TLS.
POST /control {"mode": "accept|refuse|ambiguous|timeout|auth_refuse"}.
GET /records returns bounded receipts, GET /state includes connection count.
"""

from __future__ import annotations

import email
import email.policy
import json
import os
from pathlib import Path
import signal
import socketserver
import ssl
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any


class State:
    def __init__(self) -> None:
        self.lock = threading.RLock()
        self.mode = "accept"
        self.connections = 0
        self.reply_bytes = 0
        self.records: list[dict[str, Any]] = []
        self.path = (
            Path(os.environ["SMTP_STATE_DIR"]) / "smtp-records.json"
            if os.environ.get("SMTP_STATE_DIR")
            else None
        )
        if self.path and self.path.exists():
            self.records = json.loads(self.path.read_text())[-2000:]

    def record(self, raw: str, sender: str, recipient: str, mode: str) -> None:
        message = email.message_from_string(raw, policy=email.policy.default)
        with self.lock:
            self.records.append(
                {
                    "message_id": message.get("Message-ID"),
                    "occurrence_id": message.get("X-Mondek-Occurrence"),
                    "subject": str(message.get("Subject", "")),
                    "body": message.get_content(),
                    "from": message.get("From"),
                    "to": message.get("To"),
                    "envelope_from": sender,
                    "envelope_to": recipient,
                    "raw": raw,
                    "mode": mode,
                    "received_at": time.time(),
                }
            )
            self.records = self.records[-2000:]
            if self.path:
                self.path.parent.mkdir(parents=True, exist_ok=True)
                temporary = self.path.with_suffix(".tmp")
                temporary.write_text(json.dumps(self.records))
                temporary.replace(self.path)


STATE = State()
TLS: ssl.SSLContext | None = None
if os.environ.get("SMTP_CERT_FILE"):
    TLS = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    TLS.minimum_version = ssl.TLSVersion.TLSv1_2
    TLS.load_cert_chain(os.environ["SMTP_CERT_FILE"], os.environ["SMTP_KEY_FILE"])


class SMTP(socketserver.StreamRequestHandler):
    timeout = 35

    def setup(self) -> None:
        if TLS and os.environ.get("SMTP_IMPLICIT_TLS") == "true":
            self.request = TLS.wrap_socket(self.request, server_side=True)
        super().setup()

    def reply(self, value: str) -> None:
        self.wfile.write((value + "\r\n").encode())
        self.wfile.flush()

    def handle(self) -> None:
        with STATE.lock:
            STATE.connections += 1
        sender = recipient = ""
        try:
            self.reply("220 mondek-local-fixture ESMTP")
            while raw := self.rfile.readline(8193):
                if len(raw) > 8192:
                    return
                line = raw.decode("utf-8", "replace").rstrip("\r\n")
                verb = line.split(" ", 1)[0].upper()
                with STATE.lock:
                    mode = STATE.mode
                if verb in {"EHLO", "HELO"}:
                    if mode == "oversized":
                        self.reply("250 " + "x" * 9000)
                        return
                    if mode == "multiline":
                        for _ in range(8192):
                            packet = "250-" + "x" * 8000
                            self.reply(packet)
                            with STATE.lock:
                                STATE.reply_bytes += len(packet) + 2
                        return
                    self.reply("250-mondek-local-fixture")
                    if TLS and not isinstance(self.connection, ssl.SSLSocket):
                        self.reply("250-STARTTLS")
                    self.reply("250 AUTH PLAIN")
                elif verb == "STARTTLS" and TLS:
                    self.reply("220 Begin TLS")
                    self.connection = TLS.wrap_socket(self.connection, server_side=True)
                    self.rfile = self.connection.makefile("rb")
                    self.wfile = self.connection.makefile("wb")
                elif verb == "AUTH":
                    # Deliberately echo dummy sensitive text to prove redaction.
                    # Never record or decode the supplied AUTH argument.
                    self.reply(
                        "535 dummy-secret-must-not-leak"
                        if mode == "auth_refuse"
                        else "235 Authentication accepted"
                    )
                elif verb == "MAIL":
                    sender = line.partition(":")[2].strip()
                    self.reply("250 Sender accepted")
                elif verb == "RCPT":
                    recipient = line.partition(":")[2].strip()
                    self.reply(
                        "451 dummy-secret-must-not-leak"
                        if mode == "refuse"
                        else "250 Recipient accepted"
                    )
                elif verb == "DATA":
                    self.reply("354 End with a single dot")
                    chunks: list[bytes] = []
                    total = 0
                    while chunk := self.rfile.readline(8193):
                        if chunk == b".\r\n":
                            break
                        total += len(chunk)
                        if total > 128 * 1024:
                            return
                        chunks.append(chunk[1:] if chunk.startswith(b"..") else chunk)
                    STATE.record(
                        b"".join(chunks).decode("utf-8"), sender, recipient, mode
                    )
                    if mode == "ambiguous":
                        return
                    if mode == "timeout":
                        time.sleep(32)
                        return
                    self.reply("250 Recorded locally")
                elif verb == "QUIT":
                    self.reply("221 Goodbye")
                    return
                elif verb in {"RSET", "NOOP"}:
                    self.reply("250 OK")
                else:
                    self.reply("500 Unsupported command")
        except (OSError, ssl.SSLError):
            pass


class SMTPServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

    def handle_error(self, request: Any, client_address: Any) -> None:
        # Expected TLS rejection and connection loss should not dump data.
        pass


class HTTP(BaseHTTPRequestHandler):
    def log_message(self, format: str, *args: Any) -> None:
        pass

    def send_json(self, status: int, value: Any) -> None:
        body = json.dumps(value).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:
        with STATE.lock:
            if self.path == "/records":
                self.send_json(200, STATE.records)
            elif self.path in {"/state", "/health"}:
                self.send_json(
                    200,
                    {
                        "mode": STATE.mode,
                        "connections": STATE.connections,
                        "reply_bytes": STATE.reply_bytes,
                    },
                )
            else:
                self.send_json(404, {"error": "not found"})

    def do_POST(self) -> None:
        if self.path != "/control":
            self.send_json(404, {"error": "not found"})
            return
        length = int(self.headers.get("Content-Length", "0"))
        if not 0 < length <= 4096:
            self.send_json(400, {"error": "invalid request size"})
            return
        try:
            request = json.loads(self.rfile.read(length))
            mode = request["mode"]
            if mode not in {
                "accept",
                "refuse",
                "ambiguous",
                "timeout",
                "auth_refuse",
                "oversized",
                "multiline",
            }:
                raise ValueError("invalid mode")
        except (KeyError, ValueError, TypeError):
            self.send_json(400, {"error": "invalid mode"})
            return
        with STATE.lock:
            STATE.mode = mode
        self.send_json(200, {"mode": mode})


def main() -> None:
    bind = os.environ.get("FIXTURE_BIND", "0.0.0.0")
    smtp = SMTPServer((bind, int(os.environ.get("SMTP_PORT", "2525"))), SMTP)
    http = ThreadingHTTPServer((bind, int(os.environ.get("HTTP_PORT", "8080"))), HTTP)
    threading.Thread(target=smtp.serve_forever, daemon=True).start()
    if os.environ.get("FIXTURE_EXIT_ON_STDIN_EOF") == "true":

        def exit_on_eof() -> None:
            sys.stdin.buffer.read()
            os._exit(0)

        threading.Thread(target=exit_on_eof, daemon=True).start()
    signal.signal(signal.SIGTERM, lambda *_: os._exit(0))
    print(
        json.dumps(
            {"smtp_port": smtp.server_address[1], "http_port": http.server_port}
        ),
        flush=True,
    )
    http.serve_forever()


if __name__ == "__main__":
    main()
