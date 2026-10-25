# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Small ordinary-Python authoring API supporting sync and async consumers."""

from __future__ import annotations

import inspect
from collections.abc import AsyncIterator, Callable, Mapping
from dataclasses import asdict, dataclass, fields
from datetime import UTC, datetime
from typing import TYPE_CHECKING, Any, Literal, TypeVar

from ._text import truncate_utf8 as truncate_utf8

if TYPE_CHECKING:
    from .authoring import Environment, Output, Parameter, Placement
    from .discovery import Discovery

_CheckFunction = TypeVar("_CheckFunction", bound=Callable[..., Any])

Health = Literal["OK", "WARN", "CRIT", "UNKNOWN"]
MAX_DETAILS_BYTES = 16 * 1024
MAX_FINDINGS = 128
MAX_IMPACTS = 16
_HEALTH_ORDER: dict[Health, int] = {"OK": 0, "WARN": 1, "UNKNOWN": 2, "CRIT": 3}


class _CollectionTime:
    pass


_COLLECTION_TIME = _CollectionTime()


def _source_time(value: str | None | _CollectionTime) -> str | None:
    return timestamp() if isinstance(value, _CollectionTime) else value


def timestamp() -> str:
    return datetime.now(UTC).isoformat(timespec="microseconds").replace("+00:00", "Z")


def validate_summary(summary: str) -> None:
    """Authored summaries must match the controller's bounded text contract."""
    if not isinstance(summary, str) or "\x00" in summary:
        raise ValueError("result summary must be text within 2048 bytes without NUL")
    try:
        size = len(summary.encode("utf-8"))
    except UnicodeEncodeError as error:
        raise ValueError("result summary must be valid UTF-8 text") from error
    if size > 2048:
        raise ValueError("result summary exceeds 2048-byte output cap")


def validate_details(details: str | None) -> None:
    """Details are bounded plain text, never interpreted markup or binary data."""
    if details is None:
        return
    if not isinstance(details, str) or "\x00" in details:
        raise ValueError("result details must be plain text without NUL")
    try:
        size = len(details.encode("utf-8"))
    except UnicodeEncodeError as error:
        raise ValueError("result details must be valid UTF-8 text") from error
    if size > MAX_DETAILS_BYTES:
        raise ValueError("result details exceeds 16384-byte output cap")


def validate_invocation_scope(value: Mapping[str, Any]) -> None:
    """Output/result extensions cannot silently override their declared scope."""
    if "environment" in value or "environment_label" in value:
        raise ValueError(
            "one monitored environment per invocation; "
            "use separate environment bindings, not output/result environment fields"
        )


@dataclass(frozen=True)
class Impact:
    """A consumer-declared material consequence with a stable identity."""

    key: str
    label: str

    def __post_init__(self) -> None:
        from .authoring import label, stable_key

        stable_key(self.key, "impact key")
        label(self.label, "impact label")


def validate_impacts(impacts: tuple[Impact, ...]) -> None:
    if not isinstance(impacts, tuple) or len(impacts) > MAX_IMPACTS:
        raise ValueError("result impacts require a tuple of at most 16 Impact values")
    seen: set[str] = set()
    for impact in impacts:
        if not isinstance(impact, Impact):
            raise ValueError("result impacts require Impact values")
        # Recheck even frozen values at the serialization boundary.
        impact.__post_init__()
        if impact.key in seen:
            raise ValueError("result impact keys must be distinct")
        seen.add(impact.key)


@dataclass(frozen=True)
class Result:
    key: str
    health: Health
    summary: str
    value: float | int | None = None
    source_at: str | None = None
    details: str | None = None
    impacts: tuple[Impact, ...] = ()
    discovery: Discovery | None = None

    def __post_init__(self) -> None:
        validate_summary(self.summary)
        validate_details(self.details)
        validate_impacts(self.impacts)
        if self.discovery is not None:
            from .discovery import Discovery

            if not isinstance(self.discovery, Discovery):
                raise ValueError("result discovery requires a Discovery value")
            self.discovery.to_dict()
        if self.health == "OK" and self.impacts:
            raise ValueError("OK results cannot declare failure impacts")

    def to_dict(self) -> dict[str, Any]:
        self.__post_init__()
        result = {
            field.name: getattr(self, field.name)
            for field in fields(self)
            if field.name != "discovery"
        }
        if self.discovery is not None:
            result["discovery"] = self.discovery.to_dict()
        validate_invocation_scope(result)
        if self.details is None:
            del result["details"]
        if self.impacts:
            result["impacts"] = [asdict(impact) for impact in self.impacts]
        else:
            del result["impacts"]
        return result


