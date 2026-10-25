# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""A dedicated runner queries real Prometheus data for several remote subjects."""

from __future__ import annotations

import asyncio
import json
import math
import re
import urllib.parse
import urllib.request
from collections.abc import AsyncIterator, Callable, Mapping
from datetime import UTC, datetime
from typing import Any

from mondek_runner import App, Datasource, Environment, Output, Result, Target, check

MAX_RESPONSE_BYTES = 256 * 1024
MAX_SETTINGS_BYTES = 16 * 1024
DEFAULT_QUERY = "mondek_fixture_service_ready[30s]"
IDENTITY_LABEL = re.compile(r"[a-zA-Z_][a-zA-Z0-9_]*")
# Only raw range selectors preserve scrape timestamps. A PromQL subquery can
# manufacture evaluation timestamps even though its result is also a matrix.
RANGE_QUERY = re.compile(
    r'[a-zA-Z_:][a-zA-Z0-9_:]*(?:\{(?:[^{}"\\]|"(?:[^"\\]|\\.)*")*\})?'
    r"\[(?:[0-9]+(?:ms|[smhdwy]))+\]"
)


def bounded_text(value: Any, maximum: int, what: str) -> str:
    if (
        not isinstance(value, str)
        or not value.strip()
        or len(value.encode()) > maximum
        or any(ord(character) < 32 or ord(character) == 127 for character in value)
    ):
        raise ValueError(
            f"{what} must be nonempty bounded text without control characters"
        )
    return value


def validate_collection(
    url: str, query: str, identity_label: str, measurement: str = "readiness"
) -> None:
    bounded_text(url, 2048, "Prometheus URL")
    parsed = urllib.parse.urlsplit(url)
    if (
        parsed.scheme not in ("http", "https")
        or not parsed.hostname
        or parsed.query
        or parsed.fragment
    ):
        raise ValueError("Prometheus URL must be an HTTP(S) base URL")
    bounded_text(query, 2048, "Prometheus query")
    if not RANGE_QUERY.fullmatch(query):
        raise ValueError(
            "Prometheus query must be a raw metric range selector, such as up[30s]"
        )
    if (
        not isinstance(identity_label, str)
        or len(identity_label) > 128
        or not IDENTITY_LABEL.fullmatch(identity_label)
    ):
        raise ValueError(
            "Prometheus identity label must be an explicit valid label name"
        )
    if measurement not in ("readiness", "scrape"):
        raise ValueError("Prometheus measurement must be readiness or scrape")


def unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("JSON contains a duplicate object key")
        result[key] = value
    return result


def parse_samples(raw: bytes, identity_label: str) -> dict[str, tuple[float, str]]:
    """Parse binary readiness, rejecting nonbinary values anywhere in a range."""
    return _parse_samples(raw, identity_label, binary=True)


def parse_numeric_samples(
    raw: bytes, identity_label: str
) -> dict[str, tuple[float, str]]:
    """Parse finite raw numeric samples without replacing their scrape time."""
    return _parse_samples(raw, identity_label, binary=False)


def _parse_samples(
    raw: bytes, identity_label: str, *, binary: bool
) -> dict[str, tuple[float, str]]:
    if len(raw) > MAX_RESPONSE_BYTES:
        raise ValueError("Prometheus response exceeds 256 KiB")
    data = json.loads(raw, object_pairs_hook=unique_object)
    if (
        not isinstance(data, dict)
        or data.get("status") != "success"
        or data.get("warnings")
    ):
        raise ValueError("Prometheus query failed or returned incomplete data")
    payload = data.get("data")
    if not isinstance(payload, dict) or payload.get("resultType") != "matrix":
        raise ValueError("Prometheus response is not a range vector")
    series_list = payload.get("result")
    if not isinstance(series_list, list) or len(series_list) > 512:
        raise ValueError("Prometheus response requires at most 512 series")
    samples = {}
    seen = set()
    latest_possible = datetime.now(UTC).timestamp()
    for series in series_list:
        if not isinstance(series, dict) or not isinstance(series.get("metric"), dict):
            raise ValueError("Prometheus series has malformed identity metadata")
        key = bounded_text(
            series["metric"].get(identity_label), 512, "Prometheus series identity"
        )
        if key in seen:
            raise ValueError(
                "Prometheus returned duplicate series identities; narrow the query or choose a unique label"
            )
        seen.add(key)
        values = series.get("values")
        if not isinstance(values, list) or len(values) > 1024:
            raise ValueError("Prometheus series requires at most 1024 range samples")
        previous = None
        for sample in values:
            if not isinstance(sample, list) or len(sample) != 2:
                raise ValueError("Prometheus range sample is malformed")
            source_time, raw_value = sample
            if type(source_time) not in (int, float) or not isinstance(raw_value, str):
                raise ValueError("Prometheus range sample types are malformed")
            if (
                not 946684800 <= source_time <= latest_possible
                or not math.isfinite(source_time)
                or (previous is not None and source_time <= previous)
            ):
                raise ValueError(
                    "Prometheus scrape timestamps must be finite and strictly ordered"
                )
            value = float(raw_value)
            if not math.isfinite(value):
                raise ValueError("Prometheus sample must be finite")
            if binary and value not in (0, 1):
                raise ValueError("Prometheus readiness must be zero or one")
            previous = source_time
            collected_at = datetime.fromtimestamp(source_time, UTC)
            samples[key] = (
                value,
                collected_at.isoformat(timespec="microseconds").replace("+00:00", "Z"),
            )
    return samples


