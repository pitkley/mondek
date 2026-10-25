# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Exercise native test lane commands without installing dependencies or services."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class NativeCommandsTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name).resolve()
        for path in ("scripts", "controller/assets", "bin"):
            (self.root / path).mkdir(parents=True)
        shutil.copy(ROOT / "scripts/mondek", self.root / "scripts/mondek")
        stub = self.root / "bin/stub"
        stub.write_text(
            f"#!{sys.executable}\n"
            "import json, os, pathlib, sys\n"
            "entry = {'command': pathlib.Path(sys.argv[0]).name, "
            "'args': sys.argv[1:], 'cwd': os.getcwd(), "
            "'PGPORT': os.environ.get('PGPORT'), "
            "'MIX_ENV': os.environ.get('MIX_ENV')}\n"
            "with open(os.environ['CALL_LOG'], 'a') as stream:\n"
            "    stream.write(json.dumps(entry) + '\\n')\n"
            "if entry['command'] == os.environ.get('FAIL_COMMAND'):\n"
            "    sys.exit(23)\n"
        )
        stub.chmod(0o755)
        for command in ("mix", "uv", "npm", "node", "docker", "esbuild"):
            (self.root / "bin" / command).symlink_to(stub)
        self.log = self.root / "calls.jsonl"
        self.env = os.environ | {
            "DEVENV_ROOT": str(self.root),
            "PATH": str(self.root / "bin") + os.pathsep + os.environ["PATH"],
            "ESBUILD_PATH": str(self.root / "bin/esbuild"),
            "CALL_LOG": str(self.log),
        }

    def run_command(self, command, **env):
        result = subprocess.run(
            ["bash", str(self.root / "scripts/mondek"), command],
            env=self.env | env,
            capture_output=True,
            text=True,
        )
        calls = [json.loads(line) for line in self.log.read_text().splitlines()]
        return result, calls

    def test_python_lane_runs_all_suites_without_preparation_or_database_work(self):
        result, calls = self.run_command("test-python")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([call["command"] for call in calls], ["uv"] * 3)
        self.assertEqual(
            [call["args"][call["args"].index("-s") + 1] for call in calls],
            ["runner/tests", "tests/e2e", "examples/consumers/tests"],
        )

    def test_controller_lane_runs_one_test_process_in_the_test_database(self):
        result, calls = self.run_command("test-controller")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0]["command"], "mix")
        self.assertEqual(calls[0]["args"], ["test"])
        self.assertEqual(calls[0]["cwd"], str(self.root / "controller"))
        self.assertEqual(calls[0]["PGPORT"], "55433")
        self.assertEqual(calls[0]["MIX_ENV"], "test")

    def test_local_test_prepares_once_before_both_lanes(self):
        result, calls = self.run_command("test")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(sum(call["command"] == "docker" for call in calls), 1)
        self.assertEqual(sum(call["command"] == "npm" for call in calls), 1)
        postgres = next(
            i for i, call in enumerate(calls) if call["command"] == "docker"
        )
        suites = [i for i, call in enumerate(calls) if "discover" in call["args"]]
        self.assertEqual(len(suites), 3)
        self.assertGreater(min(suites), postgres)
        self.assertEqual(calls[-1]["command"], "mix")
        self.assertEqual(calls[-1]["args"], ["test"])

    def test_preparation_and_lane_failures_propagate_without_running_following_work(
        self,
    ):
        for command, failure, expected_last in (
            ("test", "npm", "npm"),
            ("test-python", "uv", "uv"),
            ("test-controller", "mix", "mix"),
        ):
            with self.subTest(command=command):
                self.log.unlink(missing_ok=True)
                result, calls = self.run_command(command, FAIL_COMMAND=failure)
                self.assertEqual(result.returncode, 23)
                self.assertEqual(calls[-1]["command"], expected_last)
                if command == "test-python":
                    self.assertEqual(len(calls), 1)


if __name__ == "__main__":
    unittest.main()
