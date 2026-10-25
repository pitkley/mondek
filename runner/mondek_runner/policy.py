# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Explicit operator commands for data-only controller policy.

This module does not load a consumer or run checks. Generate JSON with ordinary
Python when useful; validation and HTTP requests receive only the resulting data.
"""

from __future__ import annotations

import argparse
import hashlib
import hmac
import json
import os
import re
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path
from typing import Any, BinaryIO

from .authoring import canonical, finite_number, normalize_json_numbers
from .controller_auth import controller_headers, http_failure

MAX_MANIFEST_BYTES = 2 * 1024 * 1024
MAX_RESPONSE_BYTES = 64 * 1024 * 1024
MAX_PLAN_BYTES = MAX_RESPONSE_BYTES + MAX_MANIFEST_BYTES
HTTP_TIMEOUT = 15
HTTP_DEADLINE = 30
IDENTITY = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,127}")
RULE_FIELDS = {
    "key",
    "name",
    "source_id",
    "parameter_contract",
    "params",
    "environment",
    "target_kind",
    "target_key",
    "priority",
    "enabled",
    "adopt_rule_id",
}


class PolicyError(ValueError):
    """An actionable operator input or controller response error."""


def _text(value: Any, name: str, maximum: int, *, empty: bool = False) -> str:
    if (
        not isinstance(value, str)
        or (not empty and not value.strip())
        or len(value.encode("utf-8", errors="surrogatepass")) > maximum
        or any(
            ord(char) < 32 or ord(char) == 127 or 0xD800 <= ord(char) <= 0xDFFF
            for char in value
        )
    ):
        raise PolicyError(f"{name} must be plain text within {maximum} UTF-8 bytes")
    return value


def _identity(value: Any, name: str) -> str:
    if not isinstance(value, str) or not IDENTITY.fullmatch(value):
        raise PolicyError(f"{name} requires 1–128 letters, digits, dots, _ or -")
    return value


def _uuid(value: Any) -> str:
    try:
        if not isinstance(value, str) or str(uuid.UUID(value)) != value.lower():
            raise ValueError
    except ValueError as error:
        raise PolicyError("adopt_rule_id must be a UUID") from error
    return value


def validate_manifest(value: Any) -> dict[str, Any]:
    """Validate the offline format; the controller checks published schemas."""
    if not isinstance(value, dict) or set(value) != {"version", "project", "rules"}:
        raise PolicyError("manifest requires exactly version, project and rules")
    if type(value["version"]) is not int or value["version"] != 1:
        raise PolicyError("manifest version must be 1")
    _identity(value["project"], "project")
    if not isinstance(value["rules"], list) or len(value["rules"]) > 64:
        raise PolicyError("rules must be a list of at most 64 complete rules")
    keys: set[str] = set()
    adoptions: set[str] = set()
    for rule in value["rules"]:
        required = {"key", "name", "source_id", "parameter_contract", "params"}
        if (
            not isinstance(rule, dict)
            or not required <= set(rule)
            or not set(rule) <= RULE_FIELDS
        ):
            raise PolicyError(
                "each rule needs key, name, source_id, "
                "parameter_contract and params; unknown fields are rejected"
            )
        key = _identity(rule["key"], "rule key")
        if key in keys:
            raise PolicyError(f"duplicate rule key: {key}")
        keys.add(key)
        for field, maximum in (
            ("name", 200),
            ("source_id", 200),
            ("parameter_contract", 128),
        ):
            _text(rule[field], field, maximum)
        for field, maximum in (
            ("environment", 128),
            ("target_kind", 64),
            ("target_key", 200),
        ):
            if rule.get(field) is not None:
                _text(rule[field], field, maximum)
        if (rule.get("target_kind") is None) != (rule.get("target_key") is None):
            raise PolicyError("target_kind and target_key must be supplied together")
        priority = rule.get("priority", 0)
        if type(priority) is not int or not -10000 <= priority <= 10000:
            raise PolicyError("priority must be an integer from -10000 to 10000")
        if type(rule.get("enabled", True)) is not bool:
            raise PolicyError("enabled must be a boolean")
        if "adopt_rule_id" in rule:
            adoption = _uuid(rule["adopt_rule_id"])
            if adoption.lower() in adoptions:
                raise PolicyError("one existing rule cannot be adopted twice")
            adoptions.add(adoption.lower())
        params = rule["params"]
        if not isinstance(params, dict) or not 1 <= len(params) <= 32:
            raise PolicyError("params must contain the complete set of 1–32 fields")
        for name, parameter in params.items():
            _text(name, "parameter name", 128)
            if isinstance(parameter, str):
                _text(parameter, "parameter value", 2048, empty=True)
            elif type(parameter) is not bool and not finite_number(parameter):
                raise PolicyError(
                    "parameter values must be strings, booleans or finite "
                    "numbers; integer literals permit at most 4096 digits"
                )
        normalized = normalize_json_numbers(params)
        reserve = sum(
            max(0, 24 - len(canonical(item)))
            for item in normalized.values()
            if type(item) is float
        )
        if len(canonical(normalized)) + reserve > 16384:
            raise PolicyError("each complete parameter set must fit within 16 KiB")
    result = normalize_json_numbers(value)
    if len(canonical(result)) > MAX_MANIFEST_BYTES:
        raise PolicyError("manifest exceeds the 2 MiB limit")
    return result


def _pairs(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    value: dict[str, Any] = {}
    for key, item in pairs:
        if key in value:
            raise PolicyError("JSON contains a duplicate object field")
        value[key] = item
    return value


def _nonfinite(_: str) -> None:
    raise PolicyError("JSON numbers must be finite")


def decode_json(raw: bytes) -> dict[str, Any]:
    try:
        value = json.loads(
            raw.decode("utf-8"), object_pairs_hook=_pairs, parse_constant=_nonfinite
        )
        if not isinstance(value, dict):
            raise PolicyError("JSON document must be an object")
        canonical(value)
        return value
    except (UnicodeError, ValueError, RecursionError) as error:
        if isinstance(error, PolicyError):
            raise
        raise PolicyError("document is not valid bounded UTF-8 JSON") from error


def _read(stream: BinaryIO, maximum: int) -> bytes:
    data = stream.read(maximum + 1)
    if len(data) > maximum:
        raise PolicyError(f"document exceeds the {maximum}-byte limit")
    return data


def read_document(filename: str, maximum: int = MAX_MANIFEST_BYTES) -> dict[str, Any]:
    if filename == "-":
        return decode_json(_read(sys.stdin.buffer, maximum))
    with Path(filename).open("rb") as stream:
        return decode_json(_read(stream, maximum))


def write_document(filename: str, value: dict[str, Any]) -> None:
    """Replace atomically with owner-only permissions, including an existing file."""
    if filename == "-":
        raise PolicyError("--out must name a file; use --json for standard output")
    path = Path(filename)
    data = (
        json.dumps(value, indent=2, ensure_ascii=True, allow_nan=False).encode() + b"\n"
    )
    if len(data) > MAX_PLAN_BYTES:
        raise PolicyError("document exceeds the saved-plan size limit")
    temporary: str | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="wb", dir=path.parent, prefix=f".{path.name}.", delete=False
        ) as stream:
            temporary = stream.name
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if temporary is not None and os.path.exists(temporary):
            os.unlink(temporary)


def controller_url(value: str) -> str:
    try:
        url = urllib.parse.urlsplit(value)
        _text(value, "controller URL", 2048)
        if (
            url.scheme not in ("http", "https")
            or not url.hostname
            or url.username is not None
            or url.password is not None
            or url.query
            or url.fragment
            or url.path not in ("", "/")
            or any(char.isspace() for char in value)
            or url.port == 0
        ):
            raise ValueError
        host = url.hostname.lower()
        if ":" in host:
            host = f"[{host}]"
        port = url.port
        suffix = (
            ""
            if port is None or (url.scheme, port) in (("http", 80), ("https", 443))
            else f":{port}"
        )
        return f"{url.scheme}://{host}{suffix}"
    except ValueError as error:
        raise PolicyError(
            "controller requires an http(s) origin URL without "
            "credentials, path, query or fragment"
        ) from error


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def request(
    controller: str, endpoint: str, body: dict[str, Any] | None = None
) -> dict[str, Any]:
    """Bound DNS, headers and body together in one owned transport process."""
    try:
        result = subprocess.run(
            [
                sys.executable,
                "-c",
                "from mondek_runner.policy import _transport_main; _transport_main()",
            ],
            input=canonical(
                {
                    "controller": controller,
                    "endpoint": endpoint,
                    "body": body,
                    "maximum": MAX_RESPONSE_BYTES,
                }
            ),
            capture_output=True,
            timeout=HTTP_DEADLINE,
            check=False,
        )
    except subprocess.TimeoutExpired as error:
        raise PolicyError(
            "controller request exceeded the time limit; "
            "retry the same saved plan if apply was in progress"
        ) from error
    if result.returncode != 0 or len(result.stdout) > MAX_RESPONSE_BYTES + 8192:
        raise PolicyError(
            "controller transport failed; "
            "retry the same saved plan if apply was in progress"
        )
    result = decode_json(result.stdout)
    if "error" in result:
        raise PolicyError(_text(result["error"], "transport error", 8192))
    if not isinstance(result.get("ok"), dict):
        raise PolicyError("invalid controller transport response")
    return result["ok"]


def _transport_main() -> None:
    """Private subprocess entry; the parent kills and reaps it at the deadline."""
    try:
        args = read_document("-", MAX_PLAN_BYTES)
        result = _request_once(
            args["controller"], args["endpoint"], args["body"], args["maximum"]
        )
        encoded = canonical(result)
        if len(encoded) > args["maximum"]:
            raise PolicyError("controller response exceeded the size limit")
        sys.stdout.buffer.write(b'{"ok":' + encoded + b"}")
    except (PolicyError, OSError) as error:
        sys.stdout.buffer.write(canonical({"error": str(error)}))


def _request_once(
    controller: str, endpoint: str, body: dict[str, Any] | None, maximum: int
) -> dict[str, Any]:
    """Make one request without redirects or retries, inside the bounded process."""
    url = controller + "/api/v1/configuration/" + endpoint
    try:
        auth = controller_headers(url)
    except ValueError as error:
        raise PolicyError(str(error)) from None
    headers = {"Accept": "application/json", **auth}
    if body is not None:
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(
        url, canonical(body) if body is not None else None, headers=headers
    )
    try:
        with urllib.request.build_opener(_NoRedirect).open(
            req, timeout=HTTP_TIMEOUT
        ) as response:
            chunks = bytearray()
            while True:
                block = response.read1(min(65536, maximum + 1 - len(chunks)))
                chunks.extend(block)
                if len(chunks) > maximum:
                    raise PolicyError("controller response exceeded the size limit")
                if not block:
                    break
            return decode_json(bytes(chunks))
    except urllib.error.HTTPError as error:
        with error:
            if auth or error.code in (401, 403):
                raise PolicyError(http_failure(error.code)) from None
            if 300 <= error.code < 400:
                raise PolicyError(
                    "controller redirected the request; redirects are refused"
                ) from error
            try:
                detail = decode_json(error.read(8193)).get("error")
                detail = _text(detail, "controller error", 4096)
            except (ValueError, OSError):
                detail = "request rejected"
            raise PolicyError(f"controller HTTP {error.code}: {detail}") from error
    except (urllib.error.URLError, TimeoutError, OSError) as error:
        raise PolicyError(
            "controller request failed or timed out; check its URL and "
            "availability. For apply, retry the same saved plan if the "
            "outcome is unknown"
        ) from error


def _digest(value: dict[str, Any]) -> str:
    return hashlib.sha256(canonical(value)).hexdigest()


def saved_plan(controller: str, plan: dict[str, Any]) -> dict[str, Any]:
    if not isinstance(plan.get("review_token"), str) or not plan["review_token"]:
        raise PolicyError("plan contains conflicts and cannot be saved for application")
    manifest = validate_manifest(plan.get("manifest"))
    envelope = {
        "version": 1,
        "controller": controller,
        "manifest": manifest,
        "plan": plan,
    }
    return {**envelope, "digest": _digest(envelope)}


def validate_saved_plan(value: dict[str, Any], controller: str) -> dict[str, Any]:
    if (
        set(value) != {"version", "controller", "manifest", "plan", "digest"}
        or type(value["version"]) is not int
        or value["version"] != 1
    ):
        raise PolicyError("not a saved policy plan; generate a new plan")
    unsigned = {key: item for key, item in value.items() if key != "digest"}
    if not isinstance(value["digest"], str) or not hmac.compare_digest(
        value["digest"], _digest(unsigned)
    ):
        raise PolicyError("saved plan was modified or corrupted; generate a new plan")
    if value["controller"] != controller:
        raise PolicyError(
            "saved plan belongs to another controller URL; review a new plan"
        )
    if not isinstance(value["plan"], dict):
        raise PolicyError("invalid saved plan")
    validated = saved_plan(controller, value["plan"])
    if canonical(validated["manifest"]) != canonical(value["manifest"]):
        raise PolicyError("saved manifest differs from the reviewed manifest")
    return {
        "manifest": validated["manifest"],
        "review_token": value["plan"]["review_token"],
    }


def _display(value: Any) -> str:
    return json.dumps(value, ensure_ascii=True, sort_keys=True, allow_nan=False)


def show_plan(plan: dict[str, Any]) -> None:
    project = plan.get("project", plan.get("manifest", {}).get("project", "?"))
    print(f"Policy project: {_display(project)}")
    if plan.get("repository_head"):
        print(f"Reviewed configuration revision: {_display(plan['repository_head'])}")
    counts = plan.get("counts", {})
    print(
        "Rules: "
        + ", ".join(
            f"{counts.get(key, 0)} {key}"
            for key in ("create", "update", "remove", "adopt", "noop")
        )
    )
    print(
        f"Checks: {counts.get('matched', 0)} matched, "
        f"{counts.get('changed', 0)} change, "
        f"{counts.get('exceptions', 0)} masked by instance exceptions, "
        f"{counts.get('conflicts', 0)} conflicts"
    )
    for change in plan.get("changes", []):
        print(
            f"\n{str(change.get('action', '?')).upper()} {_display(change.get('key'))}"
        )
        for side in ("before", "after"):
            if change.get(side) is not None:
                settings = {
                    key: item
                    for key, item in change[side].items()
                    if key in RULE_FIELDS
                }
                print(f"  {side}: {_display(settings)}")
    rows = [
        row
        for row in plan.get("rows", [])
        if row.get("masked_by_exception") or row.get("error")
    ]
    for row in rows[:20]:
        print(f"\n  {_display(row.get('label', row.get('id')))} [{row.get('id')}]")
        if row.get("masked_by_exception"):
            print(
                f"    Instance exception keeps: {_display(row.get('proposed_params'))}"
            )
            print(f"    Without exception: {_display(row.get('masked_params'))}")
        if row.get("error"):
            print(f"    Conflict: {_display(row['error'])}")
        if row.get("masked_error"):
            print(f"    Underlying conflict: {_display(row['masked_error'])}")
            print("    Removing the instance exception would require resolving this.")
    if len(rows) > 20:
        print(
            f"  {len(rows) - 20} further exceptions/conflicts; use --json for all rows."
        )


def show_values(value: dict[str, Any]) -> None:
    rows = value.get("rows", [])
    print(
        f"Effective settings: page {value.get('page', 1)}, "
        f"{value.get('total', len(rows))} checks"
    )
    for row in rows:
        print(f"\n{_display(row.get('label', row.get('id')))} [{row.get('id')}]")
        print(
            f"  Monitored environment: {_display(row.get('environment'))}; "
            f"observing runner: {_display(row.get('runner_id'))}"
        )
        if row.get("params_owner") == "source":
            print("  Parameters are owned by check code.")
        print(f"  Source defaults: {_display(row.get('source_defaults'))}")
        settings = row.get("current_params", row.get("params"))
        print(f"  Saved settings: {_display(settings)}")
        origin = row.get("current_origin", row.get("configuration_origin"))
        print(f"  Origin: {_display(origin)}")
        desired = row.get("target_generation")
        measured = row.get("observed_generation")
        print(
            f"  Desired generation: {_display(desired)}; "
            f"last measured generation: {_display(measured)}"
        )
        if desired is not None and desired != measured:
            print("  Awaiting a measurement using the desired settings.")
        if row.get("masked_by_exception"):
            print(f"  Instance exception masks: {_display(row.get('masked_params'))}")
            print(f"  Underlying origin: {_display(row.get('masked_origin'))}")
        if row.get("error") or row.get("masked_error"):
            print(
                f"  Conflict: {_display(row.get('error') or row.get('masked_error'))}"
            )
    page_size = value.get("page_size", max(1, len(rows)))
    if value.get("total", 0) > value.get("page", 1) * page_size:
        print("\nMore checks are available; inspect the next --page.")


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    validate = sub.add_parser(
        "validate", help="validate JSON locally without imports or network"
    )
    validate.add_argument("file", help="manifest JSON file, or - for standard input")
    plan = sub.add_parser(
        "plan", help="review the exact changes and save an apply plan"
    )
    plan.add_argument("file", help="manifest JSON file, or - for standard input")
    plan.add_argument("--out", required=True, help="save a reviewed plan to this file")
    plan.add_argument(
        "--base",
        help="reviewed Git revision; required when changing an existing project",
    )
    apply = sub.add_parser(
        "apply", help="apply an unchanged saved plan; never replan automatically"
    )
    apply.add_argument("file", help="saved plan JSON file")
    export = sub.add_parser(
        "export", help="export one project's currently managed rules"
    )
    export.add_argument("--project", required=True)
    export.add_argument("--out", required=True)
    export.add_argument(
        "--adopt",
        action="append",
        default=[],
        metavar="UUID=KEY",
        help="include an existing unmanaged UI rule for explicit adoption",
    )
    inspect = sub.add_parser(
        "inspect", help="show source, effective and masked settings"
    )
    inspect.add_argument("--source", required=True)
    inspect.add_argument("--page", type=int, default=1)
    for command in (plan, apply, export, inspect):
        command.add_argument(
            "--controller",
            required=True,
            help="controller origin, e.g. http://localhost:4001",
        )
    for command in (validate, plan, apply, export, inspect):
        command.add_argument(
            "--json", action="store_true", help="print JSON for automation"
        )
    return parser


def run(arguments: argparse.Namespace) -> int:
    if arguments.command == "validate":
        manifest = validate_manifest(read_document(arguments.file))
        if arguments.json:
            print(_display(manifest))
        else:
            print(
                f"Valid policy format: {manifest['project']}, "
                f"{len(manifest['rules'])} rules. "
                "Plan against a controller to check published parameter schemas "
                "and conflicts."
            )
        return 0
    controller = controller_url(arguments.controller)
    if arguments.command == "plan":
        if (
            arguments.file != "-"
            and Path(arguments.out).resolve() == Path(arguments.file).resolve()
        ):
            raise PolicyError("--out must differ from the input manifest")
        manifest = validate_manifest(read_document(arguments.file))
        payload: dict[str, Any] = {"manifest": manifest}
        if arguments.base is not None:
            if not re.fullmatch(r"[0-9a-f]{40}", arguments.base):
                raise PolicyError("--base must be a full 40-character Git revision")
            payload["base_head"] = arguments.base
        plan = request(controller, "policy/plan", payload)
        if arguments.json:
            print(_display(plan))
        else:
            show_plan(plan)
        envelope = saved_plan(controller, plan)
        write_document(arguments.out, envelope)
        print(
            f"Saved reviewed plan to {arguments.out}. "
            "Apply this file to the same controller.",
            file=sys.stderr,
        )
    elif arguments.command == "apply":
        plan = validate_saved_plan(
            read_document(arguments.file, MAX_PLAN_BYTES), controller
        )
        result = request(controller, "policy/apply", plan)
        if arguments.json:
            print(_display(result))
        elif result.get("superseded"):
            print(
                "This plan was applied previously and has since been superseded. "
                f"Current project revision: {result.get('current_project_revision')}. "
                "This historical receipt restored no policy or settings."
            )
        else:
            print(
                f"{'Already applied' if result.get('replayed') else 'Applied'} policy "
                f"{result.get('project', plan['manifest']['project'])}: "
                f"{result.get('changed_count', 0)} checks changed. "
                "Runner adoption is asynchronous; "
                "inspect effective settings for progress."
            )
    elif arguments.command == "export":
        project = _identity(arguments.project, "project")
        manifest = request(
            controller, "policy/export?" + urllib.parse.urlencode({"project": project})
        )
        manifest = validate_manifest(manifest)
        for adoption in arguments.adopt:
            if "=" not in adoption:
                raise PolicyError("--adopt requires UUID=KEY")
            rule_id, key = adoption.split("=", 1)
            _uuid(rule_id)
            _identity(key, "rule key")
            rule = request(controller, f"rules/{rule_id}")
            if rule.get("managed_project") is not None:
                raise PolicyError("--adopt requires an unmanaged UI rule")
            manifest["rules"].append(
                {
                    **{
                        name: value
                        for name, value in rule.items()
                        if name in RULE_FIELDS
                    },
                    "key": key,
                    "adopt_rule_id": rule_id,
                }
            )
        manifest = validate_manifest(manifest)
        write_document(arguments.out, manifest)
        if arguments.json:
            print(_display(manifest))
        else:
            print(
                f"Exported {len(manifest['rules'])} rules to {arguments.out}. "
                "Review and plan the file before applying; "
                "export changes no controller state."
            )
    elif arguments.command == "inspect":
        _text(arguments.source, "source", 200)
        if not 1 <= arguments.page <= 1_000_000:
            raise PolicyError("page must be from 1 to 1000000")
        result = request(
            controller,
            "policy/values?"
            + urllib.parse.urlencode(
                {"source_id": arguments.source, "page": arguments.page}
            ),
        )
        if arguments.json:
            print(_display(result))
        else:
            show_values(result)
    return 0


def main(argv: list[str] | None = None) -> int:
    arguments = _parser().parse_args(argv)
    try:
        return run(arguments)
    except (PolicyError, OSError, RecursionError, UnicodeError) as error:
        print(f"mondek-policy: {error}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print(
            "mondek-policy: interrupted; retry the same plan if apply was in progress",
            file=sys.stderr,
        )
        return 130


if __name__ == "__main__":
    sys.exit(main())
