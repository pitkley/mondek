# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Build/install the real wheel, then check consumers outside the checkout."""

import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[2]


def run(*args: str, cwd: Path, **kwargs: object) -> subprocess.CompletedProcess[str]:
    return subprocess.run(args, cwd=cwd, text=True, check=True, **kwargs)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--wheel", type=Path, default=os.environ.get("MONDEK_SDK_WHEEL")
    )
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="mondek-sdk-typing-") as directory:
        workspace = Path(directory).resolve()
        if args.wheel:
            wheel = args.wheel.resolve(strict=True)
            sdist = wheel.with_name(
                wheel.name.removesuffix("-py3-none-any.whl") + ".tar.gz"
            )
        else:
            wheels = workspace / "dist"
            run("uv", "build", "--out-dir", str(wheels), cwd=ROOT / "runner")
            sdist = next(wheels.glob("*.tar.gz"))
            rebuilt = workspace / "rebuilt"
            run(
                "uv",
                "build",
                str(sdist),
                "--wheel",
                "--out-dir",
                str(rebuilt),
                cwd=workspace,
            )
            wheels = rebuilt
            wheel = next(wheels.glob("*.whl"))
        with tarfile.open(sdist) as archive:
            license_member = next(
                member for member in archive if member.name.endswith("/LICENSE")
            )
            assert (
                archive.extractfile(license_member).read()
                == (ROOT / "LICENSE").read_bytes()
            )
            assert any(
                member.name.endswith("/THIRD_PARTY_LICENSES.md")
                for member in archive.getmembers()
            )
        with zipfile.ZipFile(wheel) as archive:
            assert "mondek_runner/py.typed" in archive.namelist()
            assert "mondek_runner/packs/linux.py" in archive.namelist()
            for name in (
                "AGENTS.md",
                "README.md",
                "app.py.tmpl",
                "test_backlog.py.tmpl",
            ):
                assert f"mondek_runner/bootstrap_templates/{name}" in archive.namelist()
            metadata = next(
                name
                for name in archive.namelist()
                if name.endswith(".dist-info/METADATA")
            )
            assert "License-Expression: Apache-2.0" in archive.read(metadata).decode()
            license_path = next(
                name
                for name in archive.namelist()
                if name.endswith(".dist-info/licenses/LICENSE")
            )
            assert archive.read(license_path) == (ROOT / "LICENSE").read_bytes()
            assert any(
                name.endswith(".dist-info/licenses/THIRD_PARTY_LICENSES.md")
                for name in archive.namelist()
            )
        run("uv", "venv", ".venv", cwd=workspace)
        python = workspace / ".venv/bin/python"
        run("uv", "pip", "install", "--python", str(python), str(wheel), cwd=workspace)
        for name in ("valid.py", "invalid.py"):
            shutil.copyfile(ROOT / "tests/typing" / name, workspace / name)
        (workspace / "pyrightconfig.json").write_text(
            json.dumps(
                {
                    "typeCheckingMode": "strict",
                    "pythonVersion": "3.13",
                    "venvPath": ".",
                    "venv": ".venv",
                }
            )
        )
        env = {key: value for key, value in os.environ.items() if key != "PYTHONPATH"}
        starter = workspace / "starter"
        run(
            str(python),
            "-I",
            "-m",
            "mondek_runner",
            "init",
            str(starter),
            cwd=workspace,
            env=env,
        )
        # Install the generated project itself against the already installed SDK.
        # The resolver uses the selected wheel, not a Mondek source override.
        run(
            "uv",
            "pip",
            "install",
            "--python",
            str(python),
            "--no-deps",
            str(starter),
            cwd=workspace,
            env=env,
        )
        run(
            str(python),
            "-I",
            "-m",
            "mondek_runner",
            "validate",
            "--consumer",
            "monitoring.app:app",
            cwd=starter,
            env=env,
        )
        private_env = starter / "private.env"
        private_env.write_text(
            "MONDEK_BACKLOG_FILE=" + str(starter / "sample-backlog.txt") + "\n"
        )
        private_env.chmod(0o600)
        run(
            "uv",
            "run",
            "--no-project",
            "--env-file",
            str(private_env),
            str(python),
            "-I",
            "-m",
            "mondek_runner",
            "run",
            "--consumer",
            "monitoring.app:app",
            "--all",
            "--results",
            cwd=starter,
            env=env,
        )
        # Load the generated consumer with the installed wheel, without resolving
        # its editable development source or installing another SDK from checkout.
        (workspace / "starter_check.py").write_text(
            "import sys, unittest\n"
            f"sys.path.insert(0, {str(starter / 'src')!r})\n"
            "from monitoring.app import app\n"
            "assert app.metadata('a' * 64)\n"
            f"suite = unittest.defaultTestLoader.discover({str(starter / 'tests')!r})\n"
            "result = unittest.TextTestRunner().run(suite)\n"
            "assert result.testsRun > 0 and result.wasSuccessful()\n"
        )
        run(str(python), "-I", "starter_check.py", cwd=workspace, env=env)
        # -I proves runtime imports resolve to the installed wheel, not the checkout.
        run(str(python), "-I", "valid.py", cwd=workspace, env=env)
        shutil.copyfile(
            ROOT / "runner/tests/test_public_api.py", workspace / "test_public_api.py"
        )
        run(
            str(python),
            "-I",
            "-m",
            "unittest",
            "discover",
            "-s",
            ".",
            "-p",
            "test_public_api.py",
            cwd=workspace,
            env=env,
        )
        run("pyright", "valid.py", cwd=workspace, env=env)
        result = subprocess.run(
            ["pyright", "--outputjson", "invalid.py"],
            cwd=workspace,
            env=env,
            text=True,
            capture_output=True,
        )
        assert result.returncode == 1, result.stdout + result.stderr
        diagnostics = json.loads(result.stdout)["generalDiagnostics"]
        actual = {
            (item["range"]["start"]["line"] + 1, item.get("rule"))
            for item in diagnostics
        }
        expected = {
            (line, content.split("# error: ")[1].strip())
            for line, content in enumerate(
                (workspace / "invalid.py").read_text().splitlines(), 1
            )
            if "# error: " in content
        }
        assert actual == expected, json.dumps(diagnostics, indent=2)
        assert all(
            item["file"] == str(workspace / "invalid.py") for item in diagnostics
        )
        print(f"Installed SDK typing passed: valid consumer and {len(expected)} errors")


if __name__ == "__main__":
    main()
