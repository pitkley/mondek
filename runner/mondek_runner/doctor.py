# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Read-only controller probes with bounded output and no registration side effects."""

from __future__ import annotations

import argparse
import json
import math
import os
import re
import signal
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

from .connection_diagnostics import BODY_LIMIT, failure_details, http_details
from .controller_auth import ENVIRONMENT_VARIABLE, NoRedirect, controller_headers
from .policy import PolicyError, controller_url

ENDPOINTS = ("inventory", "control", "observations")
SERVICE_ENV = (
    "MONDEK_CONTROLLER_URL",
    ENVIRONMENT_VARIABLE,
    "SSL_CERT_FILE",
    "SSL_CERT_DIR",
    "HTTP_PROXY",
    "HTTPS_PROXY",
    "ALL_PROXY",
    "NO_PROXY",
    "http_proxy",
    "https_proxy",
    "all_proxy",
    "no_proxy",
)


def probe_once(url: str, timeout: float) -> dict[str, Any]:
    """Only GET existing POST routes. Never send registration or report payloads."""
    try:
        headers = controller_headers(url)
        request = urllib.request.Request(url, headers=headers, method="GET")
        try:
            response = urllib.request.build_opener(NoRedirect).open(
                request, timeout=timeout
            )
        except urllib.error.HTTPError as error:
            response = error
        with response:
            details = http_details(
                response.code, response.headers, response.read(BODY_LIMIT)
            )
        status = details["http_status"]
        if status in (404, 405):
            details.update(
                outcome="reachable_unverified",
                message=(
                    "GET reached a responding server; this route expects POST. "
                    "Registration and controller identity are not verified."
                ),
            )
        elif 300 <= status < 400:
            details.update(
                outcome="redirect",
                message=(
                    "Redirect refused; verify the Access application "
                    "and authentication policy."
                ),
            )
        elif details.get("cf_error_code") == 1010:
            details.update(
                outcome="blocked",
                message=(
                    "Cloudflare Browser Integrity Check blocked the request; "
                    "inspect Security Events using the Ray ID."
                ),
            )
        elif status in (401, 403):
            details.update(
                outcome="denied",
                message=(
                    "Access denied. Correlate the Ray ID with Access/security logs; "
                    "if Access allowed it, inspect tunnel JWT audiences "
                    "and origin middleware."
                ),
            )
        else:
            details.update(
                outcome="unexpected_response",
                message=(
                    "Unexpected GET response; registration and controller "
                    "identity are not verified."
                ),
            )
        return details
    except Exception as error:
        return {"outcome": "failed", **failure_details(error)}


def probe(
    url: str, timeout: float, env: dict[str, str], identity: dict[str, Any]
) -> dict[str, Any]:
    try:
        result = subprocess.run(
            [sys.executable, "-m", "mondek_runner.doctor", "--probe-helper"],
            input=json.dumps({"url": url, "timeout": timeout}).encode(),
            capture_output=True,
            timeout=timeout + 1,
            check=False,
            env=env,
            **identity,
        )
    except subprocess.TimeoutExpired:
        return {
            "outcome": "failed",
            "kind": "timeout",
            "message": (
                "Probe exceeded its total deadline, including DNS and response reads."
            ),
        }
    except OSError:
        return {
            "outcome": "failed",
            "kind": "helper",
            "message": "Could not launch the probe under the service account.",
        }
    if result.returncode == -signal.SIGALRM:
        return {
            "outcome": "failed",
            "kind": "timeout",
            "message": (
                "Probe exceeded its total deadline, including DNS and response reads."
            ),
        }
    try:
        if result.returncode or len(result.stdout) > 8192:
            raise ValueError
        report = json.loads(result.stdout)
        if not isinstance(report, dict):
            raise ValueError
        return report
    except ValueError:
        return {
            "outcome": "failed",
            "kind": "helper",
            "message": (
                "Probe helper failed; verify the installed runner "
                "executable and permissions."
            ),
        }


def _main_pid(service: str) -> int:
    result = subprocess.run(
        ["systemctl", "show", service, "--property=MainPID", "--value"],
        capture_output=True,
        timeout=5,
        check=False,
    )
    if result.returncode or not re.fullmatch(rb"[0-9]+\s*", result.stdout):
        raise ValueError
    pid = int(result.stdout)
    if pid <= 1:
        raise ValueError
    return pid


