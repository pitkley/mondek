# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Complete local assignment validation before readiness is advertised."""

from __future__ import annotations

import math
import re
from copy import deepcopy
from typing import Any

from .authoring import canonical, stable_key

MAX_ASSIGNMENTS = 512


def assignment_id(value: Any) -> bool:
    """A textual UUID, safe for an assignment's execution lock."""
    return (
        isinstance(value, str)
        and re.fullmatch(
            r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", value
        )
        is not None
    )


def number(value: Any, low: float, high: float) -> bool:
    return type(value) in (int, float) and math.isfinite(value) and low <= value <= high


def validate(assignment: dict[str, Any]) -> dict[str, Any]:
    kind = assignment["kind"]
    if kind != "python" or not assignment_id(assignment["id"]):
        raise ValueError("unsupported assignment kind or identity")
    if (
        type(assignment["generation"]) is not int
        or not 1 <= assignment["generation"] <= 2_147_483_647
    ):
        raise ValueError("generation must be an integer between 1 and 2147483647")
    for key, low, high in (
        ("interval_seconds", 0.1, 86400),
        ("timeout_seconds", 0.1, 300),
        ("freshness_seconds", 0.1, 172800),
    ):
        if not number(assignment[key], low, high):
            raise ValueError(f"invalid {key}")
    params = assignment["params"]
    if not isinstance(params, dict):
        raise ValueError("params must be an object")
    for name in ("source_id", "source_key"):
        stable_key(assignment[name], name)
    for name in ("source_revision", "definition_revision"):
        if not isinstance(assignment[name], str) or not re.fullmatch(
            r"[0-9a-f]{64}", assignment[name]
        ):
            raise ValueError(f"invalid {name}")
    keys = assignment["expected_keys"]
    if (
        not isinstance(keys, list)
        or not 1 <= len(keys) <= 16
        or len(set(keys)) != len(keys)
    ):
        raise ValueError("expected membership requires 1–16 unique output keys")
    for key in keys:
        stable_key(key, "output key")
    if len(canonical(params)) > 16384:
        raise ValueError("parameters exceed 16 KiB")
    return deepcopy(assignment)
