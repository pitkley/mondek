#!/usr/bin/env python3
# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Measure actual installed-consumer capacity without competing example runners."""

from __future__ import annotations

import argparse
import json
from datetime import UTC, datetime

from parity import ParityAcceptance


def run(group_size: int) -> None:
    proof = ParityAcceptance()
    proof.env.update(MONDEK_LOAD_GROUP_SIZE=str(group_size))
    print(
        f"Capacity project: {proof.project}; UI: {proof.base}; evidence: {proof.output}",
        flush=True,
    )
    success = False
    try:
        proof.run_step(
            f"500 real file results across {(500 + group_size - 1) // group_size} scheduled checks",
            proof.capacity,
        )
        success = True
    finally:
        try:
            for name, read in (
                ("overview", proof.overview),
                ("snapshot", proof.snapshot),
            ):
                try:
                    (proof.output / f"{name}.json").write_text(
                        json.dumps(read(), indent=2)
                    )
                except Exception:
                    pass
            (proof.output / "capacity-results.json").write_text(
                json.dumps(
                    {
                        "success": success,
                        "finished_at": datetime.now(UTC).isoformat(),
                        "project": proof.project,
                        "steps": proof.steps,
                    },
                    indent=2,
                )
            )
        finally:
            try:
                proof.compose(
                    "--profile", "capacity", "logs", "--no-color", "--tail", "250"
                )
            finally:
                try:
                    proof.compose(
                        "--profile", "capacity", "down", "--volumes", "--remove-orphans"
                    )
                finally:
                    proof.log.close()
        print(f"Evidence: {proof.output}", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--group-size", type=int, choices=[1, 10], default=10)
    args = parser.parse_args()
    run(args.group_size)
