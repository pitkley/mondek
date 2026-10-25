# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Controlled Linux proc/systemd fixtures; no host service or secrets inspected."""

import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from mondek_runner import doctor
from mondek_runner.controller_auth import ENVIRONMENT_VARIABLE


class DoctorServiceContextTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.process = Path(self.temporary.name)
        self.write_stat("12345")
        (self.process / "status").write_text(
            "Name:\trunner\nUid:\t4242\t4242\t4242\t4242\n"
            "Gid:\t4343\t4343\t4343\t4343\nGroups:\t44 4343\n"
        )
        self.write_environment(
            {
                "MONDEK_CONTROLLER_URL": "https://controller.example",
                ENVIRONMENT_VARIABLE: "/state/controller-auth.json",
                "SSL_CERT_FILE": "/etc/test-ca.pem",
                "HTTPS_PROXY": "http://proxy.example:3128",
                "NO_PROXY": "localhost",
                "APP_SECRET": "NEVER_COPY_THIS",
                "PYTHONPATH": "/untrusted/consumer",
                "LD_PRELOAD": "/untrusted/library.so",
                "HOME": "/untrusted/home",
            }
        )
        self.path_mock = self.enterContext(
            patch.object(doctor, "Path", return_value=self.process)
        )
        self.pid = self.enterContext(
            patch.object(doctor, "_main_pid", return_value=123)
        )
        self.euid = self.enterContext(
            patch.object(doctor.os, "geteuid", return_value=0)
        )
        self.enterContext(patch.object(doctor.os, "getegid", return_value=4343))
        self.enterContext(patch.object(doctor.os, "getgroups", return_value=[44, 4343]))

    def write_stat(self, start):
        # Linux comm can contain spaces and closing parentheses.
        fields = ["S"] + ["0"] * 18 + [start] + ["0"] * 10
        (self.process / "stat").write_text("123 (runner ) process) " + " ".join(fields))

    def write_environment(self, settings):
        (self.process / "environ").write_bytes(
            b"\0".join(f"{key}={value}".encode() for key, value in settings.items())
            + b"\0"
        )

    def test_root_uses_allowlisted_service_environment_and_exact_credentials(self):
        env, identity = doctor.service_context("mondek-runner.service")
        self.assertEqual(
            env,
            {
                "MONDEK_CONTROLLER_URL": "https://controller.example",
                ENVIRONMENT_VARIABLE: "/state/controller-auth.json",
                "SSL_CERT_FILE": "/etc/test-ca.pem",
                "HTTPS_PROXY": "http://proxy.example:3128",
                "NO_PROXY": "localhost",
            },
        )
        self.assertEqual(
            identity, {"user": 4242, "group": 4343, "extra_groups": [44, 4343]}
        )
        self.path_mock.assert_called_once_with("/proc/123")
        self.assertEqual(self.pid.call_count, 2)
        self.assertNotIn("NEVER_COPY_THIS", repr((env, identity)))

    def test_nonroot_different_uid_is_rejected_without_sensitive_context(self):
        self.euid.return_value = 1000
        with self.assertRaisesRegex(ValueError, "sudo") as error:
            doctor.service_context("mondek-runner")
        self.assertNotIn("NEVER_COPY_THIS", str(error.exception))
        self.assertNotIn("controller-auth.json", str(error.exception))

    def test_matching_nonroot_account_does_not_attempt_privilege_change(self):
        self.euid.return_value = 4242
        _, identity = doctor.service_context("mondek-runner")
        self.assertEqual(identity, {})

    def test_matching_uid_with_different_groups_requires_sudo(self):
        self.euid.return_value = 4242
        for gid, groups in ((9999, [44, 4343]), (4343, [4343])):
            with self.subTest(gid=gid, groups=groups):
                with (
                    patch.object(doctor.os, "getegid", return_value=gid),
                    patch.object(doctor.os, "getgroups", return_value=groups),
                    self.assertRaisesRegex(ValueError, "sudo"),
                ):
                    doctor.service_context("mondek-runner")

    def test_systemd_pid_changed_during_inspection_is_rejected(self):
        self.pid.side_effect = [123, 124]
        with self.assertRaisesRegex(ValueError, "running systemd service"):
            doctor.service_context("mondek-runner")

    def test_reused_pid_with_different_start_time_is_rejected(self):
        def main_pid(_service):
            if self.pid.call_count == 2:
                self.write_stat("99999")
            return 123

        self.pid.side_effect = main_pid
        with self.assertRaisesRegex(ValueError, "running systemd service"):
            doctor.service_context("mondek-runner")

    def test_missing_controller_setting_and_malformed_process_are_rejected(self):
        self.write_environment({"APP_SECRET": "NEVER_COPY_THIS"})
        with self.assertRaisesRegex(ValueError, "MONDEK_CONTROLLER_URL"):
            doctor.service_context("mondek-runner")
        self.write_environment({"MONDEK_CONTROLLER_URL": "https://controller.example"})
        (self.process / "stat").write_text("invalid process data")
        with self.assertRaises(ValueError):
            doctor.service_context("mondek-runner")

    def test_oversized_environment_is_rejected(self):
        (self.process / "environ").write_bytes(b"X" * (1024 * 1024 + 1))
        with self.assertRaises(ValueError):
            doctor.service_context("mondek-runner")

    def test_service_names_cannot_be_options_or_shell_fragments(self):
        for service in ("--all", "runner;id", "runner\nother", "", "x" * 202):
            with self.subTest(service=service), self.assertRaises(ValueError):
                doctor.service_context(service)
        self.pid.assert_not_called()


class DoctorSystemdPidTests(unittest.TestCase):
    def test_systemctl_is_bounded_and_uses_argument_array(self):
        result = subprocess.CompletedProcess([], 0, b"1234\n", b"")
        with patch.object(doctor.subprocess, "run", return_value=result) as run:
            self.assertEqual(doctor._main_pid("mondek-runner"), 1234)
        run.assert_called_once_with(
            [
                "systemctl",
                "show",
                "mondek-runner",
                "--property=MainPID",
                "--value",
            ],
            capture_output=True,
            timeout=5,
            check=False,
        )

    def test_stopped_failed_or_unparseable_services_are_rejected(self):
        for code, output in (
            (0, b"0\n"),
            (0, b"1\n"),
            (1, b"123\n"),
            (0, b"MainPID=123"),
            (0, b"123\n456\n"),
        ):
            with self.subTest(code=code, output=output):
                result = subprocess.CompletedProcess([], code, output, b"PRIVATE ERROR")
                with (
                    patch.object(doctor.subprocess, "run", return_value=result),
                    self.assertRaises(ValueError) as error,
                ):
                    doctor._main_pid("mondek-runner")
                self.assertNotIn("PRIVATE ERROR", str(error.exception))
