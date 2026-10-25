# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""One-shot consumer execution without sessions, persistence or controller I/O."""

from __future__ import annotations

import asyncio
import json
import tempfile
import uuid
from pathlib import Path
from typing import Any

from ._text import diagnostic_text
from .authoring import MAX_CHECKS
from .bundle import snapshot
from .runtime import execute

HEALTH = ("OK", "WARN", "CRIT", "UNKNOWN")
MAX_RESULTS_OUTPUT_BYTES = 8 * 1024 * 1024


def include_result_evidence(
    outcome: dict[str, Any], results: dict[str, list[dict[str, Any]]]
) -> None:
    """Retain whole original results in stable order within the CLI JSON budget."""
    evidence = {
        "included_results": 0,
        "omitted_results": sum(len(values) for values in results.values()),
        "output_limit_bytes": MAX_RESULTS_OUTPUT_BYTES,
        "order": "check_key_then_result_key",
    }
    outcome["result_evidence"] = evidence
    for row in outcome["checks"]:
        row["results"] = []
        row["omitted_results"] = len(results[row["key"]])

    # Match __main__'s JSON encoding and final newline. Count each entry once,
    # rather than serializing the growing response for each of 8192 results.
    size = len(json.dumps(outcome, allow_nan=False).encode()) + 1
    if size > MAX_RESULTS_OUTPUT_BYTES:
        raise ValueError("batch summary exceeds the local result output limit")
    for row in outcome["checks"]:
        for result in sorted(results[row["key"]], key=lambda item: item["key"]):
            counters = (
                (evidence["included_results"], 1),
                (evidence["omitted_results"], -1),
                (row["omitted_results"], -1),
            )
            extra = len(json.dumps(result, allow_nan=False).encode())
            extra += 2 if row["results"] else 0
            extra += sum(
                len(str(value + change)) - len(str(value)) for value, change in counters
            )
            if size + extra > MAX_RESULTS_OUTPUT_BYTES:
                continue
            row["results"].append(result)
            row["omitted_results"] -= 1
            evidence["included_results"] += 1
            evidence["omitted_results"] -= 1
            size += extra


def select_checks(
    inventory: dict[str, Any], keys: list[str], all_checks: bool
) -> list[dict[str, Any]]:
    entries = inventory["checks"]
    if not entries:
        raise ValueError(
            "no checks selected for this runner context; "
            "use validate to inspect placement exclusions"
        )
    if len(entries) > MAX_CHECKS:
        raise ValueError("run requires a consumer with 1–512 registered checks")
    if len(set(keys)) != len(keys):
        raise ValueError("select each check key only once")
    available = {entry["key"] for entry in entries}
    if missing := set(keys) - available:
        raise ValueError("unregistered check keys: " + ", ".join(sorted(missing)))
    selected = [entry for entry in entries if all_checks or entry["key"] in keys]
    if not keys and not all_checks:
        if len(entries) != 1:
            raise ValueError("run requires --check or --all for this consumer")
        selected = entries
    return sorted(selected, key=lambda entry: entry["key"])


def assignment(
    entry: dict[str, Any], inventory: dict[str, Any], params: str | None
) -> dict[str, Any]:
    return {
        **entry,
        "kind": "python",
        "id": str(uuid.uuid4()),
        "generation": 1,
        "source_key": entry["key"],
        "source_id": inventory["source_id"],
        "source_revision": inventory["source_revision"],
        "expected_keys": [output["key"] for output in entry["outputs"]],
        "params": json.loads(params) if params is not None else entry["params"],
    }


async def run_selected(
    inventory: dict[str, Any],
    bundles: Path,
    *,
    keys: list[str],
    all_checks: bool,
    concurrency: int,
    params: str | None = None,
    include_results: bool = False,
) -> dict[str, Any]:
    if type(concurrency) is not int or not 1 <= concurrency <= 16:
        raise ValueError("concurrency must be an integer between 1 and 16")
    selected = select_checks(inventory, keys, all_checks)
    batch = all_checks or len(selected) > 1
    if params is not None and batch:
        raise ValueError(
            "--params requires one --check; batch runs use source defaults"
        )
    assignments = [assignment(entry, inventory, params) for entry in selected]
    if not batch:
        return await execute(assignments[0], bundle_dir=bundles)

    pending = iter(assignments)
    summaries: dict[str, dict[str, Any]] = {}
    result_evidence: dict[str, list[dict[str, Any]]] = {}

    async def worker() -> None:
        for config in pending:
            try:
                outcome = await execute(config, bundle_dir=bundles)
            except Exception as error:
                outcome = {
                    "complete": False,
                    "results": [],
                    "diagnostic": diagnostic_text(f"{type(error).__name__}: {error}"),
                }
            results = outcome["results"]
            if include_results:
                result_evidence[config["source_key"]] = results
            summaries[config["source_key"]] = {
                "key": config["source_key"],
                "label": config["label"],
                "collection": "complete" if outcome["complete"] else "incomplete",
                "expected_results": len(config["expected_keys"]),
                "received_results": len(results),
                "measured_health": {
                    health: sum(result["health"] == health for result in results)
                    for health in HEALTH
                },
                "diagnostic": outcome["diagnostic"],
            }

    async with asyncio.TaskGroup() as tasks:
        for _ in range(min(concurrency, len(assignments))):
            tasks.create_task(worker())

    checks = [summaries[entry["key"]] for entry in selected]
    complete_count = sum(item["collection"] == "complete" for item in checks)
    outcome = {
        "source_id": inventory["source_id"],
        "source_revision": inventory["source_revision"],
        "complete": complete_count == len(checks),
        "checks": checks,
        "summary": {
            "checks": len(checks),
            "complete_checks": complete_count,
            "incomplete_checks": len(checks) - complete_count,
            "measured_health": {
                health: sum(item["measured_health"][health] for item in checks)
                for health in HEALTH
            },
        },
    }
    if include_results:
        include_result_evidence(outcome, result_evidence)
    return outcome


async def local(
    command: str,
    consumer: str,
    *,
    keys: list[str],
    all_checks: bool,
    concurrency: int,
    params: str | None,
    include_results: bool = False,
) -> dict[str, Any]:
    with tempfile.TemporaryDirectory(prefix="mondek-local-") as directory:
        bundles = Path(directory)
        inventory = await snapshot(consumer, bundles)
        if command == "validate":
            return inventory
        return await run_selected(
            inventory,
            bundles,
            keys=keys,
            all_checks=all_checks,
            concurrency=concurrency,
            params=params,
            include_results=include_results,
        )
