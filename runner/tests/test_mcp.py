# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Process and failure boundaries of the local MCP transport adapter."""

import argparse
import json
import subprocess
import sys
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from mondek_runner.mcp import MAX_REQUEST, MAX_RESPONSE, endpoint


class MCPTests(unittest.TestCase):
    def run_bridge(self, origin, messages):
        return subprocess.run(
            [sys.executable, "-m", "mondek_runner.mcp", "--controller", origin],
            input=messages,
            capture_output=True,
            text=True,
            timeout=25,
        )

    def test_controller_origin_validation(self):
        self.assertEqual(
            endpoint("http://localhost:4000/"), "http://localhost:4000/mcp"
        )
        for value in [
            "file:///tmp/data",
            "http://user:pass@host",
            "http://host/api",
            "http://host/?secret=x",
        ]:
            with self.assertRaises(argparse.ArgumentTypeError):
                endpoint(value)

    def test_eof_and_oversized_input_exit_cleanly(self):
        eof = self.run_bridge("http://127.0.0.1:1", "")
        self.assertEqual(eof.returncode, 0)
        self.assertEqual(eof.stdout, "")
        large = self.run_bridge("http://127.0.0.1:1", "x" * (MAX_REQUEST + 1))
        self.assertEqual(large.returncode, 1)
        self.assertEqual(large.stdout, "")
        self.assertIn("16 KiB", large.stderr)

    def test_redirects_large_bodies_and_private_error_bodies_are_not_forwarded(self):
        class Handler(BaseHTTPRequestHandler):
            mode = "redirect"
            paths = []

            def do_POST(self):
                type(self).paths.append(self.path)
                self.rfile.read(int(self.headers["Content-Length"]))
                if self.mode == "redirect":
                    self.send_response(307)
                    self.send_header("Location", "/private")
                elif self.mode == "large":
                    self.send_response(200)
                else:
                    self.send_response(500)
                self.end_headers()
                try:
                    self.wfile.write(
                        b"x" * (MAX_RESPONSE + 1)
                        if self.mode == "large"
                        else b"private-token"
                    )
                except (BrokenPipeError, ConnectionResetError):
                    pass

            def log_message(self, *args):
                pass

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            for mode in ["redirect", "large", "error"]:
                Handler.mode = mode
                reply = self.run_bridge(
                    f"http://127.0.0.1:{server.server_port}",
                    json.dumps({"jsonrpc": "2.0", "id": 42, "method": "ping"}) + "\n",
                )
                self.assertEqual(reply.returncode, 0)
                self.assertEqual(json.loads(reply.stdout)["id"], 42)
                self.assertIn("error", json.loads(reply.stdout))
                self.assertNotIn("private-token", reply.stdout + reply.stderr)
            self.assertEqual(Handler.paths, ["/mcp"] * 3)
        finally:
            server.shutdown()
            server.server_close()
            thread.join()
