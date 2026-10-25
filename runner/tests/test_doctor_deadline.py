# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0

import os
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from mondek_runner.doctor import probe


class DoctorDeadlineTests(unittest.TestCase):
    def test_total_deadline_includes_a_stalled_error_response_body(self):
        release = threading.Event()
        reached = threading.Event()

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(403)
                self.send_header("Content-Length", "1000")
                self.end_headers()
                self.wfile.flush()
                reached.set()
                release.wait(5)

            def log_message(self, *args):
                pass

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        env = dict(os.environ)
        env.pop("MONDEK_CONTROLLER_HEADERS_FILE", None)
        try:
            before = time.monotonic()
            report = probe(
                f"http://127.0.0.1:{server.server_port}/api/v1/control", 1, env, {}
            )
            self.assertTrue(reached.is_set())
            self.assertEqual(report["kind"], "timeout")
            self.assertLess(time.monotonic() - before, 3)
        finally:
            release.set()
            server.shutdown()
            server.server_close()
            thread.join(2)