class ResultBuilder:
    """Accumulate bounded findings about one fixed output into a frozen result.

    Builder-level impacts describe the failed check and apply only to non-OK
    snapshots. Findings add explicit impacts; their prose never creates identities.
    """

    def __init__(
        self,
        key: str,
        *,
        ok_summary: str,
        fail_summary: str,
        base_details: str | None = None,
        value: float | int | None = None,
        source_at: str | None | _CollectionTime = _COLLECTION_TIME,
        impacts: tuple[Impact, ...] = (),
        discovery: Discovery | None = None,
    ) -> None:
        validate_summary(ok_summary)
        validate_summary(fail_summary)
        validate_details(base_details)
        validate_impacts(impacts)
        self._discovery = discovery
        self._key = key
        self._ok_summary = ok_summary
        self._fail_summary = fail_summary
        self._details = base_details
        self._value = value
        self._source_at = _source_time(source_at)
        self._health: Health = "OK"
        self._count = 0
        self._failure: str | None = None
        self._impacts = {impact.key: impact for impact in impacts}

    def add(
        self,
        health: Health,
        summary: str,
        *,
        details: str | None = None,
        impacts: tuple[Impact, ...] = (),
    ) -> ResultBuilder:
        """Append a finding in call order; bounds failures invalidate the builder."""
        if self._failure is not None:
            raise ValueError(self._failure)
        try:
            if health not in _HEALTH_ORDER:
                raise ValueError("invalid finding health")
            if self._count >= MAX_FINDINGS:
                raise ValueError("result builder exceeds 128 findings")
            validate_summary(summary)
            validate_details(details)
            validate_impacts(impacts)
            if health == "OK" and impacts:
                raise ValueError("OK findings cannot declare failure impacts")
            merged_impacts = self._impacts.copy()
            for impact in impacts:
                if (
                    impact.key in merged_impacts
                    and merged_impacts[impact.key] != impact
                ):
                    raise ValueError(
                        "conflicting labels for result impact " + impact.key
                    )
                merged_impacts[impact.key] = impact
            if len(merged_impacts) > MAX_IMPACTS:
                raise ValueError("result builder exceeds 16 impacts")
            finding = f"[{health}] {summary}"
            if details is not None:
                finding += "\n" + details
            combined = (
                self._details + "\n\n" + finding
                if self._details is not None
                else finding
            )
            validate_details(combined)
        except ValueError as error:
            self._failure = str(error)
            raise
        self._details = combined
        self._impacts = merged_impacts
        self._count += 1
        if _HEALTH_ORDER[health] > _HEALTH_ORDER[self._health]:
            self._health = health
        return self

    def ok(self, summary: str, *, details: str | None = None) -> ResultBuilder:
        return self.add("OK", summary, details=details)

    def warn(
        self,
        summary: str,
        *,
        details: str | None = None,
        impacts: tuple[Impact, ...] = (),
    ) -> ResultBuilder:
        return self.add("WARN", summary, details=details, impacts=impacts)

    def crit(
        self,
        summary: str,
        *,
        details: str | None = None,
        impacts: tuple[Impact, ...] = (),
    ) -> ResultBuilder:
        return self.add("CRIT", summary, details=details, impacts=impacts)

    def unknown(
        self,
        summary: str,
        *,
        details: str | None = None,
        impacts: tuple[Impact, ...] = (),
    ) -> ResultBuilder:
        return self.add("UNKNOWN", summary, details=details, impacts=impacts)

    def finalize(self) -> Result:
        """Snapshot current findings without changing their original source time."""
        if self._failure is not None:
            raise ValueError(self._failure)
        return Result(
            self._key,
            self._health,
            self._ok_summary if self._health == "OK" else self._fail_summary,
            self._value,
            self._source_at,
            self._details,
            tuple(self._impacts.values()) if self._health != "OK" else (),
            self._discovery,
        )


def build_result(
    key: str,
    *,
    ok_summary: str,
    fail_summary: str,
    base_details: str | None = None,
    value: float | int | None = None,
    source_at: str | None | _CollectionTime = _COLLECTION_TIME,
    impacts: tuple[Impact, ...] = (),
    discovery: Discovery | None = None,
) -> ResultBuilder:
    return ResultBuilder(
        key,
        ok_summary=ok_summary,
        fail_summary=fail_summary,
        base_details=base_details,
        value=value,
        source_at=source_at,
        impacts=impacts,
        discovery=discovery,
    )


