# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Reusable numeric thresholds over fixed Prometheus series and original age."""

from __future__ import annotations

import asyncio
import sys
from collections.abc import AsyncIterator, Callable, Mapping
from typing import Any, Literal

from mondek_runner import (
    App,
    Datasource,
    Environment,
    Output,
    Parameter,
    Result,
    Target,
    check,
)

from .prometheus import bounded_text, collect_samples, validate_collection

Direction = Literal["above", "below"]
MAX_NUMBER = sys.float_info.max


def _policy(unit: str, direction: Direction) -> None:
    bounded_text(unit, 64, "Numeric Prometheus unit")
    if direction not in ("above", "below"):
        raise ValueError("Numeric Prometheus direction must be above or below")


def _bounds(
    minimum: float | int, maximum: float | int
) -> tuple[float | int, float | int]:
    if (
        any(
            type(value) not in (int, float) or not -MAX_NUMBER <= value <= MAX_NUMBER
            for value in (minimum, maximum)
        )
        or minimum >= maximum
    ):
        raise ValueError("Numeric threshold bounds must be finite and increasing")
    # JSONB expands exponent notation. Export integral floats as their exact
    # integer value so a database round trip cannot change the declared schema.
    return tuple(
        int(value) if isinstance(value, float) and value.is_integer() else value
        for value in (minimum, maximum)
    )


def _thresholds(
    params: Mapping[str, Any],
    direction: Direction,
    minimum: float | int,
    maximum: float | int,
) -> None:
    if set(params) != {"warning", "critical"} or any(
        type(value) not in (int, float) or not minimum <= value <= maximum
        for value in params.values()
    ):
        raise ValueError(
            "Numeric thresholds require finite warning and critical values within the declared range"
        )
    warning, critical = params["warning"], params["critical"]
    if not (warning < critical if direction == "above" else critical < warning):
        raise ValueError(
            "Numeric thresholds must be strictly ordered for their direction"
        )


class NumericPrometheus(Datasource):
    """Private query, series bindings and source-owned measurement semantics."""

    def __init__(
        self,
        url: str,
        query: str,
        identity_label: str,
        expected_series: dict[str, str],
        unit: str,
        direction: Direction,
    ):
        validate_collection(url, query, identity_label)
        _policy(unit, direction)
        if not isinstance(expected_series, dict) or not 1 <= len(expected_series) <= 16:
            raise ValueError("Numeric Prometheus requires 1–16 prepared series")
        for key, series in expected_series.items():
            bounded_text(key, 128, "Prepared result key")
            bounded_text(series, 512, "Prepared Prometheus series identity")
        if len(set(expected_series.values())) != len(expected_series):
            raise ValueError("Numeric Prometheus requires distinct prepared series")
        self.url = url
        self.query = query
        self.identity_label = identity_label
        self.expected_series = dict(expected_series)
        self.unit = unit
        self.direction = direction

    def collect(self) -> dict[str, tuple[float, str]]:
        return collect_samples(self.url, self.query, self.identity_label, numeric=True)