def service_context(service: str) -> tuple[dict[str, str], dict[str, Any]]:
    """Read only allowlisted settings; helpers use the running service's UID/GIDs."""
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.@-]{0,200}", service):
        raise ValueError("Invalid systemd service name.")
    try:
        pid = _main_pid(service)
        process = Path(f"/proc/{pid}")
        before = (process / "stat").read_bytes()
        # Split after the final ')' because the process name can contain spaces.
        started = before.rsplit(b")", 1)[1].split()[19]
        with (process / "environ").open("rb") as stream:
            raw = stream.read(1024 * 1024 + 1)
        if len(raw) > 1024 * 1024:
            raise ValueError
        variables = dict(
            item.split(b"=", 1) for item in raw.split(b"\0") if b"=" in item
        )
        env = {
            key: variables[key.encode()].decode()
            for key in SERVICE_ENV
            if key.encode() in variables
        }
        if "MONDEK_CONTROLLER_URL" not in env:
            raise ValueError
        status = dict(
            line.split(":", 1) for line in (process / "status").read_text().splitlines()
        )
        uid = int(status["Uid"].split()[1])
        gid = int(status["Gid"].split()[1])
        groups = [int(value) for value in status["Groups"].split()]
        if (
            _main_pid(service) != pid
            or (process / "stat").read_bytes().rsplit(b")", 1)[1].split()[19] != started
        ):
            raise ValueError
        identity: dict[str, Any] = {}
        if os.geteuid() == 0:
            identity = {"user": uid, "group": gid, "extra_groups": groups}
        elif (
            os.geteuid() != uid
            or os.getegid() != gid
            or set(os.getgroups()) != set(groups)
        ):
            raise ValueError
        return env, identity
    except (OSError, ValueError, KeyError, IndexError, subprocess.TimeoutExpired):
        raise ValueError(
            "Cannot inspect the running systemd service. Run doctor with sudo "
            "and verify the service is running with MONDEK_CONTROLLER_URL set."
        ) from None


def main(arguments: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--controller", help="controller origin; defaults to MONDEK_CONTROLLER_URL"
    )
    parser.add_argument(
        "--headers-file",
        help="private origin-bound header JSON file; never pass header values",
    )
    parser.add_argument(
        "--service",
        help="read running systemd service settings and probe as its account (Linux)",
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=8,
        help="per-endpoint deadline, 1–30 seconds (default: 8)",
    )
    args = parser.parse_args(arguments)
    if not math.isfinite(args.timeout) or not 1 <= args.timeout <= 30:
        parser.error("--timeout must be between 1 and 30 seconds")
    if args.service and (args.controller or args.headers_file):
        parser.error("--service cannot be combined with --controller or --headers-file")
    try:
        if args.service:
            env, identity = service_context(args.service)
        else:
            env, identity = dict(os.environ), {}
            if args.controller:
                env["MONDEK_CONTROLLER_URL"] = args.controller
            if args.headers_file:
                env[ENVIRONMENT_VARIABLE] = args.headers_file
        origin = controller_url(
            env.get("MONDEK_CONTROLLER_URL", "http://127.0.0.1:4000")
        )
        results = []
        for endpoint in ENDPOINTS:
            result = probe(origin + "/api/v1/" + endpoint, args.timeout, env, identity)
            results.append({"endpoint": "/api/v1/" + endpoint, **result})
            if result.get("kind") == "authentication_file":
                break
        output = {
            "command": "doctor",
            "read_only": True,
            "settings_source": "running_service"
            if args.service
            else "environment_and_arguments",
            "headers_file_configured": ENVIRONMENT_VARIABLE in env,
            "registration_tested": False,
            "results": results,
        }
        print(json.dumps(output, indent=2))
        raise SystemExit(
            0
            if all(item["outcome"] == "reachable_unverified" for item in results)
            else 1
        )
    except (ValueError, PolicyError):
        # Invalid URLs may contain credentials; never echo arguments or exceptions.
        print(
            json.dumps(
                {
                    "command": "doctor",
                    "error": (
                        "Invalid controller origin or unavailable service context; "
                        "use an http(s) origin without credentials and verify "
                        "service access."
                    ),
                }
            )
        )
        raise SystemExit(2) from None


if __name__ == "__main__":
    if sys.argv[1:] == ["--probe-helper"]:
        payload = json.loads(sys.stdin.buffer.read(8192))
        signal.signal(signal.SIGALRM, signal.SIG_DFL)
        signal.setitimer(signal.ITIMER_REAL, payload["timeout"])
        print(json.dumps(probe_once(payload["url"], payload["timeout"])))
    else:
        main()
