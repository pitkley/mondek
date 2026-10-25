# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Bounded public connection evidence; never serialize response bodies or secrets."""

from __future__ import annotations

import json
import re
import socket
import ssl
import time
import urllib.error
from collections.abc import Callable, Mapping
from datetime import UTC, datetime
from typing import Any

from .controller_auth import ControllerAuthError, http_failure

BODY_LIMIT = 16384


def http_details(
    status: int, headers: Mapping[str, str], body: bytes
) -> dict[str, Any]:
    details: dict[str, Any] = {"http_status": status}
    ray = headers.get("CF-Ray", "")
    if re.fullmatch(r"[a-fA-F0-9]{16}(?:-[A-Z]{3,5})?", ray):
        details["cf_ray"] = ray
    match = re.search(rb"\berror code:\s*(1[0-9]{3})\b", body[:BODY_LIMIT], re.I)
    if match and 400 <= status < 600:
        details["cf_error_code"] = int(match[1])
    return details


class ControllerHTTPError(urllib.error.HTTPError):
    def __init__(self, url: str, status: int, details: dict[str, Any]):
        super().__init__(url, status, http_failure(status), None, None)
        # Keep only the fields parsed by our bounded HTTP helper.
        self.details = {"http_status": status}
        ray = details.get("cf_ray")
        if isinstance(ray, str) and re.fullmatch(
            r"[a-fA-F0-9]{16}(?:-[A-Z]{3,5})?", ray
        ):
            self.details["cf_ray"] = ray
        code = details.get("cf_error_code")
        if type(code) is int and 1000 <= code <= 1999:
            self.details["cf_error_code"] = code


def failure_details(error: Exception) -> dict[str, Any]:
    if isinstance(error, urllib.error.HTTPError):
        details = {"http_status": error.code}
        if isinstance(error, ControllerHTTPError):
            details.update(error.details)
        details["kind"] = "http"
        details["message"] = http_failure(error.code)
        if details.get("cf_error_code") == 1010:
            details["message"] = (
                "Cloudflare Browser Integrity Check blocked the request (1010); "
                "inspect Security Events using the Ray ID."
            )
        return details
    if isinstance(error, ControllerAuthError):
        return {"kind": "authentication_file", "message": str(error)}
    reason = error.reason if isinstance(error, urllib.error.URLError) else error
    for error_type, kind, message in (
        (
            ssl.SSLCertVerificationError,
            "tls_certificate",
            "Controller TLS certificate verification failed.",
        ),
        (ssl.SSLError, "tls", "Controller TLS connection failed."),
        (socket.gaierror, "dns", "Controller hostname could not be resolved."),
        (TimeoutError, "timeout", "Controller request exceeded its time limit."),
        (
            ConnectionRefusedError,
            "connection_refused",
            "Controller connection was refused.",
        ),
        (
            ValueError,
            "protocol",
            "Controller response or local request configuration was invalid.",
        ),
    ):
        if isinstance(reason, error_type):
            return {"kind": kind, "message": message}
    return {
        "kind": "connection",
        "message": (
            "Controller request failed; check connectivity "
            "and gateway/origin availability."
        ),
    }


def emit_event(event: dict[str, Any]) -> None:
    try:
        at = datetime.now(UTC).isoformat().replace("+00:00", "Z")
        print(json.dumps({"at": at, **event}, allow_nan=False), flush=True)
    except (OSError, ValueError):
        # Logging must not turn a transient transport failure into a dead runner.
        pass


class ConnectionEvents:
    """One stream per channel; unchanged failures repeat at most every five minutes."""

    def __init__(
        self,
        *,
        clock: Callable[[], float] = time.monotonic,
        emit: Callable[[dict[str, Any]], None] = emit_event,
    ):
        self.clock, self.emit = clock, emit
        self.channels: dict[str, dict[str, Any]] = {}

    def failed(self, channel: str, error: Exception) -> None:
        now = self.clock()
        details = failure_details(error)
        signature = (
            details["kind"],
            details.get("http_status"),
            details.get("cf_error_code"),
        )
        previous = self.channels.get(channel)
        if previous is None or previous["ready"]:
            previous = {
                "ready": False,
                "since": now,
                "last_log": float("-inf"),
                "count": 0,
                "signature": None,
            }
            self.channels[channel] = previous
        previous["count"] += 1
        elapsed = now - previous["last_log"]
        if elapsed >= 300 or (signature != previous["signature"] and elapsed >= 30):
            self.emit(
                {
                    "event": "controller_unavailable",
                    "channel": channel,
                    "attempts": previous["count"],
                    **details,
                }
            )
            previous.update(last_log=now, signature=signature)

    def succeeded(self, channel: str) -> None:
        previous = self.channels.get(channel)
        if previous and previous["ready"]:
            return
        event: dict[str, Any] = {"event": "controller_ready", "channel": channel}
        if previous:
            event.update(
                recovered=True,
                failed_attempts=previous["count"],
                unavailable_seconds=round(max(0, self.clock() - previous["since"]), 3),
            )
        self.emit(event)
        self.channels[channel] = {"ready": True}
