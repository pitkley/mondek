# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Execution-scoped controller state and explicit stale-read access."""

from __future__ import annotations

import json
import math
import socket
import time
import urllib.error
from dataclasses import dataclass
from datetime import datetime
from http.client import RemoteDisconnected
from typing import Any, Protocol
from uuid import UUID

from .connection_diagnostics import STATE_REJECTION_CODES, ControllerHTTPError
from .consumer_state_cache import StateCache, cache_identity
from .transport import WireTimeout, post_json


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


@dataclass(frozen=True)
class FreshState:
    """A controller-verified entry or authoritative miss."""

    entry: StateEntry | None


@dataclass(frozen=True)
class StaleState:
    """A prior read, with original timestamps and no write version."""

    value: Any
    updated_at: str
    expires_at: str | None
    age_seconds: float


@dataclass(frozen=True)
class StateUnavailable:
    """The transport failed and no eligible cached value is available."""


type StateRead = FreshState | StaleState | StateUnavailable


class _ReadTransportFailure(StateError):
    def __init__(self, result: StaleState | StateUnavailable):
        super().__init__("Controller state is unavailable")
        self.result = result


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


def read_state(store: StateStore, key: str, *, max_age_seconds: float) -> StateRead:
    """Read authoritatively first, allowing an explicitly bounded stale value."""
    if type(max_age_seconds) not in (float, int) or not 0 < max_age_seconds <= 86_400:
        raise StateError(
            "State cache age must be greater than zero and at most one day"
        )
    if isinstance(store, _StateClient):
        try:
            return FreshState(store._request("get", key, max_age=max_age_seconds))
        except _ReadTransportFailure as error:
            return error.result
    return FreshState(store.get(key))


def _transport_failure(error: Exception) -> bool:
    if isinstance(error, urllib.error.HTTPError):
        return False
    if isinstance(error, urllib.error.URLError):
        return isinstance(
            error.reason, (socket.gaierror, ConnectionRefusedError, TimeoutError)
        )
    return isinstance(error, (ConnectionRefusedError, RemoteDisconnected, WireTimeout))


def _aware_time(value: Any) -> datetime | None:
    try:
        if isinstance(value, str) and len(value) <= 40:
            time_value = datetime.fromisoformat(value)
            if time_value.tzinfo is not None:
                return time_value
    except (TypeError, ValueError, OverflowError):
        pass
    return None


def _cache_expiry(
    expires_at: str | None, observed_at: Any, started: float
) -> float | None:
    if expires_at is None:
        return None
    expiry = _aware_time(expires_at)
    observed = _aware_time(observed_at)
    if expiry is not None and observed is not None:
        return started + (expiry - observed).total_seconds()
    return started


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
        cache: StateCache | None = None,
    ):
        self.url = url
        self.identity = identity or {}
        self.scope = scope
        self.budget = budget or _Budget(deadline)
        self.cache = cache

    def for_check(self) -> StateStore:
        return _StateClient(
            self.url, self.identity, scope="check", budget=self.budget, cache=self.cache
        )

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

    def _request(
        self, operation: str, key: str, *, max_age: float | None = None, **fields: Any
    ) -> StateEntry | None:
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
        mutation = operation != "get"
        deadline = self.budget.deadline
        cache = self.cache
        cache_key, address = (
            cache_identity(self.url, self.identity, self.scope, key)
            if cache
            else ("", "")
        )
        epoch = cache.snapshot(deadline) if cache and not mutation else None
        pending = False
        if cache and mutation:
            try:
                pending = cache.begin_mutation(address, deadline)
            except OSError:
                raise StateError(
                    "Local state cache could not invalidate the address"
                ) from None

        started = time.monotonic()
        remaining = deadline - started
        if remaining <= 0:
            if cache and pending:
                cache.finish_mutation()
            raise StateError("State execution deadline or 64-call budget exceeded")

        self.budget.calls += 1
        verified_mutation = False
        invalidate_read = False
        remembered: dict[str, Any] | None = None
        observed_version = None
        expiry = None
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
                verified_mutation = mutation and response.get("version") == 1
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
                invalidate_read = status == "missing"
                verified_mutation = status == "deleted"
                return None
            e = response["entry"]
            UUID(e["version"])
            if (
                not isinstance(e["updated_at"], str)
                or not (e["expires_at"] is None or isinstance(e["expires_at"], str))
                or value_bytes(e["value"]) > 65_536
            ):
                raise ValueError("Invalid state entry")
            verified_mutation = mutation
            if not mutation:
                observed_version = e["version"]
            if (
                epoch is not None
                and max_age is not None
                and _aware_time(e["updated_at"]) is not None
            ):
                expiry = _cache_expiry(
                    e["expires_at"], response.get("observed_at"), started
                )
                if expiry is None or expiry > time.monotonic():
                    remembered = {
                        field: e[field]
                        for field in ("value", "version", "updated_at", "expires_at")
                    }
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
                verified_mutation = mutation
                invalidate_read = not mutation
                raise StateError(
                    f"Controller state request rejected (HTTP {error.code})"
                ) from None
            raise StateWriteIndeterminate("State write outcome is unknown") from None
        except Exception as error:
            if mutation:
                raise StateWriteIndeterminate(
                    "State write outcome is unknown"
                ) from None
            if max_age is not None and _transport_failure(error):
                if time.monotonic() >= deadline:
                    raise StateError("State execution deadline exceeded") from None
                cached = (
                    cache.load(cache_key, epoch, max_age, deadline)
                    if cache and epoch is not None
                    else None
                )
                if time.monotonic() >= deadline:
                    raise StateError("State execution deadline exceeded") from None
                if cached is not None:
                    payload, age = cached
                    raise _ReadTransportFailure(
                        StaleState(
                            payload["value"],
                            payload["updated_at"],
                            payload["expires_at"],
                            age,
                        )
                    ) from None
                raise _ReadTransportFailure(StateUnavailable()) from None
            raise StateError(
                "Controller state is unavailable or returned an invalid response"
            ) from None
        finally:
            if cache:
                if pending and verified_mutation:
                    cache.finish_mutation()
                elif invalidate_read or (
                    observed_version is not None and epoch is None
                ):
                    try:
                        cache.invalidate(address, deadline)
                    except OSError:
                        raise StateError(
                            "Local state cache could not invalidate the address"
                        ) from None
                elif observed_version is not None and epoch is not None:
                    try:
                        cache.observe_entry(
                            cache_key,
                            address,
                            observed_version,
                            epoch,
                            started,
                            expiry,
                            remembered,
                            deadline,
                        )
                    except OSError:
                        raise StateError(
                            "Local state cache could not record the read"
                        ) from None
