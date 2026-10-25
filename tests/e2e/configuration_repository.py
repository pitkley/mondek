#!/usr/bin/env python3
# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Real Git HTTP, UI-equivalent saves, file workers and durable repository restart."""

from __future__ import annotations

import argparse
import base64
import json
import subprocess

from durable_rules import DEFAULTS, DurableRulesAcceptance


class RepositoryAcceptance(DurableRulesAcceptance):
    def __init__(self) -> None:
        super().__init__()
        self.env["MONDEK_CONFIGURATION_GIT_TOKEN"] = (
            "local-acceptance-only-configuration-token"
        )
        self.checkout = self.output / "configuration"

    def git(self, *args: str, ok: bool = True) -> str:
        token = base64.b64encode(
            ("mondek:" + self.env["MONDEK_CONFIGURATION_GIT_TOKEN"]).encode()
        ).decode()
        command = ["git", "-c", f"http.extraHeader=Authorization: Basic {token}"]
        if self.checkout.exists():
            command += ["-C", str(self.checkout)]
        result = subprocess.run(
            command + list(args),
            env=self.env
            | {
                "GIT_TERMINAL_PROMPT": "0",
                "GIT_AUTHOR_NAME": "Acceptance",
                "GIT_AUTHOR_EMAIL": "acceptance@example.invalid",
                "GIT_COMMITTER_NAME": "Acceptance",
                "GIT_COMMITTER_EMAIL": "acceptance@example.invalid",
            },
            capture_output=True,
            text=True,
            timeout=60,
        )
        assert (result.returncode == 0) == ok, result.stdout + result.stderr
        return result.stdout + result.stderr

    def edit(self, params: dict[str, int], message: str) -> None:
        path = next((self.checkout / "rules").glob("*.json"))
        value = json.loads(path.read_text())
        value["params"] = params
        path.write_text(json.dumps(value, indent=2) + "\n")
        self.git("add", ".")
        self.git("commit", "-m", message)

    def roundtrip(self) -> dict:
        self.git("clone", self.base + "/configuration.git", str(self.checkout))
        initial = self.git("rev-parse", "HEAD").strip()
        self.edit(DEFAULTS, "Restore healthy limits from Git")
        self.git("push", "origin", "main")
        accepted = self.git("rev-parse", "HEAD").strip()
        self.eventually(
            "Git settings reach a real worker measurement",
            lambda: self.measured(DEFAULTS, "OK"),
        )
        self.edit_rule(params={"warning_items": 8, "critical_items": 15})
        self.git("fetch", "origin")
        ui_head = self.git("rev-parse", "origin/main").strip()
        assert ui_head != accepted
        self.edit({"warning_items": 25, "critical_items": 50}, "Stale competing edit")
        self.git("push", "origin", "main", ok=False)
        self.git("reset", "--hard", "origin/main")
        # Invalid desired values and unsupported refs do not change accepted head.
        self.edit(
            {"warning_items": 100, "critical_items": 1}, "Invalid threshold ordering"
        )
        self.git("push", "origin", "main", ok=False)
        self.git("fetch", "origin")
        assert self.git("rev-parse", "origin/main").strip() == ui_head
        self.git("push", "origin", "HEAD:refs/heads/other", ok=False)
        self.git("push", "origin", ":refs/heads/main", ok=False)
        self.git("push", "--force", "origin", initial + ":refs/heads/main", ok=False)
        self.git("reset", "--hard", "origin/main")
        self.edit(DEFAULTS, "Reconciled healthy limits")
        self.git("push", "origin", "main")
        final = self.git("rev-parse", "HEAD").strip()
        self.eventually(
            "Reconciled settings measured", lambda: self.measured(DEFAULTS, "OK")
        )
        self.compose("restart", "controller")
        self.eventually(
            "Controller returns after restart", lambda: self.request("/health")
        )
        self.git("fetch", "origin")
        assert self.git("rev-parse", "origin/main").strip() == final
        self.eventually(
            "Measurements recover after controller restart",
            lambda: self.measured(DEFAULTS, "OK"),
        )
        return {
            "initial": initial,
            "ui_commit": ui_head,
            "accepted": final,
            "invalid_pushes_rejected": True,
        }

    def run(self, browser: bool = False) -> None:
        success = False
        print(
            f"Configuration Git acceptance: {self.project}; {self.base}; {self.output}",
            flush=True,
        )
        try:
            self.run_step("Real installed observers", self.clean_start)
            self.run_step(
                "UI-equivalent rule save creates history", self.create_target_rule
            )
            self.run_step(
                "Git editing, conflicts, validation and restart", self.roundtrip
            )
            if browser:
                input(
                    f"Browser inspection: {self.base}/configuration/history — Enter to clean up: "
                )
            self.run_step(
                "Fresh installation restoration and explicit exception mapping",
                self.restore,
            )
            success = True
        finally:
            self.finish(success)
        print("Configuration Git acceptance passed", flush=True)

    def restore(self) -> dict:
        assignment = self.assignment_state()
        params = {"warning_items": 40, "critical_items": 90}
        self.request(
            "/api/v1/assignments/" + assignment["id"],
            {"revision": assignment["revision"], "params": params},
            method="PUT",
        )
        self.git("fetch", "origin")
        self.git("reset", "--hard", "origin/main")
        self.git("branch", "saved-installation")
        old_exception = next((self.checkout / "exceptions").glob("*.json")).name
        self.compose("down", "--volumes", "--remove-orphans")
        self.clean_start()
        self.git("fetch", "origin")
        self.git("reset", "--hard", "origin/main")
        fresh_head = self.git("rev-parse", "HEAD").strip()
        self.git(
            "merge",
            "--allow-unrelated-histories",
            "--no-commit",
            "-s",
            "ours",
            "saved-installation",
        )
        self.git(
            "restore", "--source", "saved-installation", "--", "rules", "exceptions"
        )
        self.git("add", ".")
        self.git("commit", "-m", "Restore saved settings with old installation scopes")
        self.git("push", "origin", "main", ok=False)
        self.git("fetch", "origin")
        assert self.git("rev-parse", "origin/main").strip() == fresh_head
        fresh = self.assignment_state()
        assert fresh["id"] != assignment["id"]
        path = self.checkout / "exceptions" / old_exception
        value = json.loads(path.read_text())
        value["scope"]["assignment_id"] = fresh["id"]
        value["scope"]["runner_installation_id"] = fresh["runner_id"]
        path.write_text(json.dumps(value, indent=2) + "\n")
        self.git("add", ".")
        self.git(
            "commit", "-m", "Explicitly map restored exception to the new observer"
        )
        self.git("push", "origin", "main")
        self.eventually(
            "Restored exception is measured", lambda: self.measured(params, "OK")
        )
        self.git("fetch", "origin")
        assert (
            self.git("rev-parse", "HEAD").strip()
            == self.git("rev-parse", "origin/main").strip()
        )
        self.git("merge-base", "--is-ancestor", "saved-installation", "main")
        return {
            "preserved_history": True,
            "old_exception_key": old_exception,
            "new_assignment": fresh["id"],
        }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--browser", action="store_true")
    RepositoryAcceptance().run(parser.parse_args().browser)
