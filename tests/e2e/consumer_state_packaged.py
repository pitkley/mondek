#!/usr/bin/env python3
# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Upgrade a real release database, then qualify installed state checks over TLS."""

from __future__ import annotations

import argparse
from datetime import UTC, datetime
import hashlib
import http.server
import json
import os
from pathlib import Path
import sqlite3
import ssl
import subprocess
import sys
import tarfile
import tempfile
import threading
import time
import urllib.error
import urllib.request
import uuid
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SOURCE = "packaged-state-qualification"
STATE_MIGRATION = 20261116120000
UPGRADE_MIGRATIONS = (STATE_MIGRATION, 20261116120100, 20261116160000)
RUNNER_PATHS = frozenset(
    f"/api/v1/runner/{name}"
    for name in ("inventory", "control", "observations", "state")
)
CONSUMER = """
import os
from mondek_runner import App, Environment, Result, check, crit, ok, unknown, Parameter

@check(id="baseline", expected_keys=("health",), interval_seconds=1, timeout_seconds=3, freshness_seconds=20,
       params={"threshold": 5}, parameters={"threshold": Parameter("integer", "Threshold", minimum=1)})
def baseline(*, params: dict[str, int]) -> Result:
    return crit("health", "Synthetic retained failure", value=10) if 10 >= params["threshold"] else ok("health", "Synthetic recovery")

checks = [baseline]
if os.environ["QUAL_PHASE"] == "state":
    from mondek_runner import CheckContext, StateError, StateConflict
    @check(id="state", expected_keys=("health",), interval_seconds=1, timeout_seconds=3, freshness_seconds=20)
    def state(ctx: CheckContext) -> Result:
        try:
            if os.environ["QUAL_ROLE"] == "writer":
                try:
                    ctx.state.compare_and_set("production/nonce/v1", "missing", {"nonce": os.environ["QUAL_NONCE"]})
                except StateConflict:
                    pass
            entry = ctx.state.get("production/nonce/v1")
            if entry is None or entry.value != {"nonce": os.environ["QUAL_NONCE"]}:
                return unknown("health", "Expected shared nonce unavailable")
            local = ctx.state.for_check().get("role")
            if local is None:
                ctx.state.for_check().compare_and_set("role", "missing", os.environ["QUAL_ROLE"])
            elif local.value != os.environ["QUAL_ROLE"]:
                return unknown("health", "Assignment-local state crossed runners")
            return ok("health", "Verified shared nonce " + entry.value["nonce"])
        except StateError:
            return unknown("health", "Controller state unavailable")
    checks.append(state)
app = App(source_id="packaged-state-qualification", environment=Environment("production"), checks=checks,
          construction_environment={name: os.environ[name] for name in ("QUAL_PHASE", "QUAL_ROLE", "QUAL_NONCE")})
"""
CLIENT = """
import json, sys, time
from mondek_runner.consumer_state import _StateClient
from mondek_runner import StateConflict
p = json.load(sys.stdin)
c = _StateClient(p["url"], p["identity"], deadline=time.monotonic()+10)
op = p["operation"]
try:
    if op == "get": result = c.get(p["key"])
    elif op == "put": result = c.put(p["key"], p["value"], ttl_seconds=p.get("ttl_seconds"))
    elif op == "cas": result = c.compare_and_set(p["key"], p["expected_version"], p["value"])
    print(json.dumps({"entry": result.__dict__ if result else None}))
except StateConflict:
    print(json.dumps({"conflict": True}))
"""


def isolated_environment(environment):
    return {
        k: v
        for k, v in environment.items()
        if k != "PYTHONPATH"
        and not k.startswith(("MONDEK_", "PG", "SMTP_", "FIXTURE_"))
    }


