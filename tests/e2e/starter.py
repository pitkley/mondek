#!/usr/bin/env python3
# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Generate/install a real consumer and exercise it against isolated Docker services."""

from __future__ import annotations

import json
import os
import signal
import subprocess

from acceptance import ROOT, Acceptance


class StarterAcceptance(Acceptance):
    def __init__(self) -> None:
        super().__init__()
        self.env.update(MONDEK_CONSUMER="")
        self.consumer = self.output / "my-monitoring"
        self.state = self.consumer / ".mondek-state"
        self.process: subprocess.Popen | None = None
        self.runner_log = (self.output / "runner.log").open("w")
        self.check_id = ""
        self.installation_id = ""

    def command(self, *arguments: str) -> str:
        result = subprocess.run(
            arguments,
            cwd=ROOT,
            env=self.env,
            check=True,
            stdout=subprocess.PIPE,
            stderr=self.log,
            text=True,
            timeout=120,
        )
        return result.stdout

    def consumer_run(self, *arguments: str) -> str:
        return self.command(
            "uv", "run", "--directory", str(self.consumer), "--locked", *arguments
        )

    def start_runner(self) -> None:
        assert self.process is None
        self.process = subprocess.Popen(
            [
                "uv",
                "run",
                "--directory",
                str(self.consumer),
                "--locked",
                "mondek-runner",
                "--consumer",
                "monitoring.app:app",
                "--state-dir",
                str(self.state),
            ],
            cwd=ROOT,
            env=self.env | {"MONDEK_CONTROLLER_URL": self.base},
            stdout=self.runner_log,
            stderr=self.runner_log,
            start_new_session=True,
        )

    def stop_runner(self) -> None:
        if self.process is not None:
            if self.process.poll() is None:
                os.killpg(self.process.pid, signal.SIGTERM)
                try:
                    self.process.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    os.killpg(self.process.pid, signal.SIGKILL)
                    self.process.wait(timeout=5)
            self.process = None

    def journal(self) -> dict:
        script = """
import json, sqlite3, sys
connection = sqlite3.connect('file:' + sys.argv[1] + '/runner.sqlite3?mode=ro', uri=True)
connection.execute('BEGIN')
metadata = dict(connection.execute('SELECT key,value FROM metadata'))
reports = [json.loads(row[0]) for row in connection.execute('SELECT payload FROM spool')]
print(json.dumps({'metadata': metadata, 'reports': reports}))
connection.close()
"""
        return json.loads(self.command("python3", "-c", script, str(self.state)))

    def measured(self, health: str = "OK") -> dict | bool:
        assignment = self.assignment(self.check_id)
        current = assignment["current"]
        return (
            assignment
            if current["knowledge"] == "fresh"
            and current["health"] == health
            and assignment["observed_generation"] == assignment["desired_generation"]
            else False
        )

    def generate(self) -> dict:
        self.compose("up", "--build", "--detach", "--wait", "controller")
        assert self.snapshot()["assignments"] == []
        self.command(
            "uv",
            "run",
            "--project",
            "runner",
            "--locked",
            "mondek-runner",
            "init",
            str(self.consumer),
            "--sdk-path",
            str(ROOT / "runner"),
        )
        self.command("uv", "sync", "--project", str(self.consumer))
        assert (self.consumer / "uv.lock").is_file()
        self.consumer_run(
            "python", "-m", "unittest", "discover", "-s", str(self.consumer / "tests")
        )
        validation = json.loads(
            self.consumer_run(
                "mondek-runner", "validate", "--consumer", "monitoring.app:app"
            )
        )
        local_run = json.loads(
            self.consumer_run(
                "mondek-runner",
                "run",
                "--consumer",
                "monitoring.app:app",
                "--all",
                "--results",
            )
        )
        assert local_run["complete"]
        assert self.snapshot()["assignments"] == [], "Local execution registered checks"
        (self.output / "local-validation.json").write_text(
            json.dumps(validation, indent=2)
        )
        (self.output / "local-run.json").write_text(json.dumps(local_run, indent=2))
        self.start_runner()
        assignments = self.eventually(
            "generated project publishes its own check",
            lambda: self.snapshot()["assignments"],
        )
        assert len(assignments) == 1
        self.check_id = assignments[0]["id"]
        self.eventually("generated check measures fresh health", self.measured)
        self.installation_id = self.snapshot()["runners"][0]["id"]
        return {"check_id": self.check_id, "installation_id": self.installation_id}

    def input_cycle(self) -> dict:
        sample = self.consumer / "sample-backlog.txt"
        sample.write_text("10\n")
        self.eventually(
            "custom Python policy reports critical backlog",
            lambda: self.measured("CRIT"),
        )
        incident = self.eventually(
            "critical result opens an incident", lambda: self.incident(self.check_id)
        )
        self.eventually(
            "real local notification arrives",
            lambda: any(
                record["payload"].get("incident_id") == incident["id"]
                and record["payload"].get("kind") == "firing"
                for record in self.records()
            ),
        )
        sample.unlink()
        self.eventually(
            "missing private input is unavailable, not retired",
            lambda: (
                self.assignment(self.check_id)["current"]["knowledge"] == "unavailable"
            ),
        )
        assert not self.assignment(self.check_id)["retired_at"]
        assert self.incident(self.check_id)["id"] == incident["id"]
        sample.write_text("0\n")
        self.eventually("repair yields measured recovery", self.measured)
        closed = self.request(f"/api/v1/incidents/{incident['id']}")["incident"]
        assert closed["closure_reason"] == "measured_recovery"
        return {"recovered_incident": incident["id"]}

    def configuration_and_reconnect(self) -> dict:
        assignment = self.assignment(self.check_id)
        params = {"warning_items": 15, "critical_items": 20}
        self.request(
            f"/api/v1/assignments/{self.check_id}",
            {"revision": assignment["revision"], "params": params},
            method="PUT",
        )
        self.eventually("delegated limits measured by custom function", self.measured)
        (self.consumer / "sample-backlog.txt").write_text("10\n")
        before = self.assignment(self.check_id)["current"]["observation_id"]
        self.eventually(
            "ten items now healthy under edited limits",
            lambda: (
                (row := self.measured())
                and row["current"]["observation_id"] != before
                and row["current"]["summary"] == "10 pending items"
            ),
        )
        self.compose("stop", "controller")
        buffered = self.eventually(
            "schedule collects while controller stopped",
            lambda: (sample := self.journal())["reports"] and sample,
        )
        originals = {report["id"]: report for report in buffered["reports"]}
        self.compose("up", "--detach", "--wait", "controller")
        self.eventually(
            "buffered evidence keeps its exact original contents",
            lambda: any(
                item["id"] in originals and item["payload"] == originals[item["id"]]
                for item in self.snapshot()["evidence"]
            ),
        )
        self.stop_runner()
        previous = self.snapshot()["runners"][0]["session_id"]
        self.start_runner()
        self.eventually(
            "same installation reconnects with new session",
            lambda: (
                (runners := self.snapshot()["runners"])
                and len(runners) == 1
                and runners[0]["id"] == self.installation_id
                and runners[0]["session_id"] != previous
            ),
        )
        self.eventually(
            "restart retains edited limits and healthy collection", self.measured
        )
        assert self.assignment(self.check_id)["params"] == params
        return {"params": params, "original_buffered_ids": list(originals)}

    def source_lifecycle(self) -> dict:
        (self.consumer / "sample-backlog.txt").write_text("25\n")
        self.eventually(
            "new source incident is critical", lambda: self.measured("CRIT")
        )
        incident = self.eventually(
            "new incident opens", lambda: self.incident(self.check_id)
        )
        self.stop_runner()
        module = self.consumer / "src" / "monitoring" / "app.py"
        original = module.read_text()
        module.write_text(
            original + "\nraise RuntimeError('broken replacement import')\n"
        )
        self.start_runner()
        previous_sequence = self.assignment(self.check_id)["last_sequence"]
        self.eventually(
            "broken replacement still executes accepted code",
            lambda: (
                (row := self.measured("CRIT"))
                and row["last_sequence"] > previous_sequence
            ),
        )
        assert not self.assignment(self.check_id)["retired_at"]
        self.stop_runner()
        module.write_text(
            original
            + '\napp = App(source_id="my-monitoring", environment=Environment("node-a", "Node A"), checks=[])\n'
        )
        self.start_runner()
        self.eventually(
            "complete empty source inventory retires monitoring",
            lambda: self.assignment(self.check_id)["retired_at"],
        )
        closed = self.request(f"/api/v1/incidents/{incident['id']}")["incident"]
        assert closed["closure_reason"] == "source_removed"
        assert closed["closing_observation_id"] is None
        retired = self.request("/api/v1/checks?status=retired")["items"]
        assert len(retired) == 1
        old_stream = retired[0]["id"]
        self.stop_runner()
        module.write_text(original)
        (self.consumer / "sample-backlog.txt").write_text("0\n")
        self.start_runner()
        active = self.eventually(
            "restored source has fresh result incarnation",
            lambda: (
                (rows := self.request("/api/v1/checks")["items"])
                and len(rows) == 1
                and rows[0]["id"] != old_stream
                and rows[0]["current"]["knowledge"] == "fresh"
                and rows
            ),
        )
        assert (
            self.request(f"/api/v1/incidents/{incident['id']}")["incident"][
                "closure_reason"
            ]
            == "source_removed"
        )
        return {
            "removed_incident": incident["id"],
            "retired_result": old_stream,
            "restored_result": active[0]["id"],
        }

    def run(self) -> None:
        success = False
        try:
            for label, function in [
                (
                    "empty controller, generated install, local tests and published coverage",
                    self.generate,
                ),
                (
                    "custom policy failure, missing input, local delivery and recovery",
                    self.input_cycle,
                ),
                (
                    "delegated limits, exact buffered replay and stable runner restart",
                    self.configuration_and_reconnect,
                ),
                (
                    "broken import, intentional removal and retained incident history",
                    self.source_lifecycle,
                ),
            ]:
                self.run_step(label, function)
            success = True
        finally:
            self.stop_runner()
            self.runner_log.close()
            self.finish(success)
            print(f"Starter evidence: {self.output}", flush=True)
        assert success


if __name__ == "__main__":
    StarterAcceptance().run()