def collect_samples(
    url: str, query: str, identity_label: str, *, numeric: bool = False
) -> dict[str, tuple[float, str]]:
    """One bounded query preserving the range's original scrape timestamps."""
    encoded = urllib.parse.urlencode({"query": query, "timeout": "2s"})
    with urllib.request.urlopen(
        f"{url.rstrip('/')}/api/v1/query?{encoded}", timeout=3
    ) as response:
        raw = response.read(MAX_RESPONSE_BYTES + 1)
    parser = parse_numeric_samples if numeric else parse_samples
    return parser(raw, identity_label)


class Prometheus(Datasource):
    def __init__(
        self,
        url: str,
        query: str = DEFAULT_QUERY,
        identity_label: str = "service",
        measurement: str = "readiness",
        expected_series: dict[str, str] | None = None,
    ):
        validate_collection(url, query, identity_label, measurement)
        self.url = url.rstrip("/")
        self.query = query
        self.identity_label = identity_label
        self.measurement = measurement
        self.expected_series = dict(
            expected_series
            if expected_series is not None
            else {"primary": "primary", "secondary": "secondary"}
        )
        if not 1 <= len(self.expected_series) <= 16:
            raise ValueError("Prometheus requires a bounded prepared series mapping")
        for key, series in self.expected_series.items():
            bounded_text(key, 128, "Prepared result key")
            bounded_text(series, 512, "Prepared Prometheus series identity")

    def collect(self) -> dict[str, tuple[float, str]]:
        # A range vector retains scrape timestamps. An instant query's outer
        # evaluation time alone would incorrectly refresh cached source evidence.
        return collect_samples(self.url, self.query, self.identity_label)


def make_check(
    *,
    targets: Mapping[str, Target],
    check_id: str = "service-readiness",
    check_name: str = "Service readiness from Prometheus",
    result_keys: Mapping[str, str] | None = None,
    result_labels: Mapping[str, str] | None = None,
) -> Callable[[Prometheus], AsyncIterator[Result]]:
    """Declare fixed results; register their private mapping with the datasource."""
    if not isinstance(targets, Mapping) or not 1 <= len(targets) <= 16:
        raise ValueError("Prometheus requires 1–16 explicitly mapped expected series")
    targets = dict(targets)
    for series, target in targets.items():
        bounded_text(series, 512, "Expected Prometheus series identity")
        if not isinstance(target, Target):
            raise ValueError(
                "Expected Prometheus series require explicit Target values"
            )
        target.to_dict()
    keys = (
        dict(result_keys)
        if result_keys is not None
        else {series: target.key for series, target in targets.items()}
    )
    labels = (
        dict(result_labels)
        if result_labels is not None
        else {series: target.label for series, target in targets.items()}
    )
    if (
        set(keys) != set(targets)
        or set(labels) != set(targets)
        or len(set(keys.values())) != len(keys)
    ):
        raise ValueError(
            "Prometheus results require one unique key and label per expected series"
        )
    targets_by_result = {keys[series]: target for series, target in targets.items()}

    @check(
        id=check_id,
        name=check_name,
        outputs=tuple(
            Output(keys[series], labels[series], target)
            for series, target in targets.items()
        ),
        interval_seconds=5,
        timeout_seconds=4,
        freshness_seconds=15,
    )
    async def readiness(prometheus: Prometheus) -> AsyncIterator[Result]:
        try:
            if set(prometheus.expected_series) != set(targets_by_result):
                raise ValueError(
                    "Prometheus prepared mapping does not match expected results"
                )
            samples = await asyncio.to_thread(prometheus.collect)
        except (
            OSError,
            ValueError,
            KeyError,
            TypeError,
            IndexError,
            OverflowError,
        ) as error:
            for key in keys.values():
                # Deployment URLs and access details remain private settings.
                yield Result(
                    key,
                    "UNKNOWN",
                    f"Prometheus collection unavailable ({type(error).__name__})",
                )
            return
        for key, target in targets_by_result.items():
            series = prometheus.expected_series[key]
            if series not in samples:
                yield Result(
                    key, "UNKNOWN", f"No recent Prometheus sample for {target.label}"
                )
                continue
            value, collected_at = samples[series]
            description = (
                f"{target.label} scrape {'succeeded' if value == 1 else 'failed'}"
                if prometheus.measurement == "scrape"
                else f"{target.label} is {'ready' if value == 1 else 'not ready'}"
            )
            yield Result(
                key,
                "OK" if value == 1 else "CRIT",
                f"{description} according to Prometheus",
                value,
                collected_at,
            )

    return readiness


