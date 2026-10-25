#!/usr/bin/env python3
# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Build and audit local runtime artifacts without starting monitoring services."""

from __future__ import annotations

import subprocess
import sys
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def main() -> None:
    subprocess.run(
        [sys.executable, str(ROOT / "scripts/runtime_licenses.py"), "--check"],
        cwd=ROOT,
        check=True,
    )
    run_id = "image-licenses-" + uuid.uuid4().hex[:12]
    output = ROOT / ".local/licenses/images" / run_id
    output.mkdir(parents=True)
    for kind in ["controller", "runner"]:
        tag = f"{run_id}-{kind}:local"
        subprocess.run(
            ["docker", "build", "--file", f"{kind}/Dockerfile", "--tag", tag, "."],
            cwd=ROOT,
            check=True,
        )
        subprocess.run(
            [
                sys.executable,
                str(ROOT / "scripts/image_licenses.py"),
                kind,
                tag,
                "--output",
                str(output / f"{kind}.json"),
            ],
            cwd=ROOT,
            check=True,
        )
    print(f"Image notice/ownership checks passed; reports: {output}")


if __name__ == "__main__":
    main()
