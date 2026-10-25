#!/usr/bin/env python3
# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Exercise the image-install recipe with a real installed SDK and local receiver."""

from __future__ import annotations

import argparse
from collections.abc import Callable
import json
import os
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def start_services(compose: list[str], run: Callable[..., None]) -> None:
    # Fresh release runners have the qualified controller, but no database image.
    # Fetch only that pinned dependency; never resolve/pull the controller tag.
    run(*compose, "pull", "postgres")
    run(*compose, "up", "-d", "--wait", "--wait-timeout", "180", "--pull", "never")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--image", required=True, help="locally built qualified controller tag"
    )
    parser.add_argument(
        "--sdk-wheel", type=Path, help="qualify this exact prepared SDK wheel"
    )
    args = parser.parse_args()
    sdk_wheel = args.sdk_wheel.resolve(strict=True) if args.sdk_wheel else None
    project = "mondek-install-" + uuid.uuid4().hex[:10]
    output = ROOT / ".local/acceptance" / project
    output.mkdir(parents=True)

    sys.path.insert(0, str(ROOT / "tests/deployment"))
    from smtp_receiver import SMTP, SMTPServer, STATE

    receiver = SMTPServer(("0.0.0.0", 0), SMTP)
    threading.Thread(target=receiver.serve_forever, daemon=True).start()
    env = {key: value for key, value in os.environ.items() if key != "PYTHONPATH"}
    # Docker Desktop's credential helper may be outside the devenv tool PATH.
    helper = Path("/Applications/Docker.app/Contents/Resources/bin")
    if helper.is_dir():
        env["PATH"] = env.get("PATH", "") + os.pathsep + str(helper)
    runner = None
    with (
        tempfile.TemporaryDirectory(prefix=project) as temporary,
        (output / "commands.log").open("w") as log,
    ):
        workspace = Path(temporary)
        private = workspace / ".env"
        private.write_text(
            f"PGPASSWORD={uuid.uuid4().hex}\nSECRET_KEY_BASE={uuid.uuid4().hex * 3}\nMONDEK_SMTP_HOST=host.docker.internal\nMONDEK_SMTP_PORT={receiver.server_address[1]}\nMONDEK_SMTP_TRANSPORT=plain\nMONDEK_SMTP_FROM=mondek@example.invalid\nMONDEK_SMTP_TO=operator@example.invalid\nMONDEK_RETENTION_RECEIPT_DAYS=2\nMONDEK_RETENTION_HISTORY_DAYS=31\nMONDEK_RETENTION_MAX_OBSERVATIONS=17\n"
        )
        private.chmod(0o600)
        overlay = workspace / "test.yaml"
        overlay.write_text(
            'services:\n  controller:\n    ports: !override\n      - "127.0.0.1::4000"\n'
            + (
                '    extra_hosts:\n      - "host.docker.internal:host-gateway"\n'
                if sys.platform == "linux"
                else ""
            )
        )
        env |= {"MONDEK_IMAGE": args.image, "MONDEK_ENV_FILE": str(private)}
        compose = [
            "docker",
            "compose",
            "-p",
            project,
            "--env-file",
            str(private),
            "-f",
            str(ROOT / "deploy/compose.yaml"),
            "-f",
            str(overlay),
        ]

        def run(*command, cwd=ROOT):
            subprocess.run(
                command,
                cwd=cwd,
                env=env,
                stdout=log,
                stderr=subprocess.STDOUT,
                check=True,
                timeout=600,
            )

        def read(path):
            with urllib.request.urlopen(origin + path, timeout=5) as response:
                return json.load(response)

        def until(label, predicate):
            print("Waiting for", label, flush=True)
            deadline = time.monotonic() + 120
            while time.monotonic() < deadline:
                if predicate():
                    return
                time.sleep(0.5)
            raise TimeoutError(f"Installation acceptance timed out: {label}")

        def delivered(kind):
            receipts = {item["occurrence_id"] for item in STATE.records}
            return any(
                item["kind"] == kind
                and item["status"] == "delivered"
                and item["id"] in receipts
                for item in read("/api/v1/snapshot")["occurrences"]
            )

        def start_runner():
            return subprocess.Popen(
                [
                    str(python),
                    "-m",
                    "mondek_runner",
                    "--consumer",
                    "monitoring.app:app",
                    "--controller",
                    origin,
                    "--state-dir",
                    str(workspace / "state"),
                ],
                cwd=consumer,
                env=env,
                stdout=log,
                stderr=subprocess.STDOUT,
            )

        try:
            run(*compose, "config", "--quiet")
            services = subprocess.check_output(
                [*compose, "config", "--services"], env=env, text=True
            ).split()
            assert sorted(services) == ["controller", "postgres"]
            start_services(compose, run)
            address = subprocess.check_output(
                [*compose, "port", "controller", "4000"], env=env, text=True
            ).strip()
            origin = "http://" + address
            assert read("/health")["status"] == "ok"
            with urllib.request.urlopen(origin, timeout=5) as response:
                html = response.read().decode()
                assert "Monitoring overview" in html and "History retention" in html
            assert read("/api/v1/snapshot")["runners"] == []
            if sdk_wheel is None:
                run(
                    "uv",
                    "build",
                    "--project",
                    "runner",
                    "--wheel",
                    "--out-dir",
                    str(workspace / "dist"),
                )
                sdk_wheel = next((workspace / "dist").glob("*.whl"))
            run("uv", "venv", str(workspace / "venv"), "--python", sys.executable)
            python = workspace / "venv/bin/python"
            run(
                "uv",
                "pip",
                "install",
                "--python",
                str(python),
                str(sdk_wheel),
            )
            consumer = workspace / "consumer"
            run(
                str(python),
                "-I",
                "-m",
                "mondek_runner",
                "init",
                str(consumer),
                cwd=workspace,
            )
            run(
                "uv",
                "pip",
                "install",
                "--python",
                str(python),
                "--no-deps",
                str(consumer),
                cwd=workspace,
            )
            run(
                str(python),
                "-I",
                "-m",
                "mondek_runner",
                "validate",
                "--consumer",
                "monitoring.app:app",
                cwd=consumer,
            )
            run(
                str(python),
                "-I",
                "-m",
                "unittest",
                "discover",
                "-s",
                str(consumer / "tests"),
                cwd=consumer,
            )
            runner = start_runner()
            until(
                "fresh installed-runner measurement",
                lambda: read("/api/v1/runners")["counts"]["coverage"]["fresh"] == 1,
            )
            before = read("/api/v1/snapshot")
            installation = before["runners"][0]["id"]
            (consumer / "sample-backlog.txt").write_text("1000000\n")
            until("firing SMTP receipt", lambda: delivered("firing"))
            (consumer / "sample-backlog.txt").write_text("0\n")
            until("recovery SMTP receipt", lambda: delivered("resolved"))
            run(
                *compose,
                "up",
                "-d",
                "--wait",
                "--wait-timeout",
                "180",
                "--no-deps",
                "--force-recreate",
                "controller",
            )
            address = subprocess.check_output(
                [*compose, "port", "controller", "4000"], env=env, text=True
            ).strip()
            origin = "http://" + address
            # Reconnect the native runner to the recreated controller's mapped port.
            runner.terminate()
            runner.wait(timeout=20)
            runner = start_runner()
            until(
                "fresh installed-runner measurement",
                lambda: read("/api/v1/runners")["counts"]["coverage"]["fresh"] == 1,
            )
            after = read("/api/v1/snapshot")
            assert after["runners"][0]["id"] == installation
            assert (
                "17 receipts" in after["retention"] and "31 days" in after["retention"]
            )
            assert after["incidents"]
            proof = {
                "project": project,
                "passed": True,
                "services": services,
                "stable_runner": installation,
                "retention_persisted": True,
                "firing_and_recovery": True,
            }
            (output / "result.json").write_text(json.dumps(proof, indent=2) + "\n")
            print("PASS image install/update and installed runner:", output)
        except Exception:
            try:
                run(*compose, "logs", "--tail", "100", "controller", "postgres")
                (output / "failure-snapshot.json").write_text(
                    json.dumps(read("/api/v1/snapshot"), indent=2)
                )
            except Exception:
                pass
            raise
        finally:
            if runner is not None and runner.poll() is None:
                runner.terminate()
                runner.wait(timeout=20)
            try:
                run(*compose, "down", "--volumes", "--remove-orphans")
            finally:
                receiver.shutdown()
                receiver.server_close()


if __name__ == "__main__":
    main()
