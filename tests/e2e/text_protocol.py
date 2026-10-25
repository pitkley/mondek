# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Real consumer worker output admitted by the packaged controller over HTTP."""

import json


SOURCE = r"""
from mondek_runner import App, Environment, check, ok

@check(id="summary", expected_keys=("first", "second"), timeout_seconds=3)
def summary():
    yield ok("first", "Original valid sibling")
    yield ok("second", "bad\x00summary")

@check(id="exception", expected_keys=("first", "second"), timeout_seconds=3)
def exception():
    yield ok("first", "Original valid sibling")
    raise ValueError("bad\x00\ud800diagnostic")

app = App(source_id="text-contract", environment=Environment("acceptance"),
          checks=[summary, exception])
"""

SCRIPT = r"""
import asyncio, json, os, tempfile, urllib.request, uuid
from pathlib import Path
from mondek_runner.api import timestamp
from mondek_runner.bundle import snapshot
from mondek_runner.runtime import execute

def post(path, body):
    request = urllib.request.Request("http://controller:4000/api/v1/" + path,
        json.dumps(body).encode(), {"Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=10) as response:
        return json.load(response)

async def main():
    with tempfile.TemporaryDirectory() as temp:
        root = Path(temp)
        package = root / "site" / "text_consumer"
        package.mkdir(parents=True)
        (package / "__init__.py").write_text(SOURCE)
        metadata = package.parent / "text_consumer-1.0.dist-info"
        metadata.mkdir()
        (metadata / "METADATA").write_text("Name: text-consumer\nVersion: 1.0\n")
        os.environ["PYTHONPATH"] = str(package.parent) + ":" + os.environ.get("PYTHONPATH", "")
        inventory = await snapshot("text_consumer:app", root / "bundles")
        identity = {"version": 1, "installation_id": str(uuid.uuid4()),
                    "session_id": str(uuid.uuid4()), "boot": 1}
        control = {**identity, "runner_label": "Text contract observer",
                   "prepared": {}, "active": {}, "wait_seconds": 0}
        post("control", control)
        publication = post("inventory", {**identity, **inventory,
            "complete": True, "inventory_revision": 1})
        assert publication["accepted_checks"] == 2
        assignments = post("control", control)["assignments"]
        assert len(assignments) == 2
        assert {a["source_key"] for a in assignments} == {"summary", "exception"}
        for assignment in assignments:
            prepared = await execute(assignment, prepare=True, bundle_dir=root / "bundles")
            assert prepared["prepared"], prepared
        generations = {a["id"]: a["generation"] for a in assignments}
        authorized = post("control", {**control, "prepared": generations})["authorized"]
        assert authorized == generations
        post("control", {**control, "prepared": generations, "active": generations})
        reports = []
        for assignment in assignments:
            started = timestamp()
            outcome = await execute(assignment, bundle_dir=root / "bundles")
            assert outcome["complete"] is False, outcome
            assert len(outcome["results"]) == 1, outcome
            assert outcome["results"][0]["key"] == "first"
            assert outcome["results"][0]["summary"] == "Original valid sibling"
            assert "\x00" not in outcome["diagnostic"]
            if assignment["source_key"] == "exception":
                assert r"bad\x00\ud800diagnostic" in outcome["diagnostic"]
            report = {"id": str(uuid.uuid4()), "installation_id": identity["installation_id"],
                "session_id": identity["session_id"], "assignment_id": assignment["id"],
                "generation": assignment["generation"], "sequence": 1,
                "started_at": started, "evaluated_at": timestamp(), **outcome}
            envelope = {**identity, "reports": [report]}
            accepted = post("observations", envelope)["dispositions"][0]
            assert accepted["disposition"] == "current", accepted
            replay = post("observations", envelope)["dispositions"][0]
            assert replay["disposition"] == "duplicate", replay
            reports.append(report)
        print(json.dumps(reports))

asyncio.run(main())
"""


class TextProtocolMixin:
    def text_protocol(self) -> dict:
        script = "SOURCE = " + repr(SOURCE) + "\n" + SCRIPT
        reports = json.loads(
            self.compose(
                "run",
                "--rm",
                "--no-deps",
                "runner",
                "python",
                "-c",
                script,
                capture=True,
            )
        )
        retained = {item["id"]: item for item in self.snapshot()["evidence"]}
        for report in reports:
            assert retained[report["id"]]["payload"] == report
        return {"reports": reports, "partial_reports_admitted": 2, "exact_replays": 2}
