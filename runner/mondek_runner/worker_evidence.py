# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Exact JSON-lines accounting for collected facts and optional detail text."""

import json
from collections.abc import Callable
from typing import Any

from ._text import DETAIL_OMISSION, truncate_utf8

MAX_CAPTURE_BYTES = 64 * 1024
MAX_COLLECTION_STDERR_BYTES = 4 * 1024
MAX_COLLECTION_STDOUT_BYTES = MAX_CAPTURE_BYTES - MAX_COLLECTION_STDERR_BYTES
MAX_TERMINAL_BYTES = 2 * 1024


def encode_record(record: dict[str, Any]) -> bytes:
    return (
        json.dumps(
            record, ensure_ascii=False, separators=(",", ":"), allow_nan=False
        ).encode("utf-8")
        + b"\n"
    )


def fit_text(
    value: str,
    record: Callable[[str], dict[str, Any]],
    budget: int,
    *,
    suffix: str,
    raw_limit: int,
) -> dict[str, Any] | None:
    whole = record(value)
    if len(encode_record(whole)) <= budget:
        return whole
    if len(encode_record(record(suffix))) > budget:
        return None

    prefix = truncate_utf8(value, raw_limit - len(suffix.encode("utf-8")))
    low, high = 0, len(prefix)
    while low < high:
        middle = (low + high + 1) // 2
        if len(encode_record(record(prefix[:middle] + suffix))) <= budget:
            low = middle
        else:
            high = middle - 1
    return record(prefix[:low] + suffix)


class EvidenceWriter:
    def __init__(self, emit: Callable[[dict[str, Any]], None], raw_details_limit: int):
        self.emit = emit
        self.raw_details_limit = raw_details_limit
        self.remaining = MAX_COLLECTION_STDOUT_BYTES - MAX_TERMINAL_BYTES
        self.details: list[tuple[str, str]] = []

    def result(self, value: dict[str, Any]) -> None:
        details = value.get("details")
        facts = value if details is None else {**value, "details": DETAIL_OMISSION}
        record = {"result": facts}
        size = len(encode_record(record))
        if size > self.remaining:
            raise ValueError("worker fixed result data exceeded the output budget")
        self.emit(record)
        self.remaining -= size
        if details is not None:
            self.details.append((value["key"], details))

    def finish(self, complete: bool, diagnostic: str | None) -> None:
        full = [{"detail": {"key": key, "text": text}} for key, text in self.details]
        if sum(len(encode_record(record)) for record in full) <= self.remaining:
            for record in full:
                self.emit(record)
        else:
            self._budget_details()

        if diagnostic is None:
            self.emit({"complete": complete, "diagnostic": None})
            return

        terminal = fit_text(
            diagnostic,
            lambda text: {"complete": complete, "diagnostic": text},
            MAX_TERMINAL_BYTES,
            suffix="…",
            raw_limit=2048,
        )
        assert terminal is not None
        self.emit(terminal)

    def _budget_details(self) -> None:
        for index, (key, details) in enumerate(self.details):
            budget = self.remaining // (len(self.details) - index)
            replacement = fit_text(
                details,
                lambda text, key=key: {"detail": {"key": key, "text": text}},
                budget,
                suffix="\n\n" + DETAIL_OMISSION,
                raw_limit=self.raw_details_limit,
            )
            if replacement is not None:
                self.emit(replacement)
                self.remaining -= len(encode_record(replacement))