def make_numeric_check(
    *,
    targets: Mapping[str, Target],
    unit: str,
    direction: Direction,
    warning: float | int,
    critical: float | int,
    minimum: float | int,
    maximum: float | int,
    check_id: str = "numeric-thresholds",
    check_name: str = "Numeric Prometheus thresholds",
    parameter_contract: str | None = None,
    interval_seconds: float = 5,
    timeout_seconds: float = 4,
    freshness_seconds: float = 20,
) -> Callable[..., AsyncIterator[Result]]:
    """Declare inclusive thresholds within an explicit source-owned range."""
    _policy(unit, direction)
    minimum, maximum = _bounds(minimum, maximum)
    defaults = {"warning": warning, "critical": critical}
    _thresholds(defaults, direction, minimum, maximum)
    if not isinstance(targets, Mapping) or not 1 <= len(targets) <= 16:
        raise ValueError("Numeric Prometheus requires 1–16 explicit targets")
    targets = dict(targets)
    for series, target in targets.items():
        bounded_text(series, 512, "Expected Prometheus series identity")
        if not isinstance(target, Target):
            raise ValueError("Numeric Prometheus requires explicit Target values")
        target.to_dict()
    by_key = {target.key: target for target in targets.values()}
    if len(by_key) != len(targets):
        raise ValueError("Numeric Prometheus result keys must be unique")
    comparison = (
        ("warning", "lt", "critical")
        if direction == "above"
        else ("critical", "lt", "warning")
    )

    @check(
        id=check_id,
        name=check_name,
        outputs=tuple(
            Output(target.key, target.label, target) for target in targets.values()
        ),
        params=defaults,
        parameters={
            key: Parameter(
                "number",
                f"{key.capitalize()} at or {direction}",
                unit,
                minimum,
                maximum,
            )
            for key in defaults
        },
        parameter_contract=parameter_contract,
        comparisons=(comparison,),
        interval_seconds=interval_seconds,
        timeout_seconds=timeout_seconds,
        freshness_seconds=freshness_seconds,
    )
    async def numeric(
        prometheus: NumericPrometheus, params: dict[str, Any]
    ) -> AsyncIterator[Result]:
        try:
            if prometheus.unit != unit or prometheus.direction != direction:
                raise ValueError(
                    "Numeric Prometheus datasource differs from declared policy"
                )
            _thresholds(params, direction, minimum, maximum)
            if set(prometheus.expected_series) != set(by_key):
                raise ValueError("Numeric Prometheus prepared coverage does not match")
            samples = await asyncio.to_thread(prometheus.collect)
        except (
            OSError,
            ValueError,
            KeyError,
            TypeError,
            IndexError,
            OverflowError,
        ) as error:
            for key in by_key:
                yield Result(
                    key,
                    "UNKNOWN",
                    f"Prometheus collection unavailable ({type(error).__name__})",
                )
            return
        for key, target in by_key.items():
            sample = samples.get(prometheus.expected_series[key])
            if sample is None:
                yield Result(
                    key, "UNKNOWN", f"No recent Prometheus sample for {target.label}"
                )
                continue
            value, source_at = sample
            if prometheus.direction == "above":
                critical_met, warning_met = (
                    value >= params["critical"],
                    value >= params["warning"],
                )
            else:
                critical_met, warning_met = (
                    value <= params["critical"],
                    value <= params["warning"],
                )
            health = "CRIT" if critical_met else "WARN" if warning_met else "OK"
            yield Result(
                key,
                health,
                f"{target.label}: {value:g} {prometheus.unit} according to Prometheus",
                value,
                source_at,
            )

    return numeric


def make_numeric_app(
    *,
    source_id: str,
    environment: Environment,
    url: str,
    query: str,
    identity_label: str,
    targets: Mapping[str, Target],
    unit: str,
    direction: Direction,
    warning: float | int,
    critical: float | int,
    minimum: float | int,
    maximum: float | int,
    check_id: str = "numeric-thresholds",
    check_name: str = "Numeric Prometheus thresholds",
    name: str = "Numeric Prometheus monitoring",
    parameter_contract: str | None = None,
    interval_seconds: float = 5,
    timeout_seconds: float = 4,
    freshness_seconds: float = 20,
    construction_environment: Mapping[str, str | None] | None = None,
) -> App:
    validate_collection(url, query, identity_label)
    function = make_numeric_check(
        targets=targets,
        unit=unit,
        direction=direction,
        warning=warning,
        critical=critical,
        minimum=minimum,
        maximum=maximum,
        check_id=check_id,
        check_name=check_name,
        parameter_contract=parameter_contract,
        interval_seconds=interval_seconds,
        timeout_seconds=timeout_seconds,
        freshness_seconds=freshness_seconds,
    )
    app = App(
        source_id=source_id,
        name=name,
        environment=environment,
        checks=[function],
        construction_environment=construction_environment,
    )
    app.register_datasource(
        NumericPrometheus,
        url=url,
        query=query,
        identity_label=identity_label,
        unit=unit,
        direction=direction,
        expected_series={target.key: series for series, target in targets.items()},
    )
    return app
