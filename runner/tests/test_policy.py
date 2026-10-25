# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
from __future__ import annotations

import copy
import json
import stat
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest.mock import patch

from mondek_runner.policy import (
    PolicyError,
    controller_url,
    decode_json,
    request,
    saved_plan,
    validate_manifest,
    validate_saved_plan,
    write_document,
)


def manifest():
    return {
        "version": 1,
        "project": "personal",
        "rules": [
            {
                "key": "disk-production",
                "name": "Production disks",
                "source_id": "my-monitoring",
                "parameter_contract": "disk.v1",
                "environment": "production",
                "params": {"warn": 80, "crit": 90},
            }
        ],
    }


class ValidationTests(unittest.TestCase):
    def test_optional_rules_and_source_defaults_require_no_mirror(self):
        self.assertEqual(
            validate_manifest({"version": 1, "project": "x", "rules": []})["rules"], []
        )
        self.assertEqual(validate_manifest(manifest()), manifest())

    def test_strict_shape_and_scalar_bounds(self):
        invalid = [
            None,
            [],
            {},
            {**manifest(), "version": True},
            {**manifest(), "unknown": 1},
            {**manifest(), "project": "x/y"},
        ]
        for fields in (
            {"key": "../key"},
            {"target_kind": "host"},
            {"params": {}},
            {"params": {"a": None}},
            {"params": {"a": []}},
            {"params": {"a": float("nan")}},
            {"priority": True},
            {"priority": 10001},
            {"enabled": 1},
            {"parameter_schema": {}},
            {"params": {"a": "bad\ntext"}},
            {"params": {"a": "x" * 2049}},
            {"name": "\ud800"},
            {"adopt_rule_id": "bad"},
        ):
            value = manifest()
            value["rules"][0].update(fields)
            invalid.append(value)
        for value in invalid:
            with self.subTest(value=repr(value)[:120]), self.assertRaises(PolicyError):
                validate_manifest(value)

    def test_duplicate_keys_adoption_and_complete_set_bounds(self):
        value = manifest()
        value["rules"] *= 2
        with self.assertRaisesRegex(PolicyError, "duplicate rule"):
            validate_manifest(value)
        value = manifest()
        value["rules"][0]["params"] = {f"a{i}": 1 for i in range(33)}
        with self.assertRaisesRegex(PolicyError, "1–32"):
            validate_manifest(value)
        value["rules"][0]["params"] = {f"a{i}": "x" * 2048 for i in range(9)}
        with self.assertRaisesRegex(PolicyError, "16 KiB"):
            validate_manifest(value)

    def test_exact_integer_and_finite_numbers(self):
        raw = (
            b'{"version":1,"project":"x","rules":[{"key":"r","name":"r","source_id":"s","parameter_contract":"c","params":{"n":'
            + b"9" * 4096
            + b"}}]}"
        )
        value = validate_manifest(decode_json(raw))
        self.assertEqual(value["rules"][0]["params"]["n"], 10**4096 - 1)
        with self.assertRaises((PolicyError, ValueError)):
            validate_manifest(decode_json(raw.replace(b"9" * 4096, b"9" * 4097)))
        value = manifest()
        value["rules"][0]["params"] = {"n": 9007199254740993, "f": 4.0, "b": True}
        self.assertEqual(
            validate_manifest(value)["rules"][0]["params"],
            {"n": 9007199254740993, "f": 4, "b": True},
        )

    def test_duplicate_or_nonstandard_json_never_silently_wins(self):
        for raw in (
            b'{"project":"x","project":"y"}',
            b'{"x":NaN}',
            b'{"x":Infinity}',
            b'{"x":1e400}',
            b"[]",
            b"\xff",
        ):
            with self.subTest(raw=raw), self.assertRaises(PolicyError):
                decode_json(raw)

    def test_controller_canonicalization_and_credential_rejection(self):
        self.assertEqual(controller_url("HTTP://LOCALHOST:80/"), "http://localhost")
        self.assertEqual(controller_url("http://[::1]:4001/"), "http://[::1]:4001")
        for url in (
            "file:///tmp/x",
            "https://u:p@host",
            "https://host/?token=a",
            "https://host/path",
            "https://host/#fragment",
            "https://host:99999",
            "https://host\n",
            "https://host:0",
        ):
            with self.subTest(url=url), self.assertRaises(PolicyError):
                controller_url(url)

    def test_review_file_is_bound_to_controller_and_contents(self):
        plan = {"manifest": manifest(), "review_token": "signed-review"}
        envelope = saved_plan("http://localhost:4001", plan)
        self.assertEqual(validate_saved_plan(envelope, "http://localhost:4001"), plan)
        with self.assertRaisesRegex(PolicyError, "another controller"):
            validate_saved_plan(envelope, "http://localhost:4000")
        changed = copy.deepcopy(envelope)
        changed["manifest"]["rules"][0]["params"]["warn"] = 70
        with self.assertRaisesRegex(PolicyError, "modified or corrupted"):
            validate_saved_plan(changed, "http://localhost:4001")
        with self.assertRaisesRegex(PolicyError, "conflicts"):
            saved_plan("http://localhost:4001", {**plan, "review_token": None})

    def test_atomic_output_replaces_symlink_not_target_and_is_private(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "original"
            target.write_text("preserve")
            output = Path(directory) / "plan"
            output.symlink_to(target)
            write_document(str(output), {"a": 1})
            self.assertEqual(target.read_text(), "preserve")
            self.assertFalse(output.is_symlink())
            self.assertEqual(stat.S_IMODE(output.stat().st_mode), 0o600)
            self.assertEqual(json.loads(output.read_text()), {"a": 1})


class HTTPTests(unittest.TestCase):
    def setUp(self):
        self.calls = []
        self.responses = {}
        self.slow_mode = None
        self.stop_slow = threading.Event()
        owner = self

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                self.respond()

            def do_POST(self):
                self.respond()

            def respond(self):
                if owner.slow_mode:
                    try:
                        if owner.slow_mode == "headers":
                            self.wfile.write(b"HTTP/1.0 200 OK\r\nX-Slow: ")
                        else:
                            self.send_response(
                                422 if owner.slow_mode == "error" else 200
                            )
                            self.send_header("Content-Length", "10000")
                            self.end_headers()
                        while not owner.stop_slow.wait(0.02):
                            self.wfile.write(b" ")
                            self.wfile.flush()
                    except (BrokenPipeError, ConnectionResetError):
                        pass
                    return
                length = int(self.headers.get("Content-Length", "0"))
                body = json.loads(self.rfile.read(length)) if length else None
                owner.calls.append((self.command, self.path, body))
                status, response, headers = owner.responses.get(
                    self.path, (404, {"error": "missing"}, {})
                )
                data = (
                    response
                    if isinstance(response, bytes)
                    else json.dumps(response).encode()
                )
                self.send_response(status)
                self.send_header("Content-Length", str(len(data)))
                self.send_header("Content-Type", "application/json")
                for key, value in headers.items():
                    self.send_header(key, value)
                self.end_headers()
                self.wfile.write(data)

            def log_message(self, *_):
                pass

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.cleanup_server)
        self.url = f"http://127.0.0.1:{self.server.server_port}"
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.file = self.root / "policy.json"
        self.file.write_text(json.dumps(manifest()))
        self.plan_file = self.root / "review.json"

    def cleanup_server(self):
        self.stop_slow.set()
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)

    def cli(self, *args, input=None):
        return subprocess.run(
            [sys.executable, "-m", "mondek_runner.policy", *map(str, args)],
            input=input,
            capture_output=True,
            text=True,
            timeout=20,
        )

    def configure_plan(self, token="signed-review"):
        self.plan = {
            "project": "personal",
            "manifest": manifest(),
            "review_token": token,
            "counts": {"create": 1, "matched": 2, "changed": 1, "exceptions": 1},
            "changes": [
                {
                    "action": "create",
                    "key": "disk-production",
                    "before": None,
                    "after": manifest()["rules"][0],
                }
            ],
            "rows": [
                {
                    "id": "assignment",
                    "label": "Disk",
                    "masked_by_exception": True,
                    "proposed_params": {"warn": 75},
                    "masked_params": {"warn": 80},
                }
            ],
        }
        self.responses["/api/v1/configuration/policy/plan"] = (200, self.plan, {})

    def test_validate_stdin_without_network_or_consumer_import(self):
        result = self.cli("validate", "-", "--json", input=json.dumps(manifest()))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), manifest())
        self.assertEqual(self.calls, [])
        invalid = self.cli("validate", "-", input='{"version":1,"project":"bad"}')
        self.assertEqual(invalid.returncode, 1)
        self.assertNotIn("Traceback", invalid.stderr)

    def test_plan_passes_explicit_baseline_and_rejects_invalid_revision(self):
        self.configure_plan()
        base = "a" * 40
        result = self.cli(
            "plan",
            self.file,
            "--controller",
            self.url,
            "--out",
            self.plan_file,
            "--base",
            base,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls[-1][2], {"manifest": manifest(), "base_head": base})
        count = len(self.calls)
        result = self.cli(
            "plan",
            self.file,
            "--controller",
            self.url,
            "--out",
            self.plan_file,
            "--base",
            "main",
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("full 40-character Git revision", result.stderr)
        self.assertEqual(len(self.calls), count)

    def test_plan_review_apply_and_exact_retry(self):
        self.configure_plan()
        result = self.cli(
            "plan", self.file, "--controller", self.url, "--out", self.plan_file
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Instance exception keeps", result.stdout)
        self.assertIn('"warn": 80', result.stdout)
        self.assertEqual(self.calls[-1][2], {"manifest": manifest()})
        envelope = json.loads(self.plan_file.read_text())
        self.assertEqual(envelope["controller"], self.url)
        self.assertEqual(stat.S_IMODE(self.plan_file.stat().st_mode), 0o600)
        self.responses["/api/v1/configuration/policy/apply"] = (
            200,
            {"project": "personal", "changed_count": 1},
            {},
        )
        result = self.cli("apply", self.plan_file, "--controller", self.url, "--json")
        self.assertEqual(result.returncode, 0, result.stderr)
        first = self.calls[-1][2]
        self.assertEqual(
            first, {"manifest": manifest(), "review_token": "signed-review"}
        )
        self.responses["/api/v1/configuration/policy/apply"] = (
            200,
            {"project": "personal", "replayed": True},
            {},
        )
        retry = self.cli("apply", self.plan_file, "--controller", self.url)
        self.assertEqual(retry.returncode, 0, retry.stderr)
        self.assertIn("Already applied", retry.stdout)
        self.assertEqual(self.calls[-1][2], first)
        self.assertEqual(sum(path.endswith("/plan") for _, path, _ in self.calls), 1)
        self.responses["/api/v1/configuration/policy/apply"] = (
            200,
            {
                "project": "personal",
                "replayed": True,
                "superseded": True,
                "current_project_revision": 3,
            },
            {},
        )
        historical = self.cli("apply", self.plan_file, "--controller", self.url)
        self.assertEqual(historical.returncode, 0, historical.stderr)
        self.assertIn("historical receipt restored no policy", historical.stdout)
        self.assertIn("Current project revision: 3", historical.stdout)

    def test_masked_conflict_is_explicit_in_human_plan(self):
        self.configure_plan()
        self.plan["rows"][0]["masked_error"] = "Equal priority rules conflict"
        result = self.cli(
            "plan", self.file, "--controller", self.url, "--out", self.plan_file
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Underlying conflict", result.stdout)
        self.assertIn("Removing the instance exception", result.stdout)

    def test_nonfinite_saved_plan_is_rejected_without_traceback(self):
        self.plan_file.write_text('{"version":1,"bad":{"number":1e400}}')
        result = self.cli("apply", self.plan_file, "--controller", self.url)
        self.assertEqual(result.returncode, 1)
        self.assertNotIn("Traceback", result.stderr)
        self.assertEqual(self.calls, [])

    def test_stale_plan_error_never_replans(self):
        self.configure_plan()
        write_document(str(self.plan_file), saved_plan(self.url, self.plan))
        self.responses["/api/v1/configuration/policy/apply"] = (
            409,
            {"error": "Review changed; plan again."},
            {},
        )
        result = self.cli("apply", self.plan_file, "--controller", self.url)
        self.assertEqual(result.returncode, 1)
        self.assertIn("HTTP 409: Review changed", result.stderr)
        self.assertEqual(len(self.calls), 1)

    def test_conflicted_plan_is_inspectable_but_not_saved(self):
        self.configure_plan(token=None)
        result = self.cli(
            "plan",
            self.file,
            "--controller",
            self.url,
            "--out",
            self.plan_file,
            "--json",
        )
        self.assertEqual(result.returncode, 1)
        self.assertIsNone(json.loads(result.stdout)["review_token"])
        self.assertFalse(self.plan_file.exists())

    def test_mismatched_plan_rejected_before_network(self):
        self.configure_plan()
        write_document(str(self.plan_file), saved_plan(self.url, self.plan))
        result = self.cli("apply", self.plan_file, "--controller", "http://127.0.0.1:1")
        self.assertEqual(result.returncode, 1)
        self.assertIn("another controller", result.stderr)
        self.assertEqual(self.calls, [])

    def test_redirect_is_not_followed_for_get_or_post(self):
        for status in (301, 302, 307, 308):
            for body in (None, {"manifest": manifest()}):
                with self.subTest(status=status, post=body is not None):
                    self.responses["/api/v1/configuration/policy/plan"] = (
                        status,
                        {},
                        {"Location": self.url + "/stolen"},
                    )
                    with self.assertRaisesRegex(PolicyError, "redirect"):
                        request(self.url, "policy/plan", body)
        self.assertFalse(any(path == "/stolen" for _, path, _ in self.calls))

    def test_response_size_deadline_and_malformed_payload(self):
        endpoint = "/api/v1/configuration/policy/export"
        self.responses[endpoint] = (200, b"{" + b"x" * 32, {})
        with (
            patch("mondek_runner.policy.MAX_RESPONSE_BYTES", 16),
            self.assertRaisesRegex(PolicyError, "size limit"),
        ):
            request(self.url, "policy/export")

    def test_whole_request_deadline_includes_slow_headers_success_and_error_bodies(
        self,
    ):
        for mode in ("headers", "success", "error"):
            with self.subTest(mode=mode):
                self.slow_mode = mode
                started = time.monotonic()
                with patch("mondek_runner.policy.HTTP_DEADLINE", 0.35):
                    with self.assertRaisesRegex(PolicyError, "time limit"):
                        request(self.url, "policy/export")
                self.assertLess(time.monotonic() - started, 2)
        self.slow_mode = None
        endpoint = "/api/v1/configuration/policy/export"
        self.responses[endpoint] = (200, b"not-json", {})
        with self.assertRaisesRegex(PolicyError, "JSON"):
            request(self.url, "policy/export")
        self.responses[endpoint] = (200, {}, {})
        with (
            patch("mondek_runner.policy.HTTP_DEADLINE", -1),
            self.assertRaisesRegex(PolicyError, "time limit"),
        ):
            request(self.url, "policy/export")

    def test_export_adoption_and_inspection(self):
        rule_id = "01adb8c9-69e9-4a8b-9329-981b9ef13aba"
        empty = {"version": 1, "project": "personal", "rules": []}
        self.responses["/api/v1/configuration/policy/export?project=personal"] = (
            200,
            empty,
            {},
        )
        self.responses[f"/api/v1/configuration/rules/{rule_id}"] = (
            200,
            {
                **manifest()["rules"][0],
                "id": rule_id,
                "revision": 3,
                "parameter_schema": {},
                "managed_project": None,
            },
            {},
        )
        result = self.cli(
            "export",
            "--project",
            "personal",
            "--out",
            self.file,
            "--controller",
            self.url,
            "--adopt",
            rule_id + "=adopted",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        value = json.loads(self.file.read_text())
        self.assertEqual(value["rules"][0]["adopt_rule_id"], rule_id)
        self.assertEqual(value["rules"][0]["key"], "adopted")
        self.assertNotIn("parameter_schema", value["rules"][0])
        self.responses[
            "/api/v1/configuration/policy/values?source_id=my-monitoring&page=1"
        ] = (
            200,
            {
                "page": 1,
                "total": 1,
                "rows": [
                    {
                        "id": "a",
                        "label": "Disk",
                        "source_defaults": {"warn": 80},
                        "current_params": {"warn": 70},
                        "current_origin": {"kind": "instance_exception"},
                        "masked_by_exception": True,
                        "masked_params": {"warn": 80},
                        "target_generation": 3,
                        "observed_generation": 2,
                    }
                ],
            },
            {},
        )
        result = self.cli(
            "inspect", "--source", "my-monitoring", "--controller", self.url
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Source defaults", result.stdout)
        self.assertIn("Instance exception masks", result.stdout)
        self.assertIn("Saved settings", result.stdout)
        self.assertIn("last measured generation: 2", result.stdout)
        self.assertIn("Awaiting a measurement", result.stdout)


if __name__ == "__main__":
    unittest.main()
