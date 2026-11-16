# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Execution-scoped controller state access; never an offline cache."""

from __future__ import annotations

import json
import math
import time
import urllib.error
from dataclasses import dataclass
from typing import Any, Protocol
from uuid import UUID

from .connection_diagnostics import STATE_REJECTION_CODES, ControllerHTTPError
from .transport import post_json


class StateError(Exception):
    """State is unavailable or a request was rejected; safe to report UNKNOWN."""


class StateConflict(StateError):
    """The expected version did not match. Reread before deciding what to do."""


class StateWriteIndeterminate(StateError):
    """A dispatched mutation may have committed. It is never retried automatically."""


@dataclass(frozen=True)
class StateEntry:
    value: Any
    version: str
    updated_at: str
    expires_at: str | None


class StateStore(Protocol):
    def get(self, key: str) -> StateEntry | None: ...
    def put(
        self, key: str, value: Any, *, ttl_seconds: int | None = None
    ) -> StateEntry: ...
    def compare_and_set(
        self,
        key: str,
        expected_version: str,
        value: Any,
        *,
        ttl_seconds: int | None = None,
    ) -> StateEntry: ...
    def delete(self, key: str, *, expected_version: str | None = None) -> None: ...
    def for_check(self) -> StateStore: ...


@dataclass(frozen=True)
class CheckContext:
    state: StateStore


def value_bytes(value: Any, depth: int = 0) -> int:
    """ASCII JSON structural accounting, with 24 bytes per nonintegral float."""
    if depth > 32:
        raise ValueError("State JSON exceeds depth 32")
    if value is None:
        return 4
    if isinstance(value, bool):
        return 4 if value else 5
    if isinstance(value, float):
        if not math.isfinite(value):
            raise ValueError("State JSON numbers must be finite")
        if not value.is_integer():
            return 24
        value = int(value)
    if isinstance(value, int):
        size = len(str(abs(value)))
        if size > 4096:
            raise ValueError("State JSON integer exceeds 4096 digits")
        return size + (value < 0)
    if isinstance(value, str):
        value.encode("utf-8")
        if "\0" in value:
            raise ValueError("State JSON cannot contain NUL")
        return len(json.dumps(value, ensure_ascii=True))
    if isinstance(value, list):
        return (
            2 + max(0, len(value) - 1) + sum(value_bytes(v, depth + 1) for v in value)
        )
    if isinstance(value, dict) and all(isinstance(k, str) for k in value):
        return (
            2
            + max(0, len(value) - 1)
            + sum(
                value_bytes(k, depth + 1) + 1 + value_bytes(v, depth + 1)
                for k, v in value.items()
            )
        )
    raise ValueError("State values must be JSON")


def _normalize(value: Any) -> Any:
    if isinstance(value, float) and value.is_integer():
        return int(value)
    if isinstance(value, list):
        return [_normalize(v) for v in value]
    if isinstance(value, dict):
        return {k: _normalize(v) for k, v in value.items()}
    return value


class _Budget:
    def __init__(self, deadline: float):
        self.deadline = deadline
        self.calls = 0


class _StateClient:
    def __init__(
        self,
        url: str | None = None,
        identity: dict[str, Any] | None = None,
        *,
        deadline: float = 0,
        scope: str = "source",
        budget: _Budget | None = None,
    ):
        self.url = url
        self.identity = identity or {}
        self.scope = scope
        self.budget = budget or _Budget(deadline)

    def for_check(self) -> StateStore:
        return _StateClient(self.url, self.identity, scope="check", budget=self.budget)

    def get(self, key: str) -> StateEntry | None:
        return self._request("get", key)

    def put(
        self, key: str, value: Any, *, ttl_seconds: int | None = None
    ) -> StateEntry:
        entry = self._request("put", key, value=value, **self._ttl(ttl_seconds))
        assert entry is not None
        return entry

    def compare_and_set(
        self,
        key: str,
        expected_version: str,
        value: Any,
        *,
        ttl_seconds: int | None = None,
    ) -> StateEntry:
        entry = self._request(
            "compare_and_set",
            key,
            value=value,
            expected_version=expected_version,
            **self._ttl(ttl_seconds),
        )
        assert entry is not None
        return entry

    def delete(self, key: str, *, expected_version: str | None = None) -> None:
        fields = (
            {} if expected_version is None else {"expected_version": expected_version}
        )
        self._request("delete", key, **fields)

    @staticmethod
    def _ttl(ttl: int | None) -> dict[str, int]:
        if ttl is None:
            return {}
        if type(ttl) is not int or not 1 <= ttl <= 2_592_000:
            raise StateError("State TTL must be 1–2592000 seconds")
        return {"ttl_seconds": ttl}

    def _request(self, operation: str, key: str, **fields: Any) -> StateEntry | None:
        if not self.url:
            raise StateError(
                "Controller state is unavailable in local execution or preparation"
            )
        try:
            if (
                not isinstance(key, str)
                or not 1 <= len(key.encode()) <= 200
                or any(ord(c) < 32 or ord(c) == 127 for c in key)
            ):
                raise ValueError("Invalid state key")
            if "value" in fields and value_bytes(fields["value"]) > 65_536:
                raise ValueError("State value exceeds 64 KiB")
            if "expected_version" in fields and fields["expected_version"] != "missing":
                UUID(fields["expected_version"])
        except (ValueError, TypeError, AttributeError, RecursionError):
            raise StateError("Invalid state key, value or expected version") from None
        if "value" in fields:
            fields["value"] = _normalize(fields["value"])
        remaining = self.budget.deadline - time.monotonic()
        if remaining <= 0 or self.budget.calls >= 64:
            raise StateError("State execution deadline or 64-call budget exceeded")
        self.budget.calls += 1
        mutation = operation != "get"
        try:
            response = post_json(
                self.url + "/api/v1/runner/state",
                {
                    "version": 1,
                    **self.identity,
                    "scope": self.scope,
                    "operation": operation,
                    "key": key,
                    **fields,
                },
                min(5.0, remaining),
            )
            status = response.get("status")
            if status == "conflict":
                raise StateConflict("State version changed; reread before updating")
            expected = {
                "get": ("found", "missing"),
                "delete": ("deleted",),
                "put": ("stored",),
                "compare_and_set": ("stored",),
            }[operation]
            if response.get("version") != 1 or status not in expected:
                raise ValueError("Invalid state receipt")
            if status in ("deleted", "missing"):
                return None
            e = response["entry"]
            UUID(e["version"])
            if (
                not isinstance(e["updated_at"], str)
                or not (e["expires_at"] is None or isinstance(e["expires_at"], str))
                or value_bytes(e["value"]) > 65_536
            ):
                raise ValueError("Invalid state entry")
            return StateEntry(
                e["value"], e["version"], e["updated_at"], e["expires_at"]
            )
        except StateConflict:
            raise
        except urllib.error.HTTPError as error:
            if not mutation or (
                isinstance(error, ControllerHTTPError)
                and error.code in (400, 409, 422)
                and error.details.get("controller_code") in STATE_REJECTION_CODES
            ):
                raise StateError(
                    f"Controller state request rejected (HTTP {error.code})"
                ) from None
            raise StateWriteIndeterminate("State write outcome is unknown") from None
        except Exception:
            if mutation:
                raise StateWriteIndeterminate(
                    "State write outcome is unknown"
                ) from None
            raise StateError(
                "Controller state is unavailable or returned an invalid response"
            ) from None
