# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Origin-bound, file-backed headers shared by controller HTTP clients only."""

from __future__ import annotations

import json
import os
import re
import stat
import urllib.request
from urllib.parse import urlsplit

from . import environment

ENVIRONMENT_VARIABLE = "MONDEK_CONTROLLER_HEADERS_FILE"
MAX_BYTES = 16384
RESERVED = {
    "host",
    "content-length",
    "content-type",
    "accept",
    "connection",
    "transfer-encoding",
    "upgrade",
    "te",
    "trailer",
    "proxy-authorization",
    "proxy-connection",
    "expect",
}


class ControllerAuthError(ValueError):
    """Safe actionable local configuration error."""


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def _unique(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate key")
        result[key] = value
    return result


def _origin(url: str) -> tuple[str, str, int]:
    parts = urlsplit(url)
    if (
        parts.scheme != "https"
        or not parts.hostname
        or parts.username is not None
        or parts.password is not None
        or parts.fragment
        or any(ord(c) <= 32 or ord(c) >= 127 for c in url)
    ):
        raise ValueError("invalid origin")
    return (
        parts.scheme,
        parts.hostname.lower(),
        parts.port if parts.port is not None else 443,
    )


def controller_headers(url: str) -> dict[str, str]:
    """Reload for every exchange; errors deliberately omit paths and contents."""
    path = environment.get(ENVIRONMENT_VARIABLE)
    if path is None:
        return {}
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
        with os.fdopen(fd, "rb") as source:
            info = os.fstat(source.fileno())
            if not stat.S_ISREG(info.st_mode) or info.st_mode & 0o077:
                raise ValueError("not a private regular file")
            data = source.read(MAX_BYTES + 1)
        if len(data) > MAX_BYTES:
            raise ValueError("file too large")
        document = json.loads(data, object_pairs_hook=_unique)
        if not isinstance(document, dict) or set(document) != {"origin", "headers"}:
            raise ValueError("invalid document")
        origin = document["origin"]
        if (
            not isinstance(origin, str)
            or urlsplit(origin).path not in ("", "/")
            or urlsplit(origin).query
        ):
            raise ValueError("invalid origin")
        if _origin(origin) != _origin(url):
            raise ValueError("origin mismatch")
        headers = document["headers"]
        if not isinstance(headers, dict) or not 1 <= len(headers) <= 32:
            raise ValueError("invalid headers")
        seen = set()
        for name, value in headers.items():
            if (
                not re.fullmatch(r"[!#$%&'*+.^_`|~0-9A-Za-z-]+", name)
                or name.lower() in RESERVED
                or name.lower() in seen
                or not isinstance(value, str)
                or not value
                or any(ord(c) < 32 or ord(c) > 126 for c in value)
            ):
                raise ValueError("invalid header")
            seen.add(name.lower())
        return headers
    except (OSError, ValueError, TypeError, RecursionError):
        raise ControllerAuthError(
            "Invalid controller authentication file: require private permissions "
            "(0600), "
            "a matching HTTPS origin and a JSON headers object."
        ) from None


def http_failure(code: int) -> str:
    if code in (401, 403):
        return (
            "controller access denied; check authentication credentials "
            "and gateway policy"
        )
    if 300 <= code < 400:
        return (
            "controller redirected the request; redirects are refused; "
            "check gateway authentication"
        )
    return f"controller HTTP {code}: request rejected"
