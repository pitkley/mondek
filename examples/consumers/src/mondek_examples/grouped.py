# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Independent volume and service observations of one explicit shared condition.

This example reads an owned HTTP fixture, not a host filesystem or Elasticsearch.
The fixture supplies measurements and their original time; the consumer owns
thresholds, target identities, the shared condition and declared write impact.
"""

from __future__ import annotations

import http.client
import json
import os
import re
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Any, Literal

from mondek_runner import (
    App,
    Condition,
    Datasource,
    Environment,
    Impact,
    Output,
    Result,
    RunnerContext,
    Target,
    check,
)
from mondek_runner.authoring import stable_key

Kind = Literal["volume", "elasticsearch"]
MAX_BODY = 4096
HTTP_TIMEOUT = 2
WARNING_PERCENT = 90
CRITICAL_PERCENT = 95
SHARED_CONDITION = Condition(
    "search-volume-pressure", "Search storage capacity", "grouped-example"
)
WRITES_BLOCKED = Impact("writes-blocked", "Search index writes are blocked")
VOLUME = Target("volume:search-data", "Search data volume", "volume")
ELASTICSEARCH = Target("service:elasticsearch", "Elasticsearch search index", "service")


@dataclass(frozen=True)
class Sample:
    used_percent: float | int
    writes_blocked: bool
    available: bool
    source_at: str


def parse_sample(value: Any) -> Sample:
    """Keep a bounded fixture reading honest about its values and original age."""
    fields = {"used_percent", "writes_blocked", "available", "source_at"}
    if not isinstance(value, dict) or set(value) != fields:
        raise ValueError("fixture sample requires exactly four declared fields")
    used = value["used_percent"]
    if type(used) not in (int, float) or not 0 <= used <= 100:
        raise ValueError("fixture used_percent must be a finite number in 0..100")
    if (
        type(value["writes_blocked"]) is not bool
        or type(value["available"]) is not bool
    ):
        raise ValueError(
            "fixture availability and blocked-write values must be boolean"
        )
    source_at = value["source_at"]
    if not isinstance(source_at, str) or not re.fullmatch(
        r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}(?:Z|\+00:00)", source_at
    ):
        raise ValueError("fixture source_at requires UTC with six fractional digits")
    measured = datetime.fromisoformat(source_at)
    if measured.year < 2000 or measured > datetime.now(UTC):
        raise ValueError("fixture source_at must be between year 2000 and collection")
    return Sample(used, value["writes_blocked"], value["available"], source_at)


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, file, code, message, headers, new_url):
        return None


def _settings(observer: str, kind: str, url: str) -> None:
    stable_key(observer, "grouped observer")
    if kind not in ("volume", "elasticsearch"):
        raise ValueError("grouped kind must be volume or elasticsearch")
    if not isinstance(url, str) or len(url) > 2048 or any(ord(c) < 32 for c in url):
        raise ValueError("grouped fixture URL must be bounded HTTP(S) text")
    parsed = urllib.parse.urlsplit(url)
    if (
        parsed.scheme not in ("http", "https")
        or not parsed.hostname
        or parsed.username is not None
        or parsed.password is not None
        or parsed.query
        or parsed.fragment
    ):
        raise ValueError("grouped fixture URL requires HTTP(S) without credentials")
    # Validate a declared port now, before inventory acceptance.
    parsed.port


class FixtureData(Datasource):
    def __init__(self, observer: str, kind: Kind, url: str):
        _settings(observer, kind, url)
        self.url = (
            url.rstrip("/")
            + "/grouped/"
            + urllib.parse.quote(observer, safe="")
            + "/"
            + kind
        )
        self.client = urllib.request.build_opener(
            urllib.request.ProxyHandler({}), _NoRedirect()
        )

    def read(self) -> Sample:
        request = urllib.request.Request(
            self.url,
            headers={"Accept": "application/json", "Accept-Encoding": "identity"},
        )
        try:
            response = self.client.open(request, timeout=HTTP_TIMEOUT)
        except urllib.error.HTTPError as error:
            error.close()
            raise
        with response:
            if response.status != 200:
                raise ValueError("fixture did not return HTTP 200")
            if response.headers.get("Content-Encoding", "identity") != "identity":
                raise ValueError("fixture response must not be compressed")
            raw = response.read(MAX_BODY + 1)
        if len(raw) > MAX_BODY:
            raise ValueError("fixture response exceeds 4096 bytes")
        return parse_sample(json.loads(raw.decode("utf-8")))


def inspect_sample(source: FixtureData, key: str, subject: str) -> Result:
    try:
        sample = source.read()
    except (OSError, http.client.HTTPException, UnicodeError, ValueError):
        return Result(
            key,
            "UNKNOWN",
            f"Cannot collect a valid {subject} measurement",
            details="The owned fixture was unreachable or returned an invalid sample.",
        )
    if not sample.available:
        return Result(
            key,
            "UNKNOWN",
            f"{subject} measurement is unavailable",
            source_at=sample.source_at,
            details="The fixture explicitly reported unavailable collection at its source timestamp.",
        )
    health = (
        "CRIT"
        if sample.writes_blocked or sample.used_percent >= CRITICAL_PERCENT
        else "WARN"
        if sample.used_percent >= WARNING_PERCENT
        else "OK"
    )
    return Result(
        key,
        health,
        f"{subject} is {sample.used_percent:g}% used"
        + ("; search index writes are blocked" if sample.writes_blocked else ""),
        sample.used_percent,
        sample.source_at,
        details=(
            "Read one independent observation from the owned fixture. "
            "Warning at 90% used; critical at 95% used or explicitly blocked writes. "
            "The shared condition is declared in source; target identity and evidence remain independent."
        ),
        impacts=(WRITES_BLOCKED,) if sample.writes_blocked else (),
    )


@check(
    id="volume-capacity",
    name="Search volume capacity",
    outputs=(Output("capacity", "Search volume used space", VOLUME, SHARED_CONDITION),),
    interval_seconds=3,
    timeout_seconds=5,
    freshness_seconds=12,
)
def volume_capacity(source: FixtureData) -> Result:
    return inspect_sample(source, "capacity", "Search data volume")


@check(
    id="elasticsearch-storage",
    name="Elasticsearch storage pressure",
    outputs=(
        Output("storage", "Elasticsearch storage", ELASTICSEARCH, SHARED_CONDITION),
    ),
    interval_seconds=3,
    timeout_seconds=5,
    freshness_seconds=12,
)
def elasticsearch_storage(source: FixtureData) -> Result:
    return inspect_sample(source, "storage", "Elasticsearch storage")


def make_app(
    observer: str,
    kind: Kind,
    url: str,
    environment: str = "production",
) -> App:
    _settings(observer, kind, url)
    application = App(
        source_id="linux-volume-monitoring"
        if kind == "volume"
        else "elasticsearch-monitoring",
        name="Independent storage condition example",
        environment=Environment(environment),
        runner=RunnerContext(observer, f"Storage observer {observer}"),
        construction_environment={
            "MONDEK_GROUPED_OBSERVER": observer,
            "MONDEK_GROUPED_KIND": kind,
            "MONDEK_GROUPED_FIXTURE_URL": url,
            "MONDEK_GROUPED_ENVIRONMENT": environment,
        },
        checks=[volume_capacity if kind == "volume" else elasticsearch_storage],
    )
    application.register_datasource(FixtureData, observer=observer, kind=kind, url=url)
    return application


app = make_app(
    os.environ.get("MONDEK_GROUPED_OBSERVER", "node-a"),
    os.environ.get("MONDEK_GROUPED_KIND", "volume"),
    os.environ.get("MONDEK_GROUPED_FIXTURE_URL", "http://target:8080"),
    os.environ.get("MONDEK_GROUPED_ENVIRONMENT", "production"),
)
