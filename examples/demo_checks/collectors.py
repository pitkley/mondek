# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Real built-in filesystem and HTTP collectors."""

import shutil
import urllib.error
import urllib.request

from mondek_runner.api import Result, check, timestamp


@check(expected_keys=("capacity",))
def filesystem(*, params: dict):
    usage = shutil.disk_usage(params["path"])
    source_at = timestamp()
    percent = usage.used / usage.total * 100
    health = (
        "CRIT"
        if percent >= params["crit_percent"]
        else "WARN"
        if percent >= params["warn_percent"]
        else "OK"
    )
    yield Result(
        "capacity",
        health,
        f"{params['path']}: {percent:.1f}% used in runner filesystem",
        round(percent, 4),
        source_at,
    )


@check(expected_keys=("readiness",))
def http(*, params: dict):
    try:
        with urllib.request.urlopen(params["url"], timeout=1.2) as response:
            status = response.status
    except urllib.error.HTTPError as error:
        status = error.code
    except (urllib.error.URLError, TimeoutError, OSError) as error:
        return Result(
            "readiness", "CRIT", f"Readiness probe failed: {error}", None, timestamp()
        )
    return Result(
        "readiness",
        "OK" if 200 <= status < 300 else "CRIT",
        f"Readiness returned HTTP {status}",
        status,
        timestamp(),
    )
