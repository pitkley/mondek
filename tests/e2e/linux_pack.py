#!/usr/bin/env python3
# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Real installed pack workers, Linux evidence, controlled failures and recovery."""

from __future__ import annotations

import json
import time
from acceptance import Acceptance, run_compose
from parity_transport import ParityTransportMixin, exact_buffered_evidence

FIXTURE = """
import os, sys, shutil
from pathlib import Path
root = Path('/linux-work')
root.mkdir(exist_ok=True)
def write(name, value):
    p=root/name; p.parent.mkdir(parents=True, exist_ok=True); p.write_text(value)
mode=sys.argv[1]
dev=root.stat().st_dev
write('proc/1/mountinfo', f'1 0 {os.major(dev)}:{os.minor(dev)} / /other rw - ext4 test rw\\n' if mode == 'missing-mount' else f'1 0 {os.major(dev)}:{os.minor(dev)} / / rw - ext4 test rw\\n')
write('proc/meminfo', 'invalid' if mode == 'unavailable' else 'MemTotal: 1000 kB\\nMemAvailable: '+('10' if mode == 'critical' else '500')+' kB\\n')
write('proc/loadavg', '0.1 0.1 0.1 1/10 1\\n')
write('proc/stat', 'cpu 1 2 3 4\\ncpu0 1 2 3 4\\n')
write('sys/class/net/eth0/operstate', 'down' if mode == 'critical' else 'up')
with (root/'proc/1/mountinfo').open('a') as mounts:
    mounts.write('90 1 0:53 / /run/user/1000 rw - tmpfs tmpfs rw\\n')
    mounts.write('91 90 0:53 / /run/user/1000 rw - tmpfs tmpfs rw\\n')
    mounts.write('92 1 0:45 / /proc/sys/fs/binfmt_misc rw - autofs systemd-1 rw\\n')
    mounts.write('93 92 0:48 / /proc/sys/fs/binfmt_misc ro - binfmt_misc binfmt_misc rw\\n')
if mode in {'dynamic', 'dynamic-failure', 'discovery-broken'}:
    (root/'data').mkdir(exist_ok=True)
    with (root/'proc/1/mountinfo').open('a') as mounts:
        mounts.write(f'2 1 {os.major(dev)}:{os.minor(dev)} / /data rw - ext4 test rw\\n')
    write('sys/class/net/br-test/operstate', 'down' if mode == 'dynamic-failure' else 'up')
else:
    shutil.rmtree(root/'sys/class/net/br-test', ignore_errors=True)
if mode == 'discovery-broken':
    write('proc/1/mountinfo', 'invalid')
"""


