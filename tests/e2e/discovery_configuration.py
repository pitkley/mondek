# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Real packaged operator journey: two hosts and three independent observers."""

import argparse
import json

from acceptance import Acceptance, run_compose

KERNEL = """import os,sys
from pathlib import Path
for host in ('a','b'):
    root=Path('/evidence')/host;root.mkdir(parents=True,exist_ok=True)
    def write(name, value):
        path=root/name;path.parent.mkdir(parents=True,exist_ok=True);path.write_text(value)
    dev=root.stat().st_dev
    write('proc/1/mountinfo', 'invalid' if host=='a' and sys.argv[1]=='broken' else f'1 0 {os.major(dev)}:{os.minor(dev)} / / rw - ext4 test rw\\n')
    write('sys/class/net/eth0/operstate','down\\n')
    write('sys/class/net/wlan0/operstate','up\\n')
"""


class DiscoveryConfigurationAcceptance(Acceptance):
    def __init__(self):
        super().__init__()
        self.env.update(
            MONDEK_SPOOL_MAX_REPORTS="512",
            MONDEK_SPOOL_MAX_BYTES="2097152",
            MONDEK_BROWSER_ARTIFACTS=str(self.output / "browser"),
        )
        (self.output / "browser").mkdir()

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
                "tests/browser/compose/base.yaml",
                "-f",
                "tests/browser/compose/discovery-configuration.yaml",
                *args,
            ],
            env=self.env,
            log=self.log,
            capture=capture,
            timeout=timeout,
        )

    def kernel(self, mode):
        self.compose(
            "run",
            "--rm",
            "--no-deps",
            "--user",
            "0",
            "--volume",
            f"{self.project}_discovery_evidence:/evidence",
            "runner",
            "python",
            "-c",
            KERNEL,
            mode,
        )

    def browser(self, phase):
        self.compose(
            "run",
            "--rm",
            "--no-deps",
            "-e",
            "MONDEK_DISCOVERY_PHASE=" + phase,
            "-e",
            "MONDEK_BROWSER_OUTPUT=/artifacts/" + phase,
            "browser",
            timeout=300,
        )
        self.steps.append({"scenario": phase, "passed": True})

    def preview(self):
        self.env["MONDEK_DISCOVERY_INTERVAL"] = "10"
        self.compose("build", "controller", "runner", "target", "browser")
        self.kernel("healthy")
        self.compose(
            "up",
            "-d",
            "--wait",
            "--wait-timeout",
            "180",
            "controller",
            "runner",
            "second-observer",
            "other-host",
        )
        self.eventually(
            "preview measurements",
            lambda: len(self.request("/api/v1/checks?page_size=100")["items"]) == 9,
            timeout=180,
        )
        self.browser("preview")
        details = {
            "url": self.base,
            "project": self.project,
            "evidence": str(self.output),
            "stop_command": (
                f"MONDEK_PORT={self.env['MONDEK_PORT']} "
                f"MONDEK_FIXTURE_PORT={self.env['MONDEK_FIXTURE_PORT']} "
                f"PGPORT={self.env['PGPORT']} docker compose -p {self.project} "
                "-f compose.yaml -f tests/browser/compose/base.yaml "
                "-f tests/browser/compose/discovery-configuration.yaml "
                "down --remove-orphans"
            ),
        }
        (self.output / "preview.json").write_text(json.dumps(details, indent=2))
        print(json.dumps(details), flush=True)
        self.log.close()

    def run(self):
        success = False
        try:
            self.compose("build", "controller", "runner", "target", "browser")
            self.kernel("healthy")
            self.compose(
                "up",
                "-d",
                "--wait",
                "--wait-timeout",
                "180",
                "controller",
                "runner",
                "second-observer",
                "other-host",
            )
            self.eventually(
                "all three observers provide fresh real measurements",
                lambda: (
                    len(rows := self.request("/api/v1/checks?page_size=100")["items"])
                    == 9
                    and all(row["current"].get("knowledge") == "fresh" for row in rows)
                ),
                timeout=180,
            )
            self.browser("operator")
            self.kernel("broken")
            self.browser("failure")
            self.kernel("healthy")
            self.compose("restart", "runner")
            self.browser("recovery")
            success = True
        finally:
            self.finish(success)
            print(f"Evidence: {self.output}", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--review",
        action="store_true",
        help="Keep an isolated local app running for manual review",
    )
    args = parser.parse_args()
    work = DiscoveryConfigurationAcceptance()
    if args.review:
        work.preview()
    else:
        work.run()