def image_info(name: str, env: dict[str, str]) -> dict:
    data = json.loads(
        subprocess.check_output(
            ["docker", "image", "inspect", name], env=env, timeout=30
        )
    )[0]
    return {
        "id": data["Id"],
        "digests": data.get("RepoDigests", []),
        "platform": f"{data['Os']}/{data['Architecture']}",
        "revision": data["Config"]
        .get("Labels", {})
        .get("org.opencontainers.image.revision"),
    }


def assert_preserved(before: dict, after: dict) -> None:
    for table, rows in before.items():
        if after.get(table) != rows:
            raise AssertionError(f"Upgrade changed preserved {table} rows")


def wait_for(label, predicate, timeout=90):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            value = predicate()
            if value:
                return value
        except (OSError, ValueError, KeyError):
            pass
        time.sleep(0.25)
    raise TimeoutError(f"Packaged state qualification timed out: {label}")


class Gateway(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, certificate, key, token):
        self.token = token
        self.upstream = None
        self.records = []
        self.guard = threading.Lock()
        super().__init__(("127.0.0.1", 0), GatewayHandler)
        tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        tls.load_cert_chain(certificate, key)
        self.socket = tls.wrap_socket(self.socket, server_side=True)


class GatewayHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        allowed = (
            self.path in RUNNER_PATHS
            and self.headers.get("Authorization") == self.server.token
        )
        status = 403
        body = b"{}"
        if allowed:
            request = urllib.request.Request(
                self.server.upstream + self.path,
                raw,
                {"Content-Type": "application/json"},
            )
            try:
                response = urllib.request.urlopen(request, timeout=15)
            except urllib.error.HTTPError as error:
                response = error
            with response:
                status, body = response.status, response.read()
        with self.server.guard:
            self.server.records.append(
                {
                    "path": self.path,
                    "allowed": allowed,
                    "forwarded": allowed,
                    "status": status,
                }
            )
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


