# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Bounded stdio-to-HTTP adapter for the controller's read-only MCP endpoint."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import urllib.error
import urllib.request
from urllib.parse import urlsplit

from .controller_auth import NoRedirect

MAX_REQUEST = 16_384
MAX_RESPONSE = 1_048_576


def endpoint(value: str) -> str:
    parts = urlsplit(value)
    if (
        parts.scheme not in {"http", "https"}
        or not parts.hostname
        or parts.username is not None
        or parts.password is not None
        or parts.query
        or parts.fragment
        or parts.path not in {"", "/"}
        or any(ord(c) <= 32 for c in value)
    ):
        raise argparse.ArgumentTypeError("Supply the controller HTTP(S) origin.")
    return value.rstrip("/") + "/mcp"


def error(request_id: object, message: str) -> dict[str, object]:
    return {
        "jsonrpc": "2.0",
        "id": request_id,
        "error": {"code": -32603, "message": message},
    }


def serve(url: str) -> int:
    version: str | None = None
    while line := sys.stdin.buffer.readline(MAX_REQUEST + 1):
        if len(line) > MAX_REQUEST:
            print("MCP input exceeds 16 KiB; closing adapter.", file=sys.stderr)
            return 1
        try:
            message = json.loads(line)
        except (ValueError, UnicodeError):
            print(json.dumps(error(None, "Invalid JSON input.")), flush=True)
            continue
        request_id = message.get("id") if isinstance(message, dict) else None
        notification = isinstance(message, dict) and "id" not in message
        try:
            # A process deadline also bounds DNS and trickling responses. The worker
            # reads a bounded response and prints no diagnostics or private bodies.
            worker = subprocess.run(
                [
                    sys.executable,
                    "-m",
                    "mondek_runner.mcp",
                    "--exchange",
                    url,
                    version or "",
                ],
                input=line,
                capture_output=True,
                timeout=15,
                check=True,
            )
            if not worker.stdout and notification:
                continue
            reply = json.loads(worker.stdout)
            if (
                not isinstance(reply, dict)
                or reply.get("jsonrpc") != "2.0"
                or reply.get("id") != request_id
            ):
                raise ValueError("invalid response")
            if isinstance(message, dict) and message.get("method") == "initialize":
                negotiated = reply.get("result", {}).get("protocolVersion")
                if isinstance(negotiated, str):
                    version = negotiated
        except (OSError, ValueError, subprocess.SubprocessError):
            reply = error(
                request_id,
                "Mondek MCP unavailable; check controller address and reachability.",
            )
            if notification:
                print("Mondek MCP notification delivery failed.", file=sys.stderr)
                return 1
        if not notification:
            print(
                json.dumps(reply, ensure_ascii=True, separators=(",", ":")), flush=True
            )
    return 0


def exchange(url: str, version: str) -> int:
    headers = {
        "Content-Type": "application/json",
        "Accept": "application/json, text/event-stream",
    }
    if version:
        headers["MCP-Protocol-Version"] = version
    request = urllib.request.Request(
        url, data=sys.stdin.buffer.read(MAX_REQUEST + 1), headers=headers, method="POST"
    )
    try:
        with urllib.request.build_opener(NoRedirect()).open(
            request, timeout=10
        ) as response:
            if response.status == 202:
                return 0
            body = response.read(MAX_RESPONSE + 1)
            if len(body) > MAX_RESPONSE:
                return 1
            sys.stdout.buffer.write(body)
    except (OSError, ValueError, urllib.error.URLError):
        return 1
    return 0


def main() -> None:
    if len(sys.argv) == 4 and sys.argv[1] == "--exchange":
        raise SystemExit(exchange(sys.argv[2], sys.argv[3]))
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--controller", required=True, type=endpoint)
    args = parser.parse_args()
    raise SystemExit(serve(args.controller))


if __name__ == "__main__":
    main()
