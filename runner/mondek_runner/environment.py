# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Current process settings with explicit default and required-value semantics."""

from __future__ import annotations

import os
from collections.abc import Mapping
from typing import overload


@overload
def get(
    name: str, default: str, *, environ: Mapping[str, str] | None = None
) -> str: ...


@overload
def get(
    name: str, default: None = None, *, environ: Mapping[str, str] | None = None
) -> str | None: ...


def get(
    name: str,
    default: str | None = None,
    *,
    environ: Mapping[str, str] | None = None,
) -> str | None:
    values = os.environ if environ is None else environ
    value = values.get(name)
    return default if value is None else value


def require(name: str) -> str:
    value = get(name)
    if value is None:
        raise KeyError(name)
    return value


DEFAULT_CONTROLLER_URL = "http://127.0.0.1:4000"
DEFAULT_STATE_DIR = ".mondek-state"