class Qualification:
    def __init__(self, args, workspace, output, log):
        self.args, self.workspace, self.output, self.log = args, workspace, output, log
        self.project = output.name
        self.env = isolated_environment(os.environ)
        helper = Path("/Applications/Docker.app/Contents/Resources/bin")
        if helper.is_dir():
            self.env["PATH"] += os.pathsep + str(helper)
        self.images = {
            name: image_info(value, self.env)
            for name, value in (
                ("baseline", args.baseline_image),
                ("candidate", args.image),
            )
        }
        self.baseline_ref = args.baseline_ref or self.images["baseline"]["revision"]
        if not self.baseline_ref:
            raise ValueError("Supply --baseline-ref for an unlabelled baseline image")
        self.runners = []
        self.nonce = uuid.uuid4().hex
        self.gateway = None

    def run(self, *command, cwd=ROOT, capture=False, input=None, env=None):
        result = subprocess.run(
            command,
            cwd=cwd,
            env=env or self.env,
            input=input,
            text=True,
            stdout=subprocess.PIPE if capture else self.log,
            stderr=self.log,
            check=True,
            timeout=600,
        )
        return result.stdout if capture else None

    def compose(self, *args, capture=False):
        return self.run(
            "docker",
            "compose",
            "-p",
            self.project,
            "--env-file",
            str(self.private),
            "-f",
            str(ROOT / "deploy/compose.yaml"),
            "-f",
            str(self.overlay),
            *args,
            capture=capture,
        )

    def sql(self, query):
        return json.loads(
            self.compose(
                "exec",
                "-T",
                "postgres",
                "psql",
                "-U",
                "mondek",
                "-d",
                "mondek",
                "-At",
                "-c",
                query,
                capture=True,
            )
        )

    def read(self, path):
        with urllib.request.urlopen(self.origin + path, timeout=5) as response:
            return json.load(response)

    def preserved(self):
        tables = {
            "observations": "*",
            "configurations": "*",
            "configuration_revisions": "*",
            "configuration_git_objects": "*",
            "assignments": "id, runner_id, source_id, source_key, desired_generation, params, retired_at",
            "result_streams": "id, assignment_id, result_key, target, retired_at",
            "runners": "id, session_id, boot",
            "incidents": "id, assignment_id, stream_id, status, health, opening_observation_id, latest_failure_observation_id, opening_generation",
        }
        return {
            table: self.sql(
                f"SELECT coalesce(json_agg(t ORDER BY t::text), '[]') FROM (SELECT {columns} FROM {table}) t"
            )
            for table, columns in tables.items()
        }

    def schema(self):
        return self.sql(
            "SELECT json_build_object('versions', (SELECT json_agg(version ORDER BY version) FROM schema_migrations), 'state_table', to_regclass('public.consumer_state_entries')::text)"
        )

    def switch(self, phase, stage=None):
        self.env["MONDEK_IMAGE"] = self.images[phase]["id"]
        self.compose(
            "up",
            "-d",
            "--wait",
            "--wait-timeout",
            "180",
            "--pull",
            "never",
            "--no-deps",
            "--force-recreate",
            "controller",
        )
        address = self.compose("port", "controller", "4000", capture=True).strip()
        self.origin = "http://" + address
        self.gateway.upstream = self.origin
        container = self.compose("ps", "-q", "controller", capture=True).strip()
        actual = self.run(
            "docker", "inspect", container, "--format", "{{.Image}}", capture=True
        ).strip()
        assert actual == self.images[phase]["id"], (actual, self.images[phase])
        self.output.joinpath(f"{stage or phase}-startup.log").write_text(
            self.compose("logs", "--no-color", "controller", capture=True)
        )

    def install(self, phase):
        source = ROOT / "runner"
        if phase == "baseline":
            archive = self.workspace / "baseline.tar"
            with archive.open("wb") as stream:
                subprocess.run(
                    ["git", "archive", self.baseline_ref, "runner"],
                    cwd=ROOT,
                    stdout=stream,
                    check=True,
                    timeout=30,
                )
            with tarfile.open(archive) as bundle:
                bundle.extractall(self.workspace / "baseline", filter="data")
            source = self.workspace / "baseline/runner"
        dist = self.workspace / f"{phase}-dist"
        self.run(
            "uv", "build", "--project", str(source), "--wheel", "--out-dir", str(dist)
        )
        wheel = next(dist.glob("*.whl"))
        venv = self.workspace / f"{phase}-venv"
        self.run("uv", "venv", str(venv), "--python", sys.executable)
        python = venv / "bin/python"
        self.run("uv", "pip", "install", "--python", str(python), str(wheel))
        self.run(
            "uv",
            "pip",
            "install",
            "--python",
            str(python),
            "--no-deps",
            str(self.consumer),
        )
        package = json.loads(
            self.run(
                str(python),
                "-I",
                "-c",
                "import json,importlib.metadata,mondek_runner; print(json.dumps({'version':importlib.metadata.version('mondek'),'module':mondek_runner.__file__}))",
                capture=True,
            )
        )
        assert "site-packages/mondek_runner/" in package["module"], package
        package["wheel_sha256"] = hashlib.sha256(wheel.read_bytes()).hexdigest()
        self.output.joinpath(f"{phase}-sdk.json").write_text(
            json.dumps(package, indent=2) + "\n"
        )
        return python

    def start_runners(self, python, phase):
        for role in ("writer", "reader"):
            env = self.env | {
                "QUAL_ROLE": role,
                "QUAL_PHASE": phase,
                "QUAL_NONCE": self.nonce,
                "SSL_CERT_FILE": str(self.workspace / "cert.pem"),
                "MONDEK_CONTROLLER_HEADERS_FILE": str(self.headers),
            }
            self.runners.append(
                subprocess.Popen(
                    [
                        str(python),
                        "-I",
                        "-m",
                        "mondek_runner",
                        "--consumer",
                        "packaged_state:app",
                        "--controller",
                        self.gateway_url,
                        "--state-dir",
                        str(self.workspace / role),
                    ],
                    cwd=self.workspace,
                    env=env,
                    stdout=self.log,
                    stderr=self.log,
                )
            )

    def stop_runners(self):
        for runner in self.runners:
            runner.terminate()
        for runner in self.runners:
            try:
                runner.wait(timeout=20)
            except subprocess.TimeoutExpired:
                runner.kill()
                runner.wait()
        self.runners.clear()

    def measurements(self, count, nonce=False, after=None):
        rows = self.read(f"/api/v1/results?source_id={SOURCE}")["data"]
        if len(rows) != count or any(
            r["current"].get("knowledge") != "fresh" for r in rows
        ):
            return False
        if after and any(
            datetime.fromisoformat(r["current"]["source_at"]) <= after for r in rows
        ):
            return False
        if (
            nonce
            and sum(
                r["current"].get("summary") == "Verified shared nonce " + self.nonce
                for r in rows
            )
            != 2
        ):
            return False
        return rows

    def identity(self, role):
        with sqlite3.connect(
            f"file:{self.workspace / role / 'runner.sqlite3'}?mode=ro", uri=True
        ) as db:
            meta = dict(db.execute("SELECT key, value FROM metadata"))
            assignments = [
                json.loads(row[0])
                for row in db.execute("SELECT payload FROM assignments")
            ]
        assignment = next(a for a in assignments if a["source_key"] == "state")
        return {
            "installation_id": meta["installation_id"],
            "session_id": meta["session_id"],
            "boot": int(meta["boot"]),
            "source_id": SOURCE,
            "assignment_id": assignment["id"],
            "generation": assignment["generation"],
        }

    def client(self, operation, key, **fields):
        payload = {
            "url": self.gateway_url,
            "identity": self.identity("reader"),
            "operation": operation,
            "key": key,
            **fields,
        }
        env = self.env | {
            "SSL_CERT_FILE": str(self.workspace / "cert.pem"),
            "MONDEK_CONTROLLER_HEADERS_FILE": str(self.headers),
        }
        return json.loads(
            self.run(
                str(self.python),
                "-I",
                "-c",
                CLIENT,
                capture=True,
                input=json.dumps(payload),
                env=env,
            )
        )

    def exercise(self):
        self.consumer = self.workspace / "consumer"
        self.consumer.mkdir()
        package = self.consumer / "src/packaged_state"
        package.mkdir(parents=True)
        (package / "__init__.py").write_text(CONSUMER)
        (self.consumer / "pyproject.toml").write_text(
            '[build-system]\nrequires=["uv_build==0.12.5"]\nbuild-backend="uv_build"\n'
            '[project]\nname="mondek-packaged-state-consumer"\nversion="0.1.0"\n'
            '[tool.uv.build-backend]\nmodule-name="packaged_state"\n'
        )
        self.run(
            "openssl",
            "req",
            "-x509",
            "-newkey",
            "rsa:2048",
            "-nodes",
            "-keyout",
            str(self.workspace / "key.pem"),
            "-out",
            str(self.workspace / "cert.pem"),
            "-days",
            "1",
            "-subj",
            "/CN=localhost",
            "-addext",
            "subjectAltName=DNS:localhost,IP:127.0.0.1",
        )
        self.token = "Bearer " + uuid.uuid4().hex
        self.gateway = Gateway(
            self.workspace / "cert.pem", self.workspace / "key.pem", self.token
        )
        threading.Thread(target=self.gateway.serve_forever, daemon=True).start()
        self.gateway_url = f"https://127.0.0.1:{self.gateway.server_port}"
        self.headers = self.workspace / "headers.json"
        self.headers.write_text(
            json.dumps(
                {"origin": self.gateway_url, "headers": {"Authorization": self.token}}
            )
        )
        self.headers.chmod(0o600)
        # Same production recipe as image installs; SMTP is an owned disposable sink.
        sys.path.insert(0, str(ROOT / "tests/deployment"))
        with patch.dict(os.environ, self.env, clear=True):
            import smtp_receiver

            smtp_receiver.STATE = smtp_receiver.State()
            smtp_receiver.TLS = None
        assert smtp_receiver.STATE.path is None
        self.smtp = smtp_receiver.SMTPServer(("0.0.0.0", 0), smtp_receiver.SMTP)
        threading.Thread(target=self.smtp.serve_forever, daemon=True).start()
        self.private = self.workspace / ".env"
        self.private.write_text(
            f"PGPASSWORD={uuid.uuid4().hex}\nSECRET_KEY_BASE={uuid.uuid4().hex * 3}\nMONDEK_DEPLOYMENT_MODE=true\nMONDEK_PUBLIC_URL={self.gateway_url}\nMONDEK_SMTP_HOST=host.docker.internal\nMONDEK_SMTP_PORT={self.smtp.server_address[1]}\nMONDEK_SMTP_TRANSPORT=plain\nMONDEK_SMTP_FROM=mondek@example.invalid\nMONDEK_SMTP_TO=operator@example.invalid\n"
        )
        self.private.chmod(0o600)
        self.env["MONDEK_ENV_FILE"] = str(self.private)
        self.overlay = self.workspace / "compose.yaml"
        self.overlay.write_text(
            'services:\n  controller:\n    ports: !override\n      - "127.0.0.1::4000"\n'
            + (
                '    extra_hosts:\n      - "host.docker.internal:host-gateway"\n'
                if sys.platform == "linux"
                else ""
            )
        )
        provenance = {
            "candidate_head": self.run(
                "git", "rev-parse", "HEAD", capture=True
            ).strip(),
            "candidate_controller_tree": self.run(
                "git", "rev-parse", "HEAD:controller", capture=True
            ).strip(),
            "candidate_runner_tree": self.run(
                "git", "rev-parse", "HEAD:runner", capture=True
            ).strip(),
            "working_tree_status": self.run(
                "git", "status", "--porcelain", capture=True
            ).splitlines(),
            "baseline_sdk_revision": self.run(
                "git", "rev-parse", self.baseline_ref, capture=True
            ).strip(),
        }
        self.output.joinpath("source-provenance.json").write_text(
            json.dumps(provenance, indent=2) + "\n"
        )
        old_python = self.install("baseline")
        self.python = self.install("candidate")
        self.env["MONDEK_IMAGE"] = self.images["baseline"]["id"]
        self.compose("pull", "postgres")
        self.compose(
            "up", "-d", "--wait", "--wait-timeout", "180", "--pull", "never", "postgres"
        )
        database_container = self.compose("ps", "-q", "postgres", capture=True).strip()
        self.switch("baseline")
        before_schema = self.schema()
        assert before_schema == {
            "versions": [1, 20261115150000],
            "state_table": None,
        }, before_schema
        self.start_runners(old_python, "baseline")
        rows = wait_for(
            "old SDK establishes both observers", lambda: self.measurements(2)
        )
        assignment = self.read(
            f"/api/v1/assignments/{rows[0]['assignment_id']}/configuration"
        )["data"]
        saved = urllib.request.Request(
            self.origin + f"/api/v1/assignments/{assignment['id']}/configuration",
            json.dumps(
                {"revision": assignment["revision"], "params": {"threshold": 7}}
            ).encode(),
            {"Content-Type": "application/json"},
            method="PUT",
        )
        with urllib.request.urlopen(saved, timeout=5) as response:
            assert response.status == 200
        wait_for(
            "saved threshold measured",
            lambda: any(
                r["current"].get("confirmed_generation") == 2
                for r in self.measurements(2) or []
            ),
        )
        wait_for("owned SMTP receiver", lambda: len(smtp_receiver.STATE.records) >= 2)
        assert all(
            r["to"] == "operator@example.invalid" for r in smtp_receiver.STATE.records
        )
        self.stop_runners()
        before = self.preserved()
        assert len(before["observations"]) >= 2 and len(before["incidents"]) == 2
        assert before["configuration_revisions"] and before["configuration_git_objects"]
        self.output.joinpath("before-upgrade.json").write_text(
            json.dumps(before, indent=2) + "\n"
        )
        self.compose("stop", "controller")
        self.switch("candidate", "upgrade")
        assert (
            self.compose("ps", "-q", "postgres", capture=True).strip()
            == database_container
        )
        after_schema = self.schema()
        assert after_schema == {
            "versions": [1, 20261115150000, *UPGRADE_MIGRATIONS],
            "state_table": "consumer_state_entries",
        }, after_schema
        assert (
            f"Database migrations complete: {len(UPGRADE_MIGRATIONS)} applied"
            in self.output.joinpath("upgrade-startup.log").read_text()
        )
        after = self.preserved()
        assert_preserved(before, after)
        self.output.joinpath("after-upgrade.json").write_text(
            json.dumps(after, indent=2) + "\n"
        )
        self.start_runners(self.python, "state")
        wait_for(
            "state-derived nonce measured over authenticated TLS",
            lambda: self.measurements(4, nonce=True),
        )
        self.stop_runners()
        first = self.client("get", "production/nonce/v1")["entry"]
        ttl = self.client(
            "put", "ttl-persist", value={"retained": self.nonce}, ttl_seconds=300
        )["entry"]
        state_before = self.sql(
            "SELECT coalesce(json_agg(t ORDER BY t.id), '[]') FROM consumer_state_entries t"
        )
        account_before = self.sql(
            "SELECT coalesce(json_agg(t ORDER BY t.source_id), '[]') FROM consumer_state_namespaces t"
        )
        # Authentication denial cannot forward or mutate the state endpoint.
        for auth in (None, "Bearer incorrect-test-token"):
            payload = {
                "version": 1,
                **self.identity("reader"),
                "scope": "source",
                "operation": "put",
                "key": "denied-write",
                "value": True,
            }
            headers = {"Content-Type": "application/json"}
            if auth:
                headers["Authorization"] = auth
            request = urllib.request.Request(
                self.gateway_url + "/api/v1/runner/state",
                json.dumps(payload).encode(),
                headers,
            )
            try:
                urllib.request.urlopen(
                    request,
                    context=ssl.create_default_context(
                        cafile=str(self.workspace / "cert.pem")
                    ),
                    timeout=5,
                )
            except urllib.error.HTTPError as error:
                assert error.code == 403
            else:
                raise AssertionError("Gateway admitted missing/invalid credentials")
        assert self.client("get", "denied-write")["entry"] is None
        self.compose("stop", "controller")
        self.switch("candidate", "restart")
        assert (
            "Database migrations complete: 0 applied"
            in self.output.joinpath("restart-startup.log").read_text()
        )
        assert self.schema() == after_schema
        state_after = self.sql(
            "SELECT coalesce(json_agg(t ORDER BY t.id), '[]') FROM consumer_state_entries t"
        )
        account_after = self.sql(
            "SELECT coalesce(json_agg(t ORDER BY t.source_id), '[]') FROM consumer_state_namespaces t"
        )
        assert state_after == state_before
        assert account_after == account_before
        self.output.joinpath("state-after-restart.json").write_text(
            json.dumps(state_after, indent=2) + "\n"
        )
        self.output.joinpath("accounting.json").write_text(
            json.dumps({"before": account_before, "after": account_after}, indent=2)
            + "\n"
        )
        nonce_after = self.client("get", "production/nonce/v1")["entry"]
        ttl_after = self.client("get", "ttl-persist")["entry"]
        assert nonce_after == first
        assert ttl_after == ttl
        self.output.joinpath("sdk-readback.json").write_text(
            json.dumps(
                {
                    "nonce_before": first,
                    "nonce_after": nonce_after,
                    "ttl_before": ttl,
                    "ttl_after": ttl_after,
                },
                indent=2,
            )
            + "\n"
        )
        assert (
            self.client(
                "cas",
                "production/nonce/v1",
                expected_version=first["version"],
                value={"nonce": self.nonce},
            )["entry"]["version"]
            != first["version"]
        )
        assert self.client(
            "cas", "production/nonce/v1", expected_version=first["version"], value=None
        ) == {"conflict": True}
        resumed_at = datetime.now(UTC)
        self.start_runners(self.python, "state")
        resumed = wait_for(
            "new-session post-restart state measurements",
            lambda: self.measurements(4, nonce=True, after=resumed_at),
        )
        self.output.joinpath("resumed-measurements.json").write_text(
            json.dumps(resumed, indent=2) + "\n"
        )
        self.stop_runners()
        records = list(self.gateway.records)
        assert (
            sum(
                r["path"] == "/api/v1/runner/state"
                and r["forwarded"]
                and r["status"] == 200
                for r in records
            )
            >= 6
        )
        assert (
            sum(
                r["path"] == "/api/v1/runner/state"
                and not r["allowed"]
                and r["status"] == 403
                for r in records
            )
            == 2
        )
        self.output.joinpath("gateway.json").write_text(
            json.dumps(records, indent=2) + "\n"
        )
        self.output.joinpath("state-before-restart.json").write_text(
            json.dumps(state_before, indent=2) + "\n"
        )
        return {
            "passed": True,
            "images": self.images,
            "baseline_ref": self.baseline_ref,
            "schema_before": before_schema,
            "schema_after": after_schema,
            "preserved_tables": {k: len(v) for k, v in before.items()},
            "state_entries_preserved": len(state_before),
            "gateway_state_success": True,
            "denied_state_mutations": 2,
            "post_restart_cas": True,
        }

    def cleanup(self):
        errors = []
        actions = [("runners", self.stop_runners)]
        if hasattr(self, "private"):
            actions += [
                (
                    "logs",
                    lambda: self.compose(
                        "logs", "--tail", "100", "controller", "postgres"
                    ),
                ),
                (
                    "compose",
                    lambda: self.compose("down", "--volumes", "--remove-orphans"),
                ),
            ]
        for name, server in (
            ("gateway", self.gateway),
            ("smtp", getattr(self, "smtp", None)),
        ):
            if server:
                actions += [
                    (name + " shutdown", server.shutdown),
                    (name + " close", server.server_close),
                ]
        for name, action in actions:
            try:
                action()
            except Exception as error:
                errors.append({"step": name, "error": type(error).__name__})
        return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--image", required=True, help="local candidate controller image; never pulled"
    )
    parser.add_argument(
        "--baseline-image",
        default="ghcr.io/pitkley/mondek/controller:0.0.4",
        help="local pre-state release image; never pulled",
    )
    parser.add_argument(
        "--baseline-ref",
        help="Git revision for the old SDK; defaults to baseline image revision label",
    )
    args = parser.parse_args()
    project = "mondek-state-packaged-" + uuid.uuid4().hex[:10]
    output = ROOT / ".local/acceptance" / project
    output.mkdir(parents=True)
    with (
        tempfile.TemporaryDirectory(prefix=project) as temporary,
        (output / "commands.log").open("w") as log,
    ):
        proof = Qualification(args, Path(temporary), output, log)
        result = {"passed": False}
        try:
            result = proof.exercise()
        finally:
            try:
                errors = proof.cleanup()
                result["cleanup"] = "failed" if errors else "complete"
                if errors:
                    result["cleanup_errors"] = errors
            finally:
                (output / "result.json").write_text(json.dumps(result, indent=2) + "\n")
                print("Packaged state qualification evidence:", output, flush=True)
    assert result["passed"] and result["cleanup"] == "complete", result
    print("PASS packaged state upgrade, restart and authenticated gateway")


if __name__ == "__main__":
    main()
