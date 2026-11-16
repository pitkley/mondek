# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Real runner/worker/HTTP qualification, invoked by the native HTTP test."""

from __future__ import annotations

import json
import os
import socket
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from mondek_runner import StateWriteIndeterminate
from mondek_runner.consumer_state import _StateClient

CONSUMER = """
import os
from mondek_runner import App, CheckContext, Environment, Result, StateError, check, ok, unknown
from mondek_runner.api import timestamp

role = os.environ["STATE_TEST_ROLE"]

@check(id="peers", expected_keys=("peers",), interval_seconds=0.5, timeout_seconds=3, freshness_seconds=8)
def peers(ctx: CheckContext) -> Result:
    try:
        if ctx.state.get("crash-after-write") is not None:
            ctx.state.put("committed-before-crash", True)
            os._exit(7)
        if role == "writer":
            entry = ctx.state.put("production/peers/v1", {"peers": ["node-a"], "acquired_at": timestamp()})
        else:
            entry = ctx.state.get("production/peers/v1")
        local = ctx.state.for_check().get("role")
        if local is not None and local.value != role:
            return unknown("peers", "Assignment state leaked between observers")
        ctx.state.for_check().put("role", role)
        if entry is None:
            return unknown("peers", "Peer list not published yet")
        return ok("peers", "Shared peer list available", source_at=entry.value["acquired_at"])
    except StateError:
        return unknown("peers", "Controller state unavailable")

@check(id="stateless", expected_keys=("health",), interval_seconds=0.5, timeout_seconds=3, freshness_seconds=8)
def stateless() -> Result:
    return ok("health", "Stateless execution continues")

app = App(source_id="state-http-acceptance", environment=Environment("production"), checks=[peers, stateless], construction_environment={"STATE_TEST_ROLE": role})
"""


def request(url, payload=None):
    raw = None if payload is None else json.dumps(payload).encode()
    req = urllib.request.Request(url, raw, {"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=5) as response:
        return json.load(response)


def wait_for(predicate, description):
    deadline = time.monotonic() + 35
    while time.monotonic() < deadline:
        result = predicate()
        if result:
            return result
        time.sleep(0.1)
    raise AssertionError(f"Timed out: {description}")


def main():
    origin = sys.argv[1]
    mode = {"state_fail": False, "drop_next": False}

    class Proxy(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_POST(self):
            body = self.rfile.read(int(self.headers["Content-Length"]))
            if self.path == "/api/v1/runner/state" and mode["state_fail"]:
                self.send_error(503)
                return
            upstream = urllib.request.Request(
                origin + self.path, body, {"Content-Type": "application/json"}
            )
            try:
                with urllib.request.urlopen(upstream, timeout=5) as response:
                    status, raw = response.status, response.read()
            except urllib.error.HTTPError as error:
                status, raw = error.code, error.read()
            if (
                self.path == "/api/v1/runner/state"
                and mode["drop_next"]
                and json.loads(body).get("key") == "lost-reply"
            ):
                mode["drop_next"] = False
                self.close_connection = True
                self.connection.shutdown(socket.SHUT_RDWR)
                return
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)

    proxy = ThreadingHTTPServer(("127.0.0.1", 0), Proxy)
    thread = threading.Thread(target=proxy.serve_forever, daemon=True)
    thread.start()
    url = f"http://127.0.0.1:{proxy.server_port}"
    processes = []
    logs = []
    with tempfile.TemporaryDirectory(prefix="mondek-state-http-") as directory:
        root = Path(directory)
        (root / "state_consumer.py").write_text(CONSUMER)
        try:
            for role in ("writer", "reader"):
                log = (root / f"{role}.log").open("w+")
                logs.append(log)
                env = {
                    **os.environ,
                    "PYTHONPATH": str(root),
                    "MONDEK_CONSUMER": "state_consumer:app",
                    "MONDEK_CONTROLLER_URL": url,
                    "MONDEK_STATE_DIR": str(root / role),
                    "STATE_TEST_ROLE": role,
                }
                processes.append(
                    subprocess.Popen(
                        [sys.executable, "-m", "mondek_runner"],
                        cwd=root,
                        env=env,
                        stdout=log,
                        stderr=log,
                        start_new_session=True,
                    )
                )

            def results():
                return request(
                    origin + "/api/v1/results?source_id=state-http-acceptance"
                )["data"]

            wait_for(
                lambda: (
                    len(results()) == 4
                    and all(
                        r["current"].get("knowledge") == "fresh"
                        and r["current"].get("health") == "OK"
                        for r in results()
                    )
                ),
                "both real runners measure shared state",
            )
            rows = request(
                origin + "/api/v1/consumer-state?source_id=state-http-acceptance"
            )["data"]
            assert len(rows) == 3, rows
            assert len({r["scope"] for r in rows if r["scope"] != "source"}) == 2

            # The identity is read from this task's journal without opening another session.
            with sqlite3.connect(
                f"file:{root / 'reader/runner.sqlite3'}?mode=ro", uri=True
            ) as db:
                meta = dict(db.execute("SELECT key,value FROM metadata"))
                assignments = [
                    json.loads(row[0])
                    for row in db.execute("SELECT payload FROM assignments")
                ]
            assignment = next(a for a in assignments if a["source_key"] == "peers")
            identity = {
                "installation_id": meta["installation_id"],
                "session_id": meta["session_id"],
                "boot": int(meta["boot"]),
                "source_id": assignment["source_id"],
                "assignment_id": assignment["id"],
                "generation": assignment["generation"],
            }
            client = _StateClient(url, identity, deadline=time.monotonic() + 60)
            mode["drop_next"] = True
            try:
                client.put("lost-reply", {"committed": True})
            except StateWriteIndeterminate:
                pass
            else:
                raise AssertionError(
                    "Dropped mutation reply did not surface as indeterminate"
                )
            assert client.get("lost-reply").value == {"committed": True}

            mode["state_fail"] = True
            wait_for(
                lambda: all(
                    r["current"].get("knowledge") == "unavailable"
                    for r in results()
                    if r["result_key"] == "peers"
                ),
                "state outage produces UNKNOWN",
            )
            assert all(
                r["current"]["knowledge"] == "fresh"
                for r in results()
                if r["result_key"] == "health"
            )
            mode["state_fail"] = False
            wait_for(
                lambda: all(
                    r["current"].get("knowledge") == "fresh" for r in results()
                ),
                "state recovers without runner restart",
            )
            client.put("crash-after-write", True)
            wait_for(
                lambda: client.get("committed-before-crash") is not None,
                "worker commits state before crashing",
            )
            wait_for(
                lambda: all(
                    r["current"].get("knowledge") == "unavailable"
                    for r in results()
                    if r["result_key"] == "peers"
                ),
                "worker crash does not manufacture a measurement",
            )
            client.delete("crash-after-write")
            wait_for(
                lambda: all(
                    r["current"].get("knowledge") == "fresh" for r in results()
                ),
                "recovery after worker crash",
            )
            print(
                "Two real runners shared state; assignment isolation, committed lost reply, outage and recovery passed."
            )
        except BaseException:
            for log in logs:
                log.flush()
                log.seek(0)
                print(log.read()[-10000:], file=sys.stderr)
            raise
        finally:
            import signal

            for process in processes:
                os.killpg(process.pid, signal.SIGCONT)
                process.terminate()
            for process in processes:
                try:
                    process.wait(timeout=8)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
            for log in logs:
                log.close()
            proxy.shutdown()
            proxy.server_close()


if __name__ == "__main__":
    main()