def check(
    *,
    expected_keys: tuple[str, ...] = (),
    id: str | None = None,
    name: str | None = None,
    outputs: tuple[Output, ...] = (),
    params: Mapping[str, Any] | None = None,
    parameters: Mapping[str, Parameter] | None = None,
    parameter_contract: str | None = None,
    comparisons: tuple[tuple[str, Literal["lt", "lte"], str], ...] = (),
    interval_seconds: float = 30,
    timeout_seconds: float = 5,
    freshness_seconds: float = 90,
    placement: Placement | None = None,
    environments: tuple[Environment, ...] = (),
) -> Callable[[_CheckFunction], _CheckFunction]:
    """Declare fixed coverage; a missing output never removes an expectation."""
    if parameter_contract is not None:
        from .authoring import stable_key

        stable_key(parameter_contract, "parameter contract")
        if not parameters:
            raise ValueError(
                "parameter contracts require explicit UI-delegated parameters"
            )
    if outputs:
        if expected_keys:
            raise ValueError("declare outputs or expected_keys, not both")
        expected_keys = tuple(output.key for output in outputs)
    if not expected_keys or len(expected_keys) > 16:
        raise ValueError("checks require between 1 and 16 expected keys")
    if len(set(expected_keys)) != len(expected_keys):
        raise ValueError("expected keys must be unique")
    if placement is not None:
        from .authoring import Placement

        if not isinstance(placement, Placement):
            raise ValueError("placement requires a Placement declaration")
    if not isinstance(environments, tuple):
        raise ValueError("environments requires a tuple of distinct Environment values")
    if environments:
        from .authoring import Environment

        if (
            len(environments) > 512
            or any(
                not isinstance(environment, Environment) for environment in environments
            )
            or len({environment.id for environment in environments})
            != len(environments)
        ):
            raise ValueError(
                "environments requires a tuple of distinct Environment values"
            )

    def decorate(function: _CheckFunction) -> _CheckFunction:
        definition: dict[str, Any] = {
            "id": id,
            "name": name,
            "outputs": outputs,
            "params": dict(params or {}),
            "parameters": dict(parameters or {}),
            "comparisons": comparisons,
            "interval_seconds": interval_seconds,
            "timeout_seconds": timeout_seconds,
            "freshness_seconds": freshness_seconds,
        }
        if parameter_contract is not None:
            definition["parameter_contract"] = parameter_contract
        if placement is not None:
            definition["placement"] = placement
        if environments:
            definition["environments"] = environments
        # Metadata does not change the callable's public signature or identity.
        setattr(function, "expected_keys", expected_keys)  # noqa: B010
        setattr(function, "mondek_definition", definition)  # noqa: B010
        return function

    return decorate


async def evaluate(function: Callable, **kwargs: Any) -> AsyncIterator[Result]:
    """Evaluate a result, iterable, coroutine or async generator without caching."""
    output = function(**kwargs)
    if inspect.isawaitable(output):
        output = await output
    if isinstance(output, (Result, ResultBuilder)):
        yield output.finalize() if isinstance(output, ResultBuilder) else output
    elif hasattr(output, "__aiter__"):
        async for result in output:
            yield result.finalize() if isinstance(result, ResultBuilder) else result
    else:
        for result in output:
            yield result.finalize() if isinstance(result, ResultBuilder) else result


def ok(
    key: str,
    summary: str,
    *,
    value: float | int | None = None,
    source_at: str | None | _CollectionTime = _COLLECTION_TIME,
    details: str | None = None,
    discovery: Discovery | None = None,
) -> Result:
    return Result(
        key,
        "OK",
        summary,
        value,
        _source_time(source_at),
        details,
        discovery=discovery,
    )


def warn(
    key: str,
    summary: str,
    *,
    value: float | int | None = None,
    source_at: str | None | _CollectionTime = _COLLECTION_TIME,
    details: str | None = None,
    impacts: tuple[Impact, ...] = (),
    discovery: Discovery | None = None,
) -> Result:
    return Result(
        key,
        "WARN",
        summary,
        value,
        _source_time(source_at),
        details,
        impacts,
        discovery,
    )


def crit(
    key: str,
    summary: str,
    *,
    value: float | int | None = None,
    source_at: str | None | _CollectionTime = _COLLECTION_TIME,
    details: str | None = None,
    impacts: tuple[Impact, ...] = (),
    discovery: Discovery | None = None,
) -> Result:
    return Result(
        key,
        "CRIT",
        summary,
        value,
        _source_time(source_at),
        details,
        impacts,
        discovery,
    )


def unknown(
    key: str,
    summary: str,
    *,
    value: float | int | None = None,
    source_at: str | None | _CollectionTime = _COLLECTION_TIME,
    details: str | None = None,
    impacts: tuple[Impact, ...] = (),
    discovery: Discovery | None = None,
) -> Result:
    return Result(
        key,
        "UNKNOWN",
        summary,
        value,
        _source_time(source_at),
        details,
        impacts,
        discovery,
    )