class LinuxAcceptance(ParityTransportMixin, Acceptance):
    def __init__(self):
        super().__init__()
        self.env["MONDEK_BROWSER_ARTIFACTS"] = str(self.output / "browser")
        (self.output / "browser").mkdir()
        self.env.update(
            MONDEK_SPOOL_MAX_REPORTS="512",
            MONDEK_SPOOL_MAX_BYTES="2097152",
        )

    def compose(self, *args, capture=False, timeout=900):
        return run_compose(
            [
                "docker",
                "compose",
                "-p",
                self.project,
                "-f",
                "compose.yaml",
                "-f",
                "examples/compose/linux.yaml",
                "-f",
                "tests/browser/compose/linux.yaml",
                *args,
            ],
            env=self.env,
            log=self.log,
            capture=capture,
            timeout=timeout,
        )

    def mode(self, name):
        # Mutation touches only this test's disposable synthetic kernel files.
        self.compose(
            "run",
            "--rm",
            "--no-deps",
            "--user",
            "0",
            "--volume",
            f"{self.project}_linux_fixture:/linux-work",
            "linux-fixture-runner",
            "python",
            "-c",
            FIXTURE,
            name,
        )

    def rows(self):
        return self.request("/api/v1/checks?page_size=100")["items"]

    def fixture_rows(self):
        rows = self.rows()
        runner = next(
            row["runner_id"]
            for row in rows
            if row["target"]["key"] == "host:linux-fixture"
        )
        return [row for row in rows if row["runner_id"] == runner]

    def fixture_health(self, name, health):
        return any(
            name in row["check_label"]
            and row["current"].get("health") == health
            and row["current"].get("knowledge") == "fresh"
            for row in self.fixture_rows()
        )

    def run(self):
        success = False
        try:
            self.compose(
                "build", "runner", "linux-fixture-runner", "controller", "target"
            )
            self.mode("healthy")
            self.compose("up", "-d", "--wait", "--wait-timeout", "180")
            self.eventually(
                "baseline real worker measurements",
                lambda: (
                    len(self.rows()) >= 8
                    and all(
                        row["current"].get("knowledge") == "fresh"
                        for row in self.rows()
                    )
                ),
                timeout=180,
            )
            # Capacity is real Docker-host evidence. Keep this scenario's failure
            # and recovery assertions independent of unrelated host disk pressure,
            # including filesystems discovered later in the same installation.
            manifest = {
                "version": 1,
                "project": "linux-filesystem-acceptance",
                "rules": [
                    {
                        "key": "capacity-baseline",
                        "name": "Acceptance filesystem thresholds",
                        "source_id": "linux-pack-example",
                        "parameter_contract": "mondek.linux.filesystem.v1",
                        "params": {
                            "warning": 99,
                            "critical": 100,
                            "inode_warning": 99,
                            "inode_critical": 100,
                        },
                    }
                ],
            }
            review = self.request(
                "/api/v1/configuration/policy/plan", {"manifest": manifest}
            )
            self.request(
                "/api/v1/configuration/policy/apply",
                {
                    "manifest": manifest,
                    "review_token": review["review_token"],
                },
            )
            self.eventually(
                "reviewed filesystem baseline measured",
                lambda: all(
                    row["current"].get("health") == "OK"
                    for row in self.rows()
                    if row["check_label"].startswith("Filesystem")
                ),
            )
            before = {row["id"] for row in self.rows()}
            fixture_count = len(self.fixture_rows())
            self.mode("critical")
            self.eventually(
                "memory and link fail",
                lambda: (
                    self.fixture_health("memory", "CRIT")
                    and self.fixture_health("Interface", "CRIT")
                ),
            )
            self.mode("missing-mount")
            self.eventually(
                "expected mount remains critical",
                lambda: self.fixture_health("Filesystem", "CRIT"),
            )
            self.mode("unavailable")
            self.eventually(
                "invalid memory is unknown",
                lambda: any(
                    "memory" in row["check_label"]
                    and row["current"].get("knowledge") == "unavailable"
                    and row["current"].get("reported_health") == "UNKNOWN"
                    for row in self.fixture_rows()
                ),
            )
            self.mode("healthy")
            self.eventually(
                "measured recovery",
                lambda: (
                    len(self.fixture_rows()) == fixture_count
                    and all(
                        row["current"].get("health") == "OK"
                        for row in self.fixture_rows()
                    )
                ),
            )
            observations = {
                row["id"]: row["current"].get("observation_id") for row in self.rows()
            }
            self.compose("restart", "runner", "linux-fixture-runner")
            self.eventually(
                "restart preserves IDs and resumes measurements",
                lambda: (
                    {row["id"] for row in self.rows()} == before
                    and all(
                        row["current"].get("observation_id") != observations[row["id"]]
                        for row in self.rows()
                    )
                ),
            )
            installation = self.fixture_rows()[0]["runner_id"]
            self.request(
                "/mode", {"offline_installations": [installation]}, fixture=True
            )
            queued = self.eventually(
                "offline collection continues",
                lambda: (
                    sample
                    if (sample := self.node_journal("linux-fixture-runner"))["status"][
                        "queue_count"
                    ]
                    >= 4
                    else False
                ),
            )
            self.compose("restart", "linux-fixture-runner")
            self.request("/mode", {"offline_installations": []}, fixture=True)
            reports = queued["reports"]
            admitted = self.eventually(
                "buffered retry after restart",
                lambda: (
                    rows
                    if len(
                        rows := self.stored_reports([item["id"] for item in reports])
                    )
                    == len(reports)
                    else False
                ),
            )
            exact_buffered_evidence(reports, admitted)
            (self.output / "buffered-evidence.json").write_text(
                json.dumps({"reports": reports, "admitted": admitted}, indent=2)
            )
            self.eventually("notification delivery", lambda: bool(self.records()))
            self.dynamic_discovery()
            self.steps.append(
                {
                    "scenario": "native and fixture Linux checks: selection, failures, recovery, stable restart and delivery",
                    "passed": True,
                }
            )
            self.compose("--profile", "browser", "build", "browser")
            self.compose("run", "--rm", "--no-deps", "browser", timeout=300)
            # The browser saved shared exclusions. They must also match resources
            # first observed after the rule was saved, including after restart.
            baseline = {row["id"] for row in self.fixture_rows()}
            self.mode("dynamic")
            changed_at = time.monotonic()
            self.compose("restart", "linux-fixture-runner")
            self.eventually(
                "UI selection applies to future resources after restart",
                lambda: (
                    time.monotonic() - changed_at > 12
                    and {row["id"] for row in self.fixture_rows()} == baseline
                    and any(
                        row["check_label"] == "Linux resource discovery"
                        and row["current"].get("summary")
                        == "Linux discovery: 0 selected resources"
                        and row["current"].get("knowledge") == "fresh"
                        for row in self.fixture_rows()
                    )
                ),
                timeout=120,
            )
            self.steps.append(
                {
                    "scenario": "UI shared exclusions apply to future resources after restart",
                    "passed": True,
                }
            )
            success = True
        finally:
            self.finish(success)
            print(f"Evidence: {self.output}", flush=True)

    def dynamic_discovery(self):
        baseline = {row["id"] for row in self.fixture_rows()}
        self.mode("dynamic")
        self.eventually(
            "new mount and bridge automatically monitored",
            lambda: (
                self.fixture_health("Filesystem /data", "OK")
                and self.fixture_health("Interface br-test", "OK")
            ),
            timeout=120,
        )
        discovered = {
            row["id"] for row in self.fixture_rows() if row["id"] not in baseline
        }
        assert len(discovered) == 2
        self.mode("discovery-broken")
        failed_at = time.monotonic()
        self.eventually(
            "failed mount discovery is visible",
            lambda: any(
                "discovery" in row["check_label"].lower()
                and row["current"].get("knowledge") == "unavailable"
                for row in self.fixture_rows()
            ),
        )
        # More than a disappearance grace must not turn failed scans into absence.
        self.compose("restart", "linux-fixture-runner")
        self.eventually(
            "restart retains discovered inventory during failed discovery",
            lambda: (
                time.monotonic() - failed_at > 15
                and discovered.issubset({row["id"] for row in self.fixture_rows()})
            ),
        )
        self.mode("dynamic-failure")
        self.eventually(
            "discovered bridge produces a real failure",
            lambda: self.fixture_health("Interface br-test", "CRIT"),
        )
        bridge = next(
            row
            for row in self.fixture_rows()
            if row["check_label"] == "Interface br-test"
        )
        incident = self.eventually(
            "discovered bridge has an incident",
            lambda: next(
                (
                    item
                    for item in self.request("/api/v1/incidents")["items"]
                    if item.get("stream_id") == bridge["id"]
                ),
                None,
            ),
        )
        self.mode("healthy")
        self.eventually(
            "absent ephemeral resources retire after grace",
            lambda: {row["id"] for row in self.fixture_rows()} == baseline,
            timeout=120,
        )
        retired = self.request("/api/v1/checks?status=retired&page_size=100")["items"]
        assert discovered.issubset({row["id"] for row in retired})
        detail = self.request(f"/api/v1/incidents/{incident['id']}")
        assert detail["incident"]["closure_reason"] == "source_removed"
        assert detail["incident"]["closing_observation_id"] is None
        (self.output / "dynamic-retirement.json").write_text(
            json.dumps(retired, indent=2)
        )
        self.steps.append(
            {
                "scenario": "dynamic addition, failed scan retention, restart and retirement",
                "passed": True,
            }
        )


if __name__ == "__main__":
    LinuxAcceptance().run()
