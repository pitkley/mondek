# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Bounded immutable consumer snapshots; imports happen only in owned workers."""

from __future__ import annotations

import argparse
import asyncio
import contextlib
import hmac
import importlib.metadata
import importlib.util
import json
import os
import shutil
import signal
import sys
import tempfile
import time
from collections.abc import Iterator, Mapping
from copy import deepcopy
from hashlib import sha256
from pathlib import Path
from typing import Any

from .api import validate_invocation_scope
from .authoring import (
    MAX_CHECKS,
    App,
    canonical,
    load_app,
    normalize_json_numbers,
    validate_check_group,
    validate_construction_environment,
)
from .catalogs import materialize as materialize_catalogs
from .catalogs import prepare as prepare_catalogs

MAX_INVENTORY = 4 * 1024 * 1024
MAX_SOURCE = 32 * 1024 * 1024
MAX_FILES = 4096
SNAPSHOT_FORMAT = 2
PRIVATE_FORMAT_KEY = "__mondek_snapshot_format"
MANIFEST_MAC_DOMAIN = b"mondek snapshot manifest v2\0"


def validate_output_scopes(checks: list[dict[str, Any]]) -> None:
    for check in checks:
        for output in check["outputs"]:
            validate_invocation_scope(output)
            if "group" in output:
                validate_check_group(output["group"])


def metadata_at_revision(
    checks: list[dict[str, Any]], revision: str
) -> list[dict[str, Any]]:
    """Rebind already validated metadata without revisiting consumer signatures.

    The definition revision binds the current check metadata and source revision.
    """
    rebound = deepcopy(checks)
    for item in rebound:
        item.pop("definition_revision")
        item["definition_revision"] = sha256(canonical([revision, item])).hexdigest()
    return rebound


def dependencies() -> dict[str, Any]:
    """Installed versions and SDK bytes fence incompatible in-place upgrades."""
    sdk = Path(__file__).parent
    return {
        "python": sys.version,
        "packages": sorted(
            [item.metadata["Name"], item.version]
            for item in importlib.metadata.distributions()
        ),
        "sdk": {
            path.relative_to(sdk).as_posix(): sha256(path.read_bytes()).hexdigest()
            for path in sorted(sdk.rglob("*.py"))
        },
    }


def package_root(entrypoint: str) -> tuple[str, Path]:
    top = entrypoint.split(":")[0].split(".")[0]
    if not top.isidentifier() or ":" not in entrypoint:
        raise ValueError("consumer entry point must be module:app")
    spec = importlib.util.find_spec(top)
    if spec is None or not spec.origin:
        raise ValueError("consumer must be an installed Python module or package")
    path = Path(spec.origin).resolve()
    return top, path.parent if spec.submodule_search_locations else path


