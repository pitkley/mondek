# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Bounded review evidence; choices propose source changes, never execute them."""

from __future__ import annotations

import json
from collections.abc import Mapping
from dataclasses import dataclass
from typing import Any

from .authoring import Parameter, label, stable_key, validate_params


def _text(value: Any, maximum: int, what: str) -> None:
    if not isinstance(value, str) or "\x00" in value:
        raise ValueError(f"{what} requires text without NUL")
    try:
        if len(value.encode("utf-8")) > maximum:
            raise ValueError(f"{what} exceeds {maximum} bytes")
    except UnicodeEncodeError as error:
        raise ValueError(f"{what} requires valid UTF-8") from error


def _object(value: Any, keys: set[str], what: str) -> None:
    if not isinstance(value, dict) or set(value) != keys:
        raise ValueError(f"{what} requires exactly {sorted(keys)}")


def validate_discovery(value: Any) -> None:
    """Validate untrusted wire evidence without normalizing or mutating it."""
    _object(
        value,
        {"version", "title", "instructions", "choices", "candidates", "omitted"},
        "discovery",
    )
    if type(value["version"]) is not int or value["version"] != 1:
        raise ValueError("unsupported discovery version")
    label(value["title"], "discovery title")
    _text(value["instructions"], 2048, "discovery instructions")
    if type(value["omitted"]) is not int or not 0 <= value["omitted"] <= 1_000_000:
        raise ValueError("discovery omitted requires an integer between 0 and 1000000")
    for collection, low, high in (("choices", 1, 8), ("candidates", 0, 100)):
        entries = value[collection]
        if not isinstance(entries, list) or not low <= len(entries) <= high:
            raise ValueError(f"discovery {collection} require {low}–{high} entries")
        seen = set()
        for entry in entries:
            keys = (
                {"key", "label", "details"}
                if collection == "candidates"
                else {"key", "label", "description", "parameter_schema", "params"}
            )
            _object(entry, keys, collection)
            stable_key(entry["key"], "discovery key")
            label(entry["label"], "discovery label")
            if entry["key"] in seen:
                raise ValueError(f"discovery {collection} keys must be distinct")
            seen.add(entry["key"])
            if collection == "candidates":
                _text(entry["details"], 1024, "candidate details")
                continue
            _text(entry["description"], 1024, "choice description")
            schema = entry["parameter_schema"]
            _object(schema, {"fields", "comparisons"}, "choice parameter schema")
            if (
                schema["comparisons"] != []
                or not isinstance(schema["fields"], dict)
                or len(schema["fields"]) > 8
            ):
                raise ValueError(
                    "choice parameters require at most 8 fields and no comparisons"
                )
            for key, spec in schema["fields"].items():
                stable_key(key, "choice parameter name")
                if (
                    not isinstance(spec, dict)
                    or not {"type", "label"} <= set(spec)
                    or set(spec)
                    - {
                        "type",
                        "label",
                        "unit",
                        "minimum",
                        "maximum",
                        "max_length",
                        "choices",
                    }
                ):
                    raise ValueError("invalid choice parameter field")
                label(spec["label"], "choice parameter label")
                if "unit" in spec:
                    label(spec["unit"], "choice parameter unit")
                    _text(spec["unit"], 64, "choice parameter unit")
                if any(item is None for item in spec.values()):
                    raise ValueError("choice parameter fields cannot be null")
                if "choices" in spec and (
                    not isinstance(spec["choices"], list) or not spec["choices"]
                ):
                    raise ValueError("parameter choices require a list")
                try:
                    Parameter(
                        **{**spec, "choices": tuple(spec.get("choices", []))}
                    ).to_dict()
                except (TypeError, UnicodeError) as error:
                    raise ValueError("invalid choice parameter field") from error
            if not isinstance(entry["params"], dict) or set(entry["params"]) != set(
                schema["fields"]
            ):
                raise ValueError("choice params must exactly match declared fields")
            validate_params(entry["params"], schema, entry["params"])
    try:
        encoded = json.dumps(
            value, ensure_ascii=True, allow_nan=False, separators=(",", ":")
        ).encode("utf-8")
    except (TypeError, UnicodeError) as error:
        raise ValueError("discovery requires UTF-8 JSON") from error
    if len(encoded) > 32768:
        raise ValueError("discovery exceeds 32768 bytes")


@dataclass(frozen=True)
class DiscoveryCandidate:
    key: str
    label: str
    details: str = ""

    def to_dict(self) -> dict[str, Any]:
        return {"key": self.key, "label": self.label, "details": self.details}


@dataclass(frozen=True)
class DiscoveryChoice:
    key: str
    label: str
    description: str = ""
    parameters: Mapping[str, Parameter] | None = None
    params: Mapping[str, Any] | None = None

    def to_dict(self) -> dict[str, Any]:
        if any(
            not isinstance(spec, Parameter) for spec in (self.parameters or {}).values()
        ):
            raise ValueError("choice parameters require Parameter declarations")
        return {
            "key": self.key,
            "label": self.label,
            "description": self.description,
            "parameter_schema": {
                "fields": {
                    key: spec.to_dict() for key, spec in (self.parameters or {}).items()
                },
                "comparisons": [],
            },
            "params": dict(self.params or {}),
        }


@dataclass(frozen=True)
class Discovery:
    title: str
    instructions: str
    choices: tuple[DiscoveryChoice, ...]
    candidates: tuple[DiscoveryCandidate, ...]
    omitted: int = 0

    def __post_init__(self) -> None:
        self.to_dict()

    def to_dict(self) -> dict[str, Any]:
        if not isinstance(self.choices, tuple) or any(
            not isinstance(item, DiscoveryChoice) for item in self.choices
        ):
            raise ValueError(
                "discovery choices require a tuple of DiscoveryChoice values"
            )
        if not isinstance(self.candidates, tuple) or any(
            not isinstance(item, DiscoveryCandidate) for item in self.candidates
        ):
            raise ValueError(
                "discovery candidates require a tuple of DiscoveryCandidate values"
            )
        value = {
            "version": 1,
            "title": self.title,
            "instructions": self.instructions,
            "choices": [item.to_dict() for item in self.choices],
            "candidates": [item.to_dict() for item in self.candidates],
            "omitted": self.omitted,
        }
        validate_discovery(value)
        return value
