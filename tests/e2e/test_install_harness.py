# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Cold-cache dependency preparation without deleting local Docker images."""

import subprocess
import unittest

from install import start_services


class InstallationPreparationTest(unittest.TestCase):
    def test_cold_cache_fetches_database_and_keeps_qualified_controller(self):
        cache = {"controller": "sha256:qualified-controller"}
        started = False
        compose = ["docker", "compose", "-p", "isolated-install"]

        def docker(*command):
            nonlocal started
            self.assertEqual(list(command[: len(compose)]), compose)
            arguments = command[len(compose) :]
            if arguments[0] == "pull":
                # A registry pull of the controller could replace the candidate.
                self.assertEqual(arguments[1:], ("postgres",))
                cache["postgres"] = "sha256:pinned-postgres"
            elif arguments[0] == "up":
                self.assertEqual(arguments[-2:], ("--pull", "never"))
                if "postgres" not in cache:
                    raise RuntimeError("cold runner has no PostgreSQL image")
                self.assertEqual(cache["controller"], "sha256:qualified-controller")
                started = True
            else:
                self.fail(f"Unexpected Docker operation: {arguments}")

        start_services(compose, docker)
        self.assertTrue(started)
        self.assertIn("postgres", cache)
        self.assertEqual(cache["controller"], "sha256:qualified-controller")

    def test_dependency_pull_failure_prevents_service_start(self):
        attempted = []
        compose = ["docker", "compose", "-p", "isolated-install"]

        def docker(*command):
            attempted.append(command[len(compose)])
            if attempted[-1] == "pull":
                raise subprocess.CalledProcessError(1, command)
            self.fail("Services must not start after a failed dependency pull")

        with self.assertRaises(subprocess.CalledProcessError):
            start_services(compose, docker)
        self.assertEqual(attempted, ["pull"])
