#!/usr/bin/env python3
# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Run browser journeys on fresh packaged installations; clean up only our projects."""

from __future__ import annotations

import argparse
import json
import os
import signal
import subprocess
import sys
import time
import uuid
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def wait_for_scale_fixture(controller: str, expected: int, output: Path) -> None:
    """Establish real measured fixtures before spending the UI journey budget."""
    started = time.monotonic()
    deadline = started + 240
    evidence: dict = {
        "expected": expected,
        "timeout_seconds": 240,
        "passed": False,
        "samples": [],
    }
    try:
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError(
                    f"scale fixture did not establish {expected} fresh results in 240s"
                )
            try:
                with urllib.request.urlopen(
                    f"http://{controller}/api/v1/runners", timeout=min(5, remaining)
                ) as response:
                    coverage = json.load(response)["counts"]["coverage"]
                evidence["samples"].append(
                    {"seconds": round(time.monotonic() - started, 2), **coverage}
                )
                if (
                    coverage["expected_count"] == expected
                    and coverage["fresh"] == expected
                    and time.monotonic() <= deadline
                ):
                    evidence["passed"] = True
                    return
            except (OSError, ValueError, KeyError) as error:
                evidence["last_error"] = str(error)
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError(
                    f"scale fixture did not establish {expected} fresh results in 240s"
                )
            time.sleep(min(5, remaining))
    finally:
        evidence["seconds"] = round(time.monotonic() - started, 2)
        (output / "scale-fixture-readiness.json").write_text(
            json.dumps(evidence, indent=2) + "\n"
        )