def identity_key(directory: Path) -> bytes:
    """Installation-local key shared by private-setting and manifest identities."""
    key_file = directory / ".identity-key"
    try:
        descriptor = os.open(key_file, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError:
        pass
    else:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(os.urandom(32))
    key = key_file.read_bytes()
    if len(key) != 32:
        raise ValueError("invalid private snapshot identity key")
    return key


def settings_digest(directory: Path, private: bytes) -> str:
    """A local secret key makes the public revision opaque to credential guesses."""
    return hmac.new(identity_key(directory), private, sha256).hexdigest()


def manifest_digest(directory: Path, manifest: bytes) -> bytes:
    return (
        hmac.new(identity_key(directory), MANIFEST_MAC_DOMAIN + manifest, sha256)
        .hexdigest()
        .encode("ascii")
    )


def validate_membership(app: Any, inventory: dict[str, Any]) -> None:
    checks = inventory["checks"]
    keys = [item["key"] for item in checks]
    if (
        not 0 <= len(keys) <= MAX_CHECKS
        or len(keys) != len(set(keys))
        or set(keys) != set(app.selected_bindings())
        or inventory["source_id"] != app.source_id
    ):
        raise ValueError("consumer registration differs from the complete snapshot")


def validate_registration(
    app: Any, inventory: dict[str, Any], registered_keys: Any
) -> None:
    """Authenticate all registrations without evaluating unrelated placement.

    A snapshot records both the complete registration and its accepted eligible
    inventory. A selected worker cannot add or remove registrations, execute an
    excluded check, or bypass its own current eligibility. Other checks' dynamic
    policies are evaluated during discovery or their own execution, not here.
    """
    keys = [item["key"] for item in inventory["checks"]]
    if (
        not isinstance(registered_keys, list)
        or len(registered_keys) > MAX_CHECKS
        or any(not isinstance(key, str) for key in registered_keys)
        or len(registered_keys) != len(set(registered_keys))
        or set(registered_keys) != set(app.bindings)
        or not 0 <= len(keys) <= MAX_CHECKS
        or len(keys) != len(set(keys))
        or not set(keys).issubset(registered_keys)
        or inventory["source_id"] != app.source_id
    ):
        raise ValueError("consumer registration differs from the complete snapshot")


def coverage_inventory(
    app: App,
    checks: list[dict[str, Any]],
    entrypoint: str,
    files: dict[str, str],
    runtime: dict[str, Any],
) -> dict[str, Any]:
    """Comparable public identities, separate from private executable revision."""
    validate_output_scopes(checks)
    coverage = normalize_json_numbers(
        {
            "version": 1,
            "code_revision": sha256(canonical([entrypoint, files])).hexdigest(),
            "runtime_revision": sha256(canonical(runtime)).hexdigest(),
            **app.coverage_metadata(checks),
        }
    )
    validate_output_scopes(coverage["candidates"])
    return coverage


def create_snapshot(entrypoint: str, directory: Path) -> dict[str, Any]:
    return prepare_snapshot(entrypoint, directory)["inventory"]


def prepare_snapshot(
    entrypoint: str,
    directory: Path,
    *,
    discovery_state: dict[str, Any] | None = None,
    policy_params: dict[str, Any] | None = None,
    policy_versions: dict[str, Any] | None = None,
    now: float | None = None,
) -> dict[str, Any]:
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    top, root = package_root(entrypoint)
    with tempfile.TemporaryDirectory(prefix=".preparing-", dir=directory) as temporary:
        staging = Path(temporary)
        paths = sorted(root.rglob("*")) if root.is_dir() else [root]
        files: dict[str, str] = {}
        size = 0
        for path in paths:
            if "__pycache__" in path.parts or path.suffix in (".pyc", ".pyo"):
                continue
            if path.is_symlink():
                raise ValueError("consumer bundles must not contain symlinks")
            if not path.is_file():
                continue
            if path.stat().st_size > MAX_SOURCE - size:
                raise ValueError("consumer bundle exceeds 32 MiB")
            relative = (
                Path(top) / path.relative_to(root)
                if root.is_dir()
                else Path(top + ".py")
            )
            with path.open("rb") as source:
                content = source.read(MAX_SOURCE - size + 1)
            size += len(content)
            if size > MAX_SOURCE or len(files) >= MAX_FILES:
                raise ValueError("consumer bundle exceeds 32 MiB or 4096 files")
            destination = staging / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(content)
            files[str(relative)] = sha256(content).hexdigest()
        runtime = dependencies()
        sys.path.insert(0, str(staging))
        sys.dont_write_bytecode = True
        with contextlib.redirect_stdout(sys.stderr):
            app = load_app(entrypoint)
            discovery = prepare_catalogs(
                app,
                discovery_state or {},
                policy_params or {},
                time.time() if now is None else now,
            )
            private_settings = app.private_settings()
            if PRIVATE_FORMAT_KEY in private_settings:
                raise ValueError("private settings contain a reserved snapshot field")
            private = canonical(
                {**private_settings, PRIVATE_FORMAT_KEY: SNAPSHOT_FORMAT}
            )
            if len(private) > 1024 * 1024:
                raise ValueError("private declared settings exceed 1 MiB")
            private_digest = settings_digest(directory, private)
            base = sha256(
                canonical([entrypoint, files, runtime, private_digest])
            ).hexdigest()
            checks = normalize_json_numbers(app.metadata(base))
            coverage = coverage_inventory(app, checks, entrypoint, files, runtime)
            revision = sha256(
                canonical([base, app.source_id, checks, coverage])
            ).hexdigest()
            inventory = normalize_json_numbers(
                {
                    "source_id": app.source_id,
                    "source_revision": revision,
                    "runner_label": (app.runner.name or app.runner.id),
                    "placement": app.placement_summary(),
                    "coverage": coverage,
                    "checks": metadata_at_revision(checks, revision),
                }
            )
        manifest = {
            "snapshot_format": SNAPSHOT_FORMAT,
            "entrypoint": entrypoint,
            "files": files,
            "runtime": runtime,
            "inventory": inventory,
            "registered_check_keys": sorted(app.bindings),
            "private_digest": private_digest,
        }
        validate_membership(app, inventory)
        manifest_bytes = canonical(manifest)
        if len(manifest_bytes) > MAX_INVENTORY:
            raise ValueError("consumer metadata exceeds 4 MiB")
        (staging / "manifest.json").write_bytes(manifest_bytes)
        with (staging / "manifest.mac").open("xb") as file:
            os.chmod(file.fileno(), 0o600)
            file.write(manifest_digest(directory, manifest_bytes))
        with (staging / "private.json").open("xb") as file:
            os.chmod(file.fileno(), 0o600)
            file.write(private)
        destination = directory / revision
        if destination.exists():
            if (destination / "manifest.json").read_bytes() != manifest_bytes or (
                destination / "manifest.mac"
            ).read_bytes() != manifest_digest(directory, manifest_bytes):
                raise ValueError("snapshot identity conflicts with stored bytes")
        else:
            staging.rename(destination)
        # Selection receipts are transport evidence, not immutable executable
        # source. Including adoption generations in source identity would cause
        # endless configuration/adoption churn even when membership is unchanged.
        if discovery["selections"]:
            inventory = {
                **inventory,
                "catalog_selections": {
                    key: {**selection, **(policy_versions or {}).get(key, {})}
                    for key, selection in discovery["selections"].items()
                },
            }
        return {"inventory": inventory, "discovery": discovery}


def load_snapshot(
    directory: Path, revision: str, *, check_key: str | None = None
) -> tuple[Any, dict[str, Any]]:
    if len(revision) != 64 or any(c not in "0123456789abcdef" for c in revision):
        raise ValueError("invalid code revision")
    root = directory / revision
    with (root / "manifest.json").open("rb") as file:
        manifest_bytes = file.read(MAX_INVENTORY + 1)
    if len(manifest_bytes) > MAX_INVENTORY:
        raise ValueError("consumer metadata exceeds 4 MiB")
    manifest = json.loads(manifest_bytes)
    if manifest.get("snapshot_format") != SNAPSHOT_FORMAT:
        raise ValueError(
            "unsupported consumer snapshot format; prepare a current revision"
        )
    try:
        with (root / "manifest.mac").open("rb") as file:
            signature = file.read(65)
    except FileNotFoundError:
        raise ValueError("prepared manifest authentication is missing") from None
    if len(signature) != 64 or not hmac.compare_digest(
        signature, manifest_digest(directory, manifest_bytes)
    ):
        raise ValueError("prepared manifest authentication failed")
    if "registered_check_keys" not in manifest:
        raise ValueError(
            "prepared manifest requires complete registration; "
            "prepare a current revision"
        )
    if manifest["inventory"]["source_revision"] != revision:
        raise ValueError("snapshot revision mismatch")
    if manifest["runtime"] != dependencies():
        raise ValueError(
            "installed Python dependencies changed; restore the previous environment "
            "or prepare a new revision"
        )
    for relative, digest in manifest["files"].items():
        path = (root / relative).resolve()
        if (
            not path.is_relative_to(root.resolve())
            or sha256(path.read_bytes()).hexdigest() != digest
        ):
            raise ValueError("prepared consumer source changed")
    with (root / "private.json").open("rb") as file:
        private = file.read(1024 * 1024 + 1)
    if len(private) > 1024 * 1024:
        raise ValueError("private declared settings exceed 1 MiB")
    if settings_digest(directory, private) != manifest["private_digest"]:
        raise ValueError("prepared private settings changed")
    settings = json.loads(private)
    if not isinstance(settings, dict):
        raise ValueError("private declared settings require an object")
    private_format = settings.pop(PRIVATE_FORMAT_KEY, None)
    if private_format != SNAPSHOT_FORMAT:
        raise ValueError("prepared private snapshot format does not match manifest")
    construction = validate_construction_environment(
        settings.get("construction_environment")
    )
    sys.path.insert(0, str(root))
    sys.dont_write_bytecode = True
    with restored_construction_environment(construction):
        app = load_app(manifest["entrypoint"])
        materialize_catalogs(app, settings.get("catalogs", {}))
        app.restore_private_settings(settings)
        validate_registration(
            app, manifest["inventory"], manifest["registered_check_keys"]
        )
        if (
            check_key is not None
            and getattr(app.metadata, "__func__", None) is App.metadata
        ):
            return validated_check(app, manifest, revision, check_key)
        validate_membership(app, manifest["inventory"])
        return validated_snapshot(app, manifest, revision)


@contextlib.contextmanager
def restored_construction_environment(
    values: Mapping[str, str | None] | None,
) -> Iterator[None]:
    """Only App construction uses these values; execution must use declared inputs."""
    values = values or {}
    previous = {name: os.environ.get(name) for name in values}
    try:
        for name, value in values.items():
            if value is None:
                os.environ.pop(name, None)
            else:
                os.environ[name] = value
        yield
    finally:
        for name, value in previous.items():
            if value is None:
                os.environ.pop(name, None)
            else:
                os.environ[name] = value


def validated_snapshot(
    app: Any, manifest: dict[str, Any], revision: str
) -> tuple[Any, dict[str, Any]]:
    base = sha256(
        canonical(
            [
                manifest["entrypoint"],
                manifest["files"],
                manifest["runtime"],
                manifest["private_digest"],
            ]
        )
    ).hexdigest()
    checks = normalize_json_numbers(app.metadata(base))
    validate_output_scopes(checks)
    revision_parts = [base, app.source_id, checks]
    if "coverage" in manifest["inventory"]:
        coverage = coverage_inventory(
            app,
            checks,
            manifest["entrypoint"],
            manifest["files"],
            manifest["runtime"],
        )
        if coverage != manifest["inventory"]["coverage"]:
            raise ValueError(
                "prepared consumer revision no longer matches its source: "
                "coverage differs from the prepared declaration catalogue"
            )
        revision_parts.append(coverage)
    actual_revision = sha256(canonical(revision_parts)).hexdigest()
    if actual_revision != revision:
        raise ValueError("prepared consumer revision no longer matches its source")
    if (
        app.source_id != manifest["inventory"]["source_id"]
        or metadata_at_revision(checks, revision) != manifest["inventory"]["checks"]
    ):
        raise ValueError(
            "consumer deployment settings changed from the prepared revision"
        )
    return app, manifest["inventory"]


def validated_check(
    app: Any, manifest: dict[str, Any], revision: str, check_key: str
) -> tuple[Any, dict[str, Any]]:
    """The authenticated inventory owns membership; execution owns one definition."""
    expected = next(
        (item for item in manifest["inventory"]["checks"] if item["key"] == check_key),
        None,
    )
    if expected is None or check_key not in app.bindings:
        raise ValueError("check is not present in the prepared consumer")
    # The source revision is already authenticated. The definition hash uses
    # exactly the same selected metadata construction as complete discovery.
    checks = app._metadata_for_check(revision, check_key)
    validate_output_scopes(checks)
    if len(checks) != 1 or checks[0] != expected:
        raise ValueError("selected check differs from the prepared consumer revision")
    return app, manifest["inventory"]


async def snapshot(
    entrypoint: str,
    directory: Path,
    *,
    discovery_state: dict[str, Any] | None = None,
    policy_params: dict[str, Any] | None = None,
    policy_versions: dict[str, Any] | None = None,
    include_discovery: bool = False,
) -> dict[str, Any]:
    """The supervisor never imports a consumer, including during discovery."""
    process = await asyncio.create_subprocess_exec(
        sys.executable,
        "-B",
        "-m",
        "mondek_runner.bundle",
        entrypoint,
        str(directory),
        "--discovery-envelope",
        "--parent-pid",
        str(os.getpid()),
        stdin=asyncio.subprocess.PIPE,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
        start_new_session=True,
    )
    output = bytearray()
    errors = bytearray()
    inputs = canonical(
        {
            "discovery_state": discovery_state or {},
            "policy_params": policy_params or {},
            "policy_versions": policy_versions or {},
        }
    )
    if len(inputs) > MAX_INVENTORY:
        process.kill()
        await process.wait()
        raise ValueError("discovery inputs exceed 4 MiB")

    async def read(stream: asyncio.StreamReader, buffer: bytearray, limit: int) -> None:
        while chunk := await stream.read(4096):
            buffer.extend(chunk)
            if len(buffer) > limit:
                raise ValueError("consumer discovery exceeded its output bound")

    try:

        async def write() -> None:
            process.stdin.write(inputs)
            await process.stdin.drain()
            process.stdin.close()

        await asyncio.wait_for(
            asyncio.gather(
                write(),
                read(process.stdout, output, 2 * MAX_INVENTORY),
                read(process.stderr, errors, 65536),
                process.wait(),
            ),
            timeout=15,
        )
        if process.returncode:
            raise ValueError(
                errors.decode(errors="replace")[-2048:] or "consumer discovery failed"
            )
        result = json.loads(output)
        return result if include_discovery else result["inventory"]
    finally:
        with contextlib.suppress(ProcessLookupError):
            os.killpg(process.pid, signal.SIGKILL)
        await process.wait()
        # A killed preparation can leave only these owned staging directories.
        for path in directory.glob(".preparing-*"):
            shutil.rmtree(path)


def _discovery_watchdog(helper_pid: int, supervisor_pid: int) -> None:
    """Bound the entire owned group independently of consumer Python/GIL state."""
    if os.getpgrp() != helper_pid:
        raise ValueError("discovery watchdog requires its helper's process group")
    deadline = time.monotonic() + 16
    while True:
        try:
            os.kill(supervisor_pid, 0)
            supervisor_alive = True
        except ProcessLookupError:
            supervisor_alive = False
        if (
            os.getppid() != helper_pid
            or not supervisor_alive
            or time.monotonic() >= deadline
        ):
            os.killpg(helper_pid, signal.SIGKILL)
        time.sleep(0.1)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("entrypoint")
    parser.add_argument("directory", type=Path)
    parser.add_argument("--discovery-envelope", action="store_true")
    parser.add_argument("--parent-pid", type=int, required=True)
    args = parser.parse_args()
    if os.getpgrp() != os.getpid() or args.parent_pid <= 0:
        raise ValueError("discovery requires its own process group")
    # The guardian inherits only our group, not our protocol pipes. Keep it alive
    # until helper/group exit: terminating it early would reopen a parent-loss race.
    helper_pid = os.getpid()
    # This is the fresh, single-threaded helper, before any consumer import.
    if os.fork() == 0:
        for fd in (0, 1, 2):
            with contextlib.suppress(OSError):
                os.close(fd)
        _discovery_watchdog(helper_pid, args.parent_pid)
        os._exit(1)
    signal.signal(signal.SIGALRM, signal.SIG_DFL)
    signal.setitimer(signal.ITIMER_REAL, 16)
    if args.discovery_envelope:
        inputs = sys.stdin.buffer.read(MAX_INVENTORY + 1)
        if len(inputs) > MAX_INVENTORY:
            raise ValueError("discovery inputs exceed 4 MiB")
        options = json.loads(inputs)
        result = prepare_snapshot(args.entrypoint, args.directory, **options)
    else:
        result = create_snapshot(args.entrypoint, args.directory)
    sys.stdout.write(json.dumps(result, allow_nan=False))


if __name__ == "__main__":
    main()
