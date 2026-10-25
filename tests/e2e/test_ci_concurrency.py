# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Real child processes prove CI lanes overlap and retain failure evidence."""

import json
import os
from pathlib import Path
import shlex
import sys
import tempfile
import unittest
from unittest.mock import patch

from scripts import ci


class ConcurrentCITests(unittest.TestCase):
    def test_smoke_lanes_overlap_and_finish_other_suites_after_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            for relative in ("scripts", "tests/e2e", "tests/browser", ".local/ci"):
                (root / relative).mkdir(parents=True)
            (root / ".local/ci/images.json").write_text(
                json.dumps(
                    {
                        f"{name}/Dockerfile": {"id": f"sha256:{name}"}
                        for name in ("controller", "runner")
                    }
                )
            )
            worker = """
from pathlib import Path
import sys, time
name = Path(__file__).stem
if name in {'acceptance', 'install'}:
    Path(name + '.started').touch()
    peer = 'install' if name == 'acceptance' else 'acceptance'
    deadline = time.monotonic() + 5
    while not Path(peer + '.started').exists():
        if time.monotonic() > deadline:
            raise RuntimeError('peer lane never started')
        time.sleep(0.01)
    Path(name + '.overlapped').touch()
print('output:' + name + ':' + ' '.join(sys.argv[1:]))
sys.exit(17 if name == 'acceptance' else 0)
"""
            for relative in (
                "scripts/runtime_licenses.py",
                "scripts/image_licenses.py",
                "tests/e2e/acceptance.py",
                "tests/e2e/install.py",
                "tests/e2e/gateway.py",
                "tests/browser/run.py",
            ):
                (root / relative).write_text(worker)
            with (
                patch.object(ci, "ROOT", root),
                patch.object(sys, "argv", ["ci.py", "packaged"]),
                patch.dict(os.environ, {"GITHUB_STEP_SUMMARY": str(root / "summary")}),
                self.assertRaisesRegex(SystemExit, "Real acceptance acceptance"),
            ):
                ci.main()
            self.assertTrue((root / "acceptance.overlapped").exists())
            self.assertTrue((root / "install.overlapped").exists())
            rows = json.loads((root / ".local/ci/packaged-timings.json").read_text())
            self.assertEqual(len(rows), 8)
            self.assertEqual(sum(row["returncode"] != 0 for row in rows), 1)
            self.assertEqual(len({row["log"] for row in rows}), 8)
            for row in rows:
                self.assertIn("output:", (root / row["log"]).read_text())
            self.assertIn("Browser lifecycle", [row["stage"] for row in rows])
            self.assertIn("| Fail |", (root / "summary").read_text())

    def test_native_lanes_share_preparation_and_wait_for_both_before_checks(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            (root / "scripts").mkdir()
            worker = root / "scripts/worker.py"
            worker.write_text("""
from pathlib import Path
import sys, time
stage = sys.argv[1]
if stage == 'test-prepare':
    Path('prepared').touch()
elif stage in {'test-python', 'test-controller'}:
    assert Path('prepared').exists()
    Path(stage + '.started').touch()
    peer = 'test-python' if stage == 'test-controller' else 'test-controller'
    deadline = time.monotonic() + 5
    while not Path(peer + '.started').exists():
        if time.monotonic() > deadline:
            raise RuntimeError('peer lane never started')
        time.sleep(0.01)
    Path(stage + '.finished').touch()
else:
    assert Path('test-python.finished').exists()
    assert Path('test-controller.finished').exists()
print(stage)
""")
            (root / "scripts/mondek").write_text(
                f'exec {shlex.quote(sys.executable)} {shlex.quote(str(worker))} "$1"\n'
            )
            (root / "controller").mkdir()
            with (
                patch.object(ci, "ROOT", root),
                patch.object(sys, "argv", ["ci.py", "native"]),
                patch.dict(
                    os.environ, {"PATH": str(root) + os.pathsep + os.environ["PATH"]}
                ),
            ):
                # Keep the advisory command local too; no real toolchain/services.
                mix = root / "mix"
                mix.write_text("#!/bin/sh\nexit 0\n")
                mix.chmod(0o755)
                ci.main()
            rows = json.loads((root / ".local/ci/native-timings.json").read_text())
            self.assertEqual(len(rows), 5)
            self.assertTrue(all(row["returncode"] == 0 for row in rows))
            self.assertEqual(rows[0]["stage"], "Prepare native tests")
            self.assertEqual(rows[3]["stage"], "Code style, types and installed SDK")


if __name__ == "__main__":
    unittest.main()
