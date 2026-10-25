#!/usr/bin/env python3
# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Run CI phases with shared immutable images and retain measured stage durations."""

from __future__ import annotations

import argparse
import json
import os
import shlex
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
IMAGES = {
    "controller": "controller/Dockerfile",
    "runner": "runner/Dockerfile",
    "fixture": "tests/fixtures/Dockerfile",
    "browser": "tests/browser/Dockerfile",
    "consumer": "examples/consumers/Dockerfile",
    "node": "tests/fixtures/Dockerfile.node",
    "fleet": "tests/browser/fleet/Dockerfile",
}
FULL_ACCEPTANCE = [
    "acceptance",
    "parity",
    "gateway",
    "placement",
    "consumers",
    "linux_pack",
    "starter",
    "durable_rules",
    "policy",
    "configuration_repository",
    "acknowledgements",
    "maintenance",
    "grouped",
    "coverage",
    "publishers",
]
BROWSER_SUITES = [
    "lifecycle",
    "diagnostics",
    "discovery",
    "monitoring-loss",
    "fleet",
    "empty",
    "parity",
    "bulk",
    "rules",
    "policy",
    "acknowledgements",
    "maintenance",
    "inventory",
    "check-groups",
    "grouped",
    "coverage",
    "publishers",
]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("phase", choices=["native", "images", "packaged"])
    parser.add_argument("--mode", choices=["smoke", "full", "browser"], default="smoke")
    parser.add_argument("--browser-suites", default="")
    args = parser.parse_args()
    selected = args.browser_suites.split() or BROWSER_SUITES
    if any(suite not in BROWSER_SUITES for suite in selected) or len(selected) != len(
        set(selected)
    ):
        parser.error(
            "browser suites must be unique names from: " + " ".join(BROWSER_SUITES)
        )
    if args.browser_suites and args.mode != "browser":
        parser.error("--browser-suites requires --mode browser")
    output = ROOT / ".local/ci"
    output.mkdir(parents=True, exist_ok=True)
    measurements: list[dict] = []
    phase_name = {
        "native": "Unit tests and checks",
        "packaged": "Integration and browser tests",
        "images": "Built test images",
    }[args.phase]

    def run(label: str, command: list[str]) -> None:
        start = time.monotonic()
        print(f"::group::{label}", flush=True)
        try:
            result = subprocess.run(command, cwd=ROOT, check=False)
            measurements.append(
                {
                    "stage": label,
                    "command": shlex.join(command),
                    "seconds": round(time.monotonic() - start, 2),
                    "returncode": result.returncode,
                }
            )
            (output / f"{args.phase}-timings.json").write_text(
                json.dumps(measurements, indent=2) + "\n"
            )
            if summary := os.environ.get("GITHUB_STEP_SUMMARY"):
                rows = [
                    f"| {item['stage']} | `{item['command'].replace('|', '&#124;')}` | {item['seconds']:.2f} | "
                    f"{'Pass' if item['returncode'] == 0 else 'Fail'} |"
                    for item in measurements
                ]
                Path(summary).write_text(
                    f"## {phase_name}\n\n"
                    "Excludes workflow setup and image builds.\n\n"
                    "| Stage | Command | Seconds | Result |\n| --- | --- | ---: | --- |\n"
                    + "\n".join(rows)
                    + f"\n\nTotal: {sum(item['seconds'] for item in measurements):.2f}s\n"
                    + "\nOpen the failed stage in the job log for command output. "
                    "Download the job evidence artifact for `.local/ci/` timings and image audits"
                    + (
                        ", `.local/acceptance/` service evidence and `.local/browser/` reports.\n"
                        if args.phase == "packaged"
                        else ".\n"
                    )
                )
            result.check_returncode()
        finally:
            print("::endgroup::", flush=True)

    if args.phase == "native":
        run("Unit and database tests", ["bash", "scripts/mondek", "test"])
        run("Code style, types and installed SDK", ["bash", "scripts/mondek", "check"])
        run(
            "Elixir dependency advisories",
            ["bash", "-c", "cd controller && mix hex.audit"],
        )
    elif args.phase == "images":
        manifest = {}
        for name, dockerfile in IMAGES.items():
            if args.mode == "smoke" and name in {"consumer", "node", "fleet"}:
                continue
            tag = f"mondek-ci/{name}:{os.environ['MONDEK_CI_REF']}"
            identity = subprocess.check_output(
                ["docker", "image", "inspect", "--format", "{{.Id}}", tag], text=True
            ).strip()
            manifest[dockerfile] = {"tag": tag, "id": identity}
        (output / "images.json").write_text(json.dumps(manifest, indent=2) + "\n")
    else:
        os.environ["MONDEK_CI_IMAGES"] = str(output / "images.json")
        os.environ["PYTHONPATH"] = str(ROOT / "runner")
        run(
            "runtime_licenses",
            [sys.executable, "scripts/runtime_licenses.py", "--check"],
        )
        images = json.loads((output / "images.json").read_text())
        for kind in ["controller", "runner"]:
            run(
                f"Exact {kind} image license audit",
                [
                    sys.executable,
                    "scripts/image_licenses.py",
                    kind,
                    images[f"{kind}/Dockerfile"]["id"],
                    "--output",
                    str(output / f"{kind}-licenses.json"),
                ],
            )
        acceptance = {
            "full": FULL_ACCEPTANCE,
            "smoke": ["acceptance", "gateway"],
            "browser": [],
        }[args.mode]
        browser = {
            "full": ["all"],
            "smoke": ["empty", "lifecycle"],
            "browser": selected,
        }[args.mode]
        suites = [
            (f"Real {name} acceptance", [sys.executable, f"tests/e2e/{name}.py"])
            for name in acceptance
        ] + [
            (
                f"Browser {suite}",
                [sys.executable, "tests/browser/run.py", "--suite", suite],
            )
            for suite in browser
        ]
        if args.mode in {"full", "smoke"}:
            suites.insert(
                0,
                (
                    "Installed image and SDK acceptance",
                    [
                        sys.executable,
                        "tests/e2e/install.py",
                        "--image",
                        images["controller/Dockerfile"]["id"],
                    ],
                ),
            )
        failures = []
        for label, command in suites:
            try:
                run(label, command)
            except subprocess.CalledProcessError:
                failures.append(label)
        if failures:
            raise SystemExit("Failed packaged suites: " + ", ".join(failures))


if __name__ == "__main__":
    main()
