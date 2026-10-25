# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Exercise hosted cleanup decisions without removing any real files."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class DiskCleanupTests(unittest.TestCase):
    def test_cleanup_is_conditional_and_removes_only_the_fixed_sdk_path(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            log = root / "sudo.log"
            for name, body in {
                "df": 'printf "Filesystem 1024-blocks Used Available Capacity Mounted\\nroot 150000000 50000000 %s 34%% /\\n" "$FREE_KIB"',
                "sudo": 'printf "%s\\n" "$@" > "$SUDO_LOG"',
            }.items():
                script = root / name
                script.write_text("#!/bin/sh\n" + body + "\n")
                script.chmod(0o755)
            for mode, free, cleanup, status in (
                ("smoke", 60 * 1024 * 1024, False, 0),
                ("smoke", 60 * 1024 * 1024 - 1, True, 0),
                ("full", 100 * 1024 * 1024, True, 0),
                ("browser", 100 * 1024 * 1024, True, 0),
                ("smoke", "invalid", False, 1),
                ("typo", 0, False, 2),
            ):
                with self.subTest(mode=mode, free=free):
                    log.unlink(missing_ok=True)
                    result = subprocess.run(
                        ["bash", str(ROOT / "scripts/ci-disk.sh")],
                        env=os.environ
                        | {
                            "PATH": directory + os.pathsep + os.environ["PATH"],
                            "MONDEK_CI_MODE": mode,
                            "FREE_KIB": str(free),
                            "SUDO_LOG": str(log),
                        },
                        capture_output=True,
                        text=True,
                    )
                    self.assertEqual(result.returncode, status, result.stderr)
                    self.assertEqual(log.exists(), cleanup)
                    if cleanup:
                        self.assertEqual(
                            log.read_text().splitlines(),
                            ["rm", "-rf", "--", "/usr/local/lib/android/sdk"],
                        )


if __name__ == "__main__":
    unittest.main()
