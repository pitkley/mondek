# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Owned acceptance-only TLS gateway; never run against a deployed controller."""

import http.server
import json
import ssl
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path("/gateway")


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_POST(self):
        mode = json.loads((ROOT / "mode.json").read_text())
        observer = self.headers.get("X-Test-Observer", "")
        allowed = (
            observer in mode and self.headers.get("Authorization") == mode[observer]
        )
        print(
            json.dumps({"observer": observer, "path": self.path, "allowed": allowed}),
            flush=True,
        )
        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        if not allowed:
            self.send_response(403)
            self.send_header("CF-Ray", "0123456789abcdef-TST")
            self.end_headers()
            self.wfile.write(b"Forbidden")
            return
        request = urllib.request.Request(
            "http://controller:4000" + self.path,
            body,
            {"Content-Type": "application/json"},
        )
        try:
            response = urllib.request.urlopen(request, timeout=30)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            data = response.read()
            self.send_response(response.status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)


server = http.server.ThreadingHTTPServer(("0.0.0.0", 8443), Handler)
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain("/certs/cert.pem", "/certs/key.pem")
server.socket = context.wrap_socket(server.socket, server_side=True)
server.serve_forever()
