# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""An optional installation policy, generated with ordinary local Python."""

import json

from settings import DISK_CONTRACT, DISK_DEFAULTS, SOURCE_ID


def manifest() -> dict:
    return {
        "version": 1,
        "project": "policy-example",
        "rules": [
            {
                "key": "production-disk-limits",
                "name": "Production disk limits",
                "source_id": SOURCE_ID,
                "parameter_contract": DISK_CONTRACT,
                "environment": "production",
                "params": {**DISK_DEFAULTS, "warn_percent": 85, "crit_percent": 95},
            }
        ],
    }


if __name__ == "__main__":
    print(json.dumps(manifest(), indent=2))