def run_suite(suite: str) -> bool:
    sys.path.insert(0, str(ROOT / "tests/e2e"))
    from ci_images import run_compose

    project = f"mondek-browser-{suite}-{uuid.uuid4().hex[:10]}"
    output = ROOT / ".local" / "browser" / project
    output.mkdir(parents=True)
    env = os.environ | {
        "MONDEK_BROWSER_SUITE": suite,
        "MONDEK_BROWSER_ARTIFACTS": str(output),
        "MONDEK_CONSUMER": ""
        if suite
        in {
            "empty",
            "bulk",
            "rules",
            "policy",
            "inventory",
            "check-groups",
            "grouped",
            "coverage",
            "publishers",
            "fleet",
        }
        else "demo_checks.app:app",
        "COMPOSE_PROFILES": "",
    }
    helper = Path("/Applications/Docker.app/Contents/Resources/bin")
    if suite == "check-groups":
        env["MONDEK_GROUPS_PHASE"] = "initial"
    if helper.is_dir():
        env["PATH"] = env.get("PATH", "") + os.pathsep + str(helper)
    command = [
        "docker",
        "compose",
        "-p",
        project,
        "-f",
        "compose.yaml",
    ]
    if suite in {"parity", "bulk"}:
        command.extend(["-f", "examples/compose/parity.yaml"])
    elif suite in {"rules", "policy"}:
        command.extend(["-f", "examples/compose/rules.yaml"])
    elif suite == "grouped":
        command.extend(["-f", "examples/compose/grouped.yaml"])
    elif suite in {"coverage", "publishers"}:
        command.extend(["-f", "examples/compose/coverage.yaml"])
        if suite == "publishers":
            command.extend(["-f", "examples/compose/publishers.yaml"])
    command.extend(["-f", "tests/browser/compose/base.yaml"])
    if suite == "parity":
        command.extend(["-f", "tests/browser/compose/scale.yaml"])
    if suite == "inventory":
        command.extend(["-f", "tests/browser/compose/inventory.yaml"])
    elif suite == "check-groups":
        command.extend(["-f", "tests/browser/compose/check-groups.yaml"])
    elif suite == "monitoring-loss":
        command.extend(["-f", "tests/browser/compose/monitoring-loss.yaml"])
    elif suite == "fleet":
        command.extend(["-f", "tests/browser/compose/fleet.yaml"])
    elif suite == "discovery":
        command.extend(["-f", "tests/browser/compose/discovery.yaml"])
    elif suite == "diagnostics":
        command.extend(["-f", "tests/browser/compose/diagnostics.yaml"])
    elif suite == "grouped":
        command.extend(["-f", "tests/browser/compose/grouped.yaml"])
    elif suite in {"coverage", "publishers"}:
        command.extend(["-f", "tests/browser/compose/coverage.yaml"])
    if suite == "parity":
        command.extend(["--profile", "capacity"])
    elif suite == "bulk":
        command.extend(["--profile", "bulk"])
    print(f"Browser {suite}: {project}; artifacts: {output}", flush=True)
    summary = {
        "project": project,
        "suite": suite,
        "started_at": datetime.now(timezone.utc).isoformat(),
        "passed": False,
        "cleanup_succeeded": False,
    }
    interrupted = False
    with (output / "compose.log").open("w") as log:

        def compose(*args: str, timeout: int = 900, capture: bool = False) -> str:
            return run_compose(
                command + list(args),
                log=log,
                env=env,
                capture=capture,
                timeout=timeout,
            )

        try:
            # Build once per suite, using shared immutable Docker layers on repeats.
            build_services = (
                ["controller", "target", "bulk-runner", "capacity-files", "browser"]
                if suite == "bulk"
                else [
                    "controller",
                    "target",
                    "rules-a-runner",
                    "rules-b-runner",
                    "browser",
                ]
                if suite in {"rules", "policy"}
                else [
                    "controller",
                    "target",
                    "grouped-volume",
                    "grouped-elasticsearch",
                    "browser",
                ]
                if suite == "grouped"
                else [
                    "controller",
                    "target",
                    "coverage-node-a",
                    "coverage-service-a",
                    "coverage-service-b",
                    "browser",
                ]
                if suite in {"coverage", "publishers"}
                else ["controller", "target", "inventory-a", "inventory-b", "browser"]
                if suite == "inventory"
                else ["controller", "target", "groups-a", "groups-b", "browser"]
                if suite == "check-groups"
                else ["controller", "target", "fleet-runner", "browser"]
                if suite == "fleet"
                else []
            )
            compose("--profile", "browser", "build", *build_services)
            start_services = (
                ["controller"]
                if suite == "empty"
                else ["bulk-runner"]
                if suite == "bulk"
                else ["rules-a-runner", "rules-b-runner"]
                if suite in {"rules", "policy"}
                else ["grouped-volume", "grouped-elasticsearch"]
                if suite == "grouped"
                else ["coverage-node-a", "coverage-service-a", "coverage-service-b"]
                if suite in {"coverage", "publishers"}
                else ["inventory-a", "inventory-b"]
                if suite == "inventory"
                else ["groups-a", "groups-b"]
                if suite == "check-groups"
                else ["fleet-runner"]
                if suite == "fleet"
                else []
            )
            compose(
                "up",
                "--detach",
                "--wait",
                "--wait-timeout",
                "180",
                *start_services,
                timeout=240,
            )
            summary["ports"] = {
                name: compose("port", name, str(port), capture=True).strip()
                for name, port in [
                    ("controller", 4000),
                    ("target", 8080),
                    ("postgres", 5432),
                ]
            }
            print(f"  Live UI: http://{summary['ports']['controller']}", flush=True)
            if suite in {"parity", "bulk"}:
                wait_for_scale_fixture(
                    summary["ports"]["controller"],
                    511 if suite == "parity" else 500,
                    output,
                )
            if suite == "check-groups":
                compose(
                    "run",
                    "--rm",
                    "--no-deps",
                    "-e",
                    "MONDEK_BROWSER_PHASE=initial",
                    "browser",
                    timeout=600,
                )
                # Source-declared metadata changes are published by the real
                # installed runners, retaining their durable installation IDs.
                env["MONDEK_GROUPS_PHASE"] = "renamed"
                compose(
                    "up",
                    "--detach",
                    "--wait",
                    "--force-recreate",
                    "--no-deps",
                    "groups-a",
                    "groups-b",
                    timeout=120,
                )
                compose(
                    "run",
                    "--rm",
                    "--no-deps",
                    "-e",
                    "MONDEK_BROWSER_PHASE=renamed",
                    "-e",
                    "MONDEK_BROWSER_OUTPUT=/artifacts/regrouped",
                    "browser",
                    timeout=600,
                )
                summary["regrouped_report"] = "regrouped/report/index.html"
            elif suite == "monitoring-loss":
                compose(
                    "run",
                    "--rm",
                    "--no-deps",
                    "-e",
                    "MONDEK_BROWSER_PHASE=before-restart",
                    "browser",
                    timeout=600,
                )
                # Chromium shares the controller's network namespace. Exit it
                # before restarting that container, then open a fresh browser.
                compose("restart", "--no-deps", "controller", timeout=60)
                compose(
                    "up",
                    "--detach",
                    "--wait",
                    "--wait-timeout",
                    "90",
                    "controller",
                    timeout=120,
                )
                # Docker may assign a new ephemeral published port on restart.
                # Keep the original mapping for evidence and export from the
                # restarted service's actual address during final collection.
                summary["ports_before_restart"] = dict(summary["ports"])
                summary["ports"] = {
                    name: compose("port", name, str(port), capture=True).strip()
                    for name, port in [
                        ("controller", 4000),
                        ("target", 8080),
                        ("postgres", 5432),
                    ]
                }
                summary["controller_restarted_at"] = datetime.now(
                    timezone.utc
                ).isoformat()
                print(
                    f"  Restarted UI: http://{summary['ports']['controller']}",
                    flush=True,
                )
                compose(
                    "run",
                    "--rm",
                    "--no-deps",
                    "-e",
                    "MONDEK_BROWSER_PHASE=after-restart",
                    "-e",
                    "MONDEK_BROWSER_OUTPUT=/artifacts/restart",
                    "-e",
                    "MONDEK_BROWSER_RESTART_STATE=/artifacts/controller-restart.json",
                    "browser",
                    timeout=300,
                )
                summary["restart_report"] = "restart/report/index.html"
            else:
                compose(
                    "run",
                    "--rm",
                    "--no-deps",
                    "browser",
                    timeout=1200 if suite in {"bulk", "fleet"} else 600,
                )
            summary["passed"] = True
        except KeyboardInterrupt:
            summary["error"] = "Interrupted"
            interrupted = True
        except (subprocess.SubprocessError, OSError) as error:
            summary["error"] = str(error)
            print(f"  Browser {suite} failed: {error}", file=sys.stderr, flush=True)
        finally:
            if summary.get("ports", {}).get("controller"):
                for resource, endpoint in (
                    ("snapshot", "snapshot"),
                    ("overview", "overview"),
                    ("runners", "runners"),
                    ("monitoring-incidents", "monitoring-incidents?status=all"),
                ):
                    try:
                        url = (
                            f"http://{summary['ports']['controller']}/api/v1/{endpoint}"
                        )
                        with urllib.request.urlopen(url, timeout=5) as response:
                            (output / f"{resource}.json").write_bytes(response.read())
                    except (OSError, ValueError) as error:
                        summary[f"{resource}_error"] = str(error)
            try:
                (output / "services.log").write_text(
                    compose(
                        "logs", "--no-color", "--tail", "500", capture=True, timeout=30
                    )
                )
                if suite == "fleet":
                    # Retain enough bounded controller history to investigate
                    # failures that occur during the earlier scale-up phase.
                    controller_log = compose(
                        "logs",
                        "--no-color",
                        "--tail",
                        "20000",
                        "controller",
                        capture=True,
                        timeout=30,
                    )
                    (output / "controller.log").write_text(controller_log)
                    if not controller_log.strip():
                        summary["passed"] = False
                        summary["controller_error"] = (
                            "Required fleet controller log is empty"
                        )
                    elif (
                        "Sent 500" in controller_log
                        or "deadlock_detected" in controller_log
                    ):
                        summary["passed"] = False
                        summary["controller_error"] = (
                            "Controller returned HTTP 500 or reported a deadlock; "
                            "see controller.log"
                        )
            except (subprocess.SubprocessError, OSError) as error:
                summary["log_error"] = str(error)
                if suite == "fleet":
                    summary["passed"] = False
                    summary["controller_error"] = (
                        "Required fleet controller log capture failed"
                    )
            try:
                compose(
                    "--profile",
                    "browser",
                    "down",
                    "--volumes",
                    "--remove-orphans",
                    timeout=90,
                )
                summary["cleanup_succeeded"] = True
            except (subprocess.SubprocessError, OSError) as error:
                summary["cleanup_error"] = str(error)
            summary["finished_at"] = datetime.now(timezone.utc).isoformat()
            (output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(
        f"  {'PASS' if summary['passed'] else 'FAIL'}: {output / 'report' / 'index.html'}",
        flush=True,
    )
    if interrupted:
        raise KeyboardInterrupt
    return summary["passed"] and summary["cleanup_succeeded"]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--suite",
        choices=[
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
            "all",
        ],
        default="all",
    )
    args = parser.parse_args()

    def interrupt(_signal: int, _frame: object) -> None:
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, interrupt)
    suites = (
        [
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
        if args.suite == "all"
        else [args.suite]
    )
    try:
        results = [run_suite(suite) for suite in suites]
    except KeyboardInterrupt:
        return 130
    return 0 if all(results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