def make_app(
    *,
    source_id: str,
    environment: Environment,
    url: str,
    query: str,
    identity_label: str,
    targets: Mapping[str, Target],
    measurement: str = "readiness",
    name: str = "Prometheus monitoring",
    check_id: str = "service-readiness",
    check_name: str = "Service readiness from Prometheus",
    result_keys: Mapping[str, str] | None = None,
    result_labels: Mapping[str, str] | None = None,
    construction_environment: Mapping[str, str | None] | None = None,
) -> App:
    """Freeze access, query and series bindings as source-owned private settings."""
    validate_collection(url, query, identity_label, measurement)
    consumer = App(
        source_id=source_id,
        name=name,
        environment=environment,
        construction_environment=construction_environment,
        checks=[
            make_check(
                targets=targets,
                check_id=check_id,
                check_name=check_name,
                result_keys=result_keys,
                result_labels=result_labels,
            )
        ],
    )
    consumer.register_datasource(
        Prometheus,
        url=url,
        query=query,
        identity_label=identity_label,
        measurement=measurement,
        expected_series={
            result_keys[series] if result_keys is not None else target.key: series
            for series, target in targets.items()
        },
    )
    return consumer


def app_from_settings(
    raw: str,
    *,
    construction_environment: Mapping[str, str | None] | None = None,
) -> App:
    if not isinstance(raw, str) or not raw or len(raw.encode()) > MAX_SETTINGS_BYTES:
        raise ValueError(
            "MONDEK_PROMETHEUS_SETTINGS must contain a JSON object within 16 KiB"
        )
    try:
        settings = json.loads(raw, object_pairs_hook=unique_object)
    except (ValueError, TypeError):
        raise ValueError(
            "MONDEK_PROMETHEUS_SETTINGS contains malformed or duplicate JSON fields"
        ) from None
    allowed = {
        "source_id",
        "environment",
        "environment_label",
        "name",
        "url",
        "query",
        "identity_label",
        "targets",
    }
    if (
        not isinstance(settings, dict)
        or set(settings) - allowed
        or not {"url", "targets"} <= settings.keys()
    ):
        raise ValueError(
            "Prometheus settings require url and explicit targets, with only documented fields"
        )
    targets = settings["targets"]
    if not isinstance(targets, dict) or not 1 <= len(targets) <= 16:
        raise ValueError(
            "Prometheus settings require 1–16 explicitly mapped expected series"
        )
    mapped = {}
    for series, target in targets.items():
        if not isinstance(target, dict) or set(target) != {"key", "label", "kind"}:
            raise ValueError(
                "Each Prometheus target requires an explicit key, label and kind"
            )
        mapped[series] = Target(**target)
    query = settings.get("query", "up[30s]")
    if not isinstance(query, str) or not re.match(r"up(?:\{|\[)", query):
        raise ValueError(
            "The scrape-health consumer requires an up metric range selector"
        )
    return make_app(
        source_id=settings.get("source_id", "prometheus-local"),
        environment=Environment(
            settings.get("environment", "local-prometheus"),
            settings.get("environment_label"),
        ),
        url=settings["url"],
        query=query,
        identity_label=settings.get("identity_label", "instance"),
        targets=mapped,
        measurement="scrape",
        name=settings.get("name", "Local Prometheus scrape health"),
        check_id="prometheus-up",
        check_name="Prometheus scrape health",
        construction_environment=construction_environment,
    )
