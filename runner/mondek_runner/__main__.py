# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Start the local runner or inspect its durable journal."""

import argparse
import asyncio
import json
import signal
import sys

from . import environment
from .bootstrap import initialize
from .local import local
from .runtime import Runner
from .state import State, inspect


def main() -> None:
    if sys.argv[1:2] == ["doctor"]:
        from .doctor import main as doctor

        doctor(sys.argv[2:])
        return
    if sys.argv[1:2] == ["init"]:
        initialize(sys.argv[2:])
        return
    parser = argparse.ArgumentParser(
        description=__doc__,
        epilog=(
            "Create a monitoring project: "
            "mondek-runner init DIRECTORY. "
            "Diagnose controller access: mondek-runner doctor --help"
        ),
    )
    parser.add_argument("command", nargs="?", choices=("validate", "run"))
    parser.add_argument("--consumer", default=environment.get("MONDEK_CONSUMER"))
    selection = parser.add_mutually_exclusive_group()
    selection.add_argument(
        "--check",
        action="append",
        help="source check key; repeat to run selected groups",
    )
    selection.add_argument(
        "--all", action="store_true", help="run every registered check"
    )
    parser.add_argument(
        "--concurrency",
        type=int,
        default=3,
        help="local run workers, 1–16 (default: 3)",
    )
    parser.add_argument("--params", help="complete JSON parameter set for a local run")
    parser.add_argument(
        "--results",
        action="store_true",
        help="include original batch result evidence within an 8 MiB JSON output limit",
    )
    parser.add_argument("--status", action="store_true")
    parser.add_argument(
        "--state-dir",
        default=environment.get("MONDEK_STATE_DIR", environment.DEFAULT_STATE_DIR),
    )
    parser.add_argument(
        "--controller",
        default=environment.get(
            "MONDEK_CONTROLLER_URL", environment.DEFAULT_CONTROLLER_URL
        ),
    )
    args = parser.parse_args()
    if args.command != "run" and (
        args.check
        or args.all
        or args.params is not None
        or args.concurrency != 3
        or args.results
    ):
        parser.error(
            "--check, --all, --params, --concurrency and --results require run"
        )
    if not 1 <= args.concurrency <= 16:
        parser.error("--concurrency must be between 1 and 16")
    if args.command:
        if not args.consumer:
            parser.error("validate/run require --consumer module:app")
        if args.status:
            parser.error("--status cannot be combined with validate/run")
        try:
            outcome = asyncio.run(
                local(
                    args.command,
                    args.consumer,
                    keys=args.check or [],
                    all_checks=args.all,
                    concurrency=args.concurrency,
                    params=args.params,
                    include_results=args.results,
                )
            )
            print(json.dumps(outcome, allow_nan=False))
            success = args.command == "validate" or outcome["complete"]
        except Exception as error:
            parser.exit(1, f"{type(error).__name__}: {error}\n")
        parser.exit(0 if success else 1)
    if args.status:
        print(json.dumps(inspect(args.state_dir)))
        return
    if not args.consumer:
        parser.error("--consumer module:app is required")
    state = State(
        args.state_dir,
        max_reports=int(environment.get("MONDEK_SPOOL_MAX_REPORTS", "1000")),
        max_bytes=int(environment.get("MONDEK_SPOOL_MAX_BYTES", "2097152")),
    )

    async def start() -> None:
        runner = Runner(
            state,
            args.controller,
            max_concurrency=int(environment.get("MONDEK_MAX_CONCURRENCY", "3")),
            consumer=args.consumer,
        )
        loop = asyncio.get_running_loop()
        for sig in (signal.SIGINT, signal.SIGTERM):
            loop.add_signal_handler(sig, runner.stopped.set)
        print(
            json.dumps(
                {
                    "event": "runner_started",
                    "installation_id": state.installation_id,
                    "session_id": state.session_id,
                    "boot": state.boot,
                    "assignments": list(runner.active),
                }
            ),
            flush=True,
        )
        await runner.run()

    try:
        asyncio.run(start())
    finally:
        state.close()


if __name__ == "__main__":
    main()
