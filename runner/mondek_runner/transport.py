# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Bounded HTTP exchanges in owned processes with absolute lifetime limits."""

from __future__ import annotations

import argparse
import json
import math
import signal
import socket
import ssl
import subprocess
import sys
import urllib.error
import urllib.request
from http.client import RemoteDisconnected
from typing import Any
from urllib.parse import urlparse

from .connection_diagnostics import (
    BODY_LIMIT,
    ControllerHTTPError,
    failure_details,
    http_details,
)
from .connections import ControllerHTTPHandler, ControllerHTTPSHandler
from .controller_auth import (
    ControllerAuthError,
    NoRedirect,
    controller_headers,
)

MAX_BODY = 262144


def body_limit(url: str) -> int:
    return (
        4 * 1024 * 1024
        if urlparse(url).path in ("/api/v1/inventory", "/api/v1/control")
        else MAX_BODY
    )


def post_json(url: str, payload: dict[str, Any], timeout: float) -> dict[str, Any]:
    """Kill and reap the exchange at its deadline, including DNS and slow reads."""
    if not math.isfinite(timeout) or timeout <= 0:
        raise ValueError("transport timeout must be positive and finite")
    raw = json.dumps(payload, separators=(",", ":"), allow_nan=False).encode()
    if len(raw) > body_limit(url):
        raise ValueError("outgoing request exceeds payload cap")
    try:
        child = subprocess.run(
            [sys.executable, "-m", "mondek_runner.transport", str(timeout), url],
            input=raw,
            capture_output=True,
            timeout=timeout,
            check=False,
        )
    except subprocess.TimeoutExpired:
        # subprocess.run has killed and reaped this child before raising.
        raise TimeoutError("HTTP exchange exceeded its total deadline") from None
    if child.returncode == -signal.SIGALRM:
        raise TimeoutError("HTTP exchange exceeded its total deadline")
    if child.returncode != 0:
        raise OSError(f"HTTP exchange process exited {child.returncode}")
    message = json.loads(child.stdout)
    if "error" in message:
        error = message["error"]
        detail = error["message"]
        if error["type"] == "RemoteDisconnected":
            raise RemoteDisconnected(detail)
        if error["type"] == "HTTPError":
            raise ControllerHTTPError(url, error["code"], error.get("details", {}))
        if error["type"] == "URLError":
            reason_type = {
                "dns": socket.gaierror,
                "tls_certificate": ssl.SSLCertVerificationError,
                "tls": ssl.SSLError,
                "connection_refused": ConnectionRefusedError,
                "timeout": TimeoutError,
            }.get(error.get("details", {}).get("kind"))
            raise urllib.error.URLError(reason_type(detail) if reason_type else detail)
        if error["type"] == "ControllerAuthError":
            raise ControllerAuthError(detail)
        if error["type"] == "ValueError":
            raise ValueError(detail)
        if error["type"] == "TimeoutError":
            raise TimeoutError(detail)
        raise OSError(f"{error['type']}: {detail}")
    return message["response"]


def exchange(url: str, raw: bytes, timeout: float) -> dict[str, Any]:
    """One bounded wire request, called only within the owned helper process."""
    limit = body_limit(url)
    if len(raw) > limit:
        raise ValueError("outgoing request exceeds payload cap")
    request = urllib.request.Request(
        url,
        raw,
        {"Content-Type": "application/json", **controller_headers(url)},
        method="POST",
    )
    try:
        with urllib.request.build_opener(
            NoRedirect, ControllerHTTPHandler, ControllerHTTPSHandler
        ).open(request, timeout=timeout) as response:
            body = response.read(limit + 1)
    except urllib.error.HTTPError as error:
        with error:
            details = http_details(error.code, error.headers, error.read(BODY_LIMIT))
        raise ControllerHTTPError(url, error.code, details) from None
    if len(body) > limit:
        raise ValueError("controller response exceeds payload cap")
    result = json.loads(body)
    if not isinstance(result, dict) or result.get("version") != 1:
        raise ValueError("unsupported controller protocol")
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("timeout", type=float)
    parser.add_argument("url")
    args = parser.parse_args()
    # Default SIGALRM terminates even a blocking resolver or native socket call.
    # This lifetime bound remains in force if the supervisor itself is killed.
    signal.signal(signal.SIGALRM, signal.SIG_DFL)
    signal.setitimer(signal.ITIMER_REAL, args.timeout)
    try:
        response = exchange(
            args.url, sys.stdin.buffer.read(body_limit(args.url) + 1), args.timeout
        )
        message = {"response": response}
        encoded = json.dumps(message, ensure_ascii=False, allow_nan=False)
    except Exception as error:
        message = {
            "error": {
                "type": "HTTPError"
                if isinstance(error, urllib.error.HTTPError)
                else type(error).__name__,
                "message": failure_details(error)["message"],
                "details": failure_details(error),
                "code": error.code
                if isinstance(error, urllib.error.HTTPError)
                else None,
            }
        }
        encoded = json.dumps(message, ensure_ascii=False)
    sys.stdout.write(encoded)


if __name__ == "__main__":
    main()
