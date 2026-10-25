#!/usr/bin/env python3
# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Bounded browser-free cost measurements on disposable real installations."""

from __future__ import annotations

import argparse
import json
import os
import re
import signal
import subprocess
import time
import uuid
from datetime import UTC, datetime
from pathlib import Path
from urllib.request import urlopen

ROOT = Path(__file__).resolve().parents[2]
SERVICES = ("controller", "postgres", "target", "profile-runners")


def now() -> str:
    return datetime.now(UTC).isoformat()


def fetch(base: str, path: str) -> dict:
    with urlopen(base + path, timeout=10) as response:
        return json.load(response)


def run_case(mode: str, count: int, seconds: int, output: Path) -> dict:
    project = "mondek-profile-" + uuid.uuid4().hex[:10]
    folder = output / f"{mode}-{count}-{project}"
    folder.mkdir()
    env = os.environ | {
        "MONDEK_PROFILE_MODE": mode,
        "MONDEK_PROFILE_RUNNERS": str(count),
        "COMPOSE_PROFILES": "",
    }
    helper = Path("/Applications/Docker.app/Contents/Resources/bin")
    if helper.is_dir():
        env["PATH"] = env.get("PATH", "") + os.pathsep + str(helper)
    command = [
        "docker",
        "compose",
        "-p",
        project,
        "-f",
        "compose.yaml",
        "-f",
        "tests/performance/compose.yaml",
    ]
    result = {
        "project": project,
        "mode": mode,
        "runners": count,
        "started_at": now(),
        "passed": False,
        "cleanup_succeeded": False,
    }
    print(f"Profile {mode}/{count}: {project}; evidence {folder}", flush=True)
    with (folder / "compose.log").open("w") as log:

        def compose(*args: str, timeout: int = 180) -> str:
            completed = subprocess.run(
                command + list(args),
                cwd=ROOT,
                env=env,
                text=True,
                stdout=subprocess.PIPE,
                stderr=log,
                timeout=timeout,
                check=False,
            )
            log.write(completed.stdout)
            log.flush()
            completed.check_returncode()
            return completed.stdout

        def sql(query: str) -> str:
            return compose(
                "exec",
                "-T",
                "postgres",
                "psql",
                "-X",
                "-A",
                "-t",
                "-v",
                "ON_ERROR_STOP=1",
                "-U",
                "mondek",
                "-d",
                "mondek_dev",
                "-c",
                query,
            )

        def sample() -> dict:
            samples = {}
            for service in SERVICES:
                if service == "profile-runners":
                    value = json.loads(
                        compose("exec", "-T", service, "python", "/app/sample.py")
                    )
                else:
                    raw = compose(
                        "exec",
                        "-T",
                        service,
                        "sh",
                        "-c",
                        "cat /sys/fs/cgroup/cpu.stat /sys/fs/cgroup/memory.current /sys/fs/cgroup/memory.peak",
                    )
                    lines = raw.splitlines()
                    value = {
                        "cpu": {
                            line.split()[0]: int(line.split()[1])
                            for line in lines
                            if " " in line
                        },
                        "memory_current": int(lines[-2]),
                        "memory_peak": int(lines[-1]),
                    }
                samples[service] = {"monotonic": time.monotonic(), **value}
            samples["database"] = json.loads(
                sql("""
                SELECT row_to_json(s) FROM (
                  SELECT xact_commit, xact_rollback, tup_returned, tup_fetched,
                    tup_inserted, tup_updated, tup_deleted, deadlocks
                  FROM pg_stat_database WHERE datname=current_database()
                ) s
            """)
            )
            return samples

        try:
            compose("build", *SERVICES, timeout=900)
            launch = time.monotonic()
            compose("up", "--detach", "--wait", "--wait-timeout", "120", *SERVICES)
            port = compose("port", "controller", "4000").strip()
            base = "http://" + port
            result["base_url"] = base
            deadline = time.monotonic() + 120
            while True:
                snapshot = fetch(base, "/api/v1/snapshot")
                checks = fetch(base, "/api/v1/checks?page_size=100")
                expected = count if mode == "active" else 0
                if (
                    len(snapshot["runners"]) == count
                    and checks["total"] == expected
                    and all(
                        row["current"]["knowledge"] == "fresh"
                        for row in checks["items"]
                    )
                ):
                    break
                if time.monotonic() >= deadline:
                    result["readiness"] = {
                        "snapshot": snapshot,
                        "checks": checks,
                        "runners": json.loads(
                            compose(
                                "exec",
                                "-T",
                                "profile-runners",
                                "python",
                                "/app/sample.py",
                            )
                        ),
                    }
                    raise RuntimeError(
                        "Profile workload did not reach expected registered/fresh state"
                    )
                time.sleep(1)
            result["startup_seconds"] = time.monotonic() - launch
            # Discovery, preparation and first publication are outside the window.
            time.sleep(10)
            sql("CREATE EXTENSION IF NOT EXISTS pg_stat_statements")
            before = sample()
            contacts_before = json.loads(
                sql(
                    "SELECT COALESCE(json_agg(s), '[]') FROM (SELECT id, session_id, boot, last_seen_at FROM runners ORDER BY id) s"
                )
            )
            sql_start = time.monotonic()
            sql("SELECT pg_stat_statements_reset()")
            start = now()
            print(
                f"  {mode}/{count}: measuring {seconds}s without a browser", flush=True
            )
            time.sleep(seconds)
            end = now()
            statements = json.loads(
                sql("""
                SELECT COALESCE(json_agg(s), '[]') FROM (
                  SELECT query, calls, total_exec_time, mean_exec_time, rows
                  FROM pg_stat_statements
                  WHERE dbid=(SELECT oid FROM pg_database WHERE datname=current_database())
                  ORDER BY total_exec_time DESC
                ) s
            """)
            )
            sql_duration = time.monotonic() - sql_start
            sql_end = now()
            after = sample()
            contacts_after = json.loads(
                sql(
                    "SELECT COALESCE(json_agg(s), '[]') FROM (SELECT id, session_id, boot, last_seen_at FROM runners ORDER BY id) s"
                )
            )
            # Generated UTC timestamps contain no user input. Require original
            # execution and receipt within the actual window, not allocations
            # or retained startup evidence that has not aged stale yet.
            progress = json.loads(
                sql(f"""
                SELECT COALESCE(json_agg(s), '[]') FROM (
                  SELECT installation_id, count(*) AS reports,
                    count(*) FILTER (WHERE disposition='current'
                      AND payload->>'complete'='true'
                      AND jsonb_array_length(payload->'results')=1
                      AND payload->'results'->0->>'health'='OK'
                      AND (payload->'results'->0->>'source_at')::timestamptz >= '{start}'::timestamptz
                      AND (payload->'results'->0->>'source_at')::timestamptz <= '{end}'::timestamptz
                    ) AS successful_measurements
                  FROM observations
                  WHERE started_at >= '{start}'::timestamptz
                    AND evaluated_at <= '{end}'::timestamptz
                    AND received_at <= '{end}'::timestamptz
                  GROUP BY installation_id
                ) s
            """)
            )
            workload_statements = [
                row for row in statements if "pg_stat_statements" not in row["query"]
            ]
            logs = compose(
                "logs", "--no-color", "--since", start, "--until", end, "controller"
            )
            (folder / "window-controller.log").write_text(logs)
            resources = {}
            for service in SERVICES:
                duration = after[service]["monotonic"] - before[service]["monotonic"]
                # sample.py and the plain cgroup probes use the same cpu shape.
                cpu = (
                    after[service]["cpu"]["usage_usec"]
                    - before[service]["cpu"]["usage_usec"]
                )
                resources[service] = {
                    "seconds": duration,
                    "cpu_seconds": cpu / 1e6,
                    "cpu_percent_one_core": 100 * cpu / 1e6 / duration,
                    "memory_current": after[service]["memory_current"],
                }
            result.update(
                window_start=start,
                window_end=end,
                before=before,
                after=after,
                resources=resources,
                statements=statements,
                sql_window_end=sql_end,
                sql_window_seconds=sql_duration,
                sql_calls=sum(row["calls"] for row in workload_statements),
                sql_exec_ms=sum(row["total_exec_time"] for row in workload_statements),
                excluded_statements=[
                    row for row in statements if "pg_stat_statements" in row["query"]
                ],
                contacts_before=contacts_before,
                contacts_after=contacts_after,
                measurement_progress=progress,
                requests={
                    path: len(
                        re.findall(r"POST " + re.escape(path) + r"(?:\s|$)", logs)
                    )
                    for path in (
                        "/api/v1/control",
                        "/api/v1/observations",
                        "/api/v1/inventory",
                    )
                },
                database_delta={
                    key: after["database"][key] - value
                    for key, value in before["database"].items()
                },
                snapshot=fetch(base, "/api/v1/snapshot"),
                checks=fetch(base, "/api/v1/checks?page_size=100"),
            )
            initial_journals = {
                row["installation_id"]: row
                for row in before["profile-runners"]["journals"]
            }
            final_journals = after["profile-runners"]["journals"]
            if len(initial_journals) != count or len(final_journals) != count:
                raise RuntimeError("Expected independent runner journals are missing")
            prior_contacts = {row["id"]: row for row in contacts_before}
            if len(prior_contacts) != count or len(contacts_after) != count:
                raise RuntimeError(
                    "Expected independent registered runners are missing"
                )
            for contact in contacts_after:
                prior = prior_contacts[contact["id"]]
                if (
                    contact["session_id"] != prior["session_id"]
                    or contact["boot"] != prior["boot"]
                    or contact["last_seen_at"] <= prior["last_seen_at"]
                ):
                    raise RuntimeError(
                        "Every registered runner must retain its session and advance contact"
                    )
            successful = {
                row["installation_id"]: row["successful_measurements"]
                for row in progress
            }
            for row in final_journals:
                initial = initial_journals[row["installation_id"]]
                if (
                    row["session_id"] != initial["session_id"]
                    or row["boot"] != initial["boot"]
                    or row["dropped"]
                    or row["loss_at"]
                    or initial["diagnostic"]
                    not in (None, "runner restarted; missed intervals skipped")
                    or row["diagnostic"] != initial["diagnostic"]
                ):
                    raise RuntimeError(
                        "Runner restarted, lost evidence or reported a diagnostic during measurement"
                    )
                if mode == "active" and successful.get(row["installation_id"], 0) < 2:
                    raise RuntimeError(
                        "Each active runner must persist two successful original measurements during the window"
                    )
                if row["queue_count"] > 2:
                    raise RuntimeError(
                        "Evidence delivery did not keep up with the bounded profile workload"
                    )
            if count:
                result["transport_microbench"] = json.loads(
                    compose(
                        "exec",
                        "-T",
                        "profile-runners",
                        "python",
                        "/app/sample.py",
                        "--microbench",
                    )
                )
            if result["checks"]["total"] != expected or any(
                row["current"]["knowledge"] != "fresh"
                or row["current"]["health"] != "OK"
                for row in result["checks"]["items"]
            ):
                raise RuntimeError(
                    "Expected fresh coverage was not preserved during measurement"
                )
            result["passed"] = True
            print(
                f"  {mode}/{count}: {result['sql_calls']} SQL calls; CPU {resources}",
                flush=True,
            )
        except (Exception, KeyboardInterrupt) as error:
            result["error"] = f"{type(error).__name__}: {error}"
            raise
        finally:
            try:
                (folder / "services.log").write_text(
                    compose("logs", "--no-color", "--tail", "2000")
                )
            finally:
                try:
                    compose("down", "--volumes", "--remove-orphans")
                    result["cleanup_succeeded"] = True
                finally:
                    result["finished_at"] = now()
                    (folder / "result.json").write_text(
                        json.dumps(result, indent=2) + "\n"
                    )
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--runners", type=int, choices=(1, 12), nargs="+", default=[1, 12]
    )
    parser.add_argument(
        "--modes", choices=("idle", "active"), nargs="+", default=["idle", "active"]
    )
    parser.add_argument("--seconds", type=int, default=75)
    parser.add_argument("--skip-baseline", action="store_true")
    args = parser.parse_args()
    if not 60 <= args.seconds <= 180:
        parser.error(
            "--seconds must be 60–180, spanning at least two execution intervals"
        )
    output = (
        ROOT
        / ".local"
        / "performance"
        / (datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ") + "-" + uuid.uuid4().hex[:6])
    )
    output.mkdir(parents=True)
    metadata = {
        "started_at": now(),
        "seconds": args.seconds,
        "git_revision": subprocess.check_output(
            ["git", "rev-parse", "HEAD"], cwd=ROOT, text=True
        ).strip(),
        "tracked_diff": subprocess.check_output(
            ["git", "diff", "--stat"], cwd=ROOT, text=True
        ),
        "docker": json.loads(
            subprocess.check_output(
                [
                    "docker",
                    "info",
                    "--format",
                    '{"architecture":"{{.Architecture}}","cpus":{{.NCPU}},"memory_bytes":{{.MemTotal}},"version":"{{.ServerVersion}}"}',
                ],
                text=True,
            )
        ),
    }
    (output / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
    cases = ([] if args.skip_baseline else [("idle", 0)]) + [
        (mode, count)
        for count in dict.fromkeys(args.runners)
        for mode in dict.fromkeys(args.modes)
    ]
    for mode, count in cases:
        run_case(mode, count, args.seconds, output)
    print(f"Completed bounded profile: {output}", flush=True)


if __name__ == "__main__":

    def interrupt(_signum: int, _frame: object) -> None:
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, interrupt)
    main()
