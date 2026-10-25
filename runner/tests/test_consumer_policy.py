# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Consumer-owned composition uses ordinary Python, not a domain SDK."""

import json
import unittest
from unittest.mock import MagicMock, patch

from demo_checks.backlog import (
    BacklogDatasource,
    BacklogPolicy,
    BacklogSnapshot,
    backlog,
)
from source_fixtures import assignment as fixture_assignment
from source_fixtures import worker_source

from mondek_runner import Result
from mondek_runner.worker import run as run_worker

SOURCE_AT = "2030-05-20T12:00:00.000000Z"


class BacklogPolicyTests(unittest.TestCase):
    def test_count_boundaries_and_processing_findings_combine_without_losing_severity(
        self,
    ):
        policy = BacklogPolicy(warn_count=5, crit_count=10)
        for count, enabled, health in (
            (0, False, "OK"),
            (2, True, "OK"),
            (2, False, "CRIT"),
            (5, True, "WARN"),
            (5, False, "CRIT"),
            (10, True, "CRIT"),
            (10, False, "CRIT"),
        ):
            with self.subTest(count=count, enabled=enabled):
                result = policy.evaluate(BacklogSnapshot(count, SOURCE_AT, enabled))
                self.assertIsInstance(result, Result)
                self.assertEqual(result.health, health)
                self.assertEqual(result.key, "backlog")
                self.assertEqual(result.summary, f"{count} queued items")
                self.assertEqual(result.value, count)
                self.assertEqual(result.source_at, SOURCE_AT)
                self.assertIn("Warning at: 5 items", result.details)
                self.assertIn("Critical at: 10 items", result.details)
                self.assertIn(f"Processing enabled: {enabled}", result.details)
                if not enabled and count:
                    self.assertIn("queued work remains", result.details)

    def test_empty_paused_queue_still_obeys_the_authored_count_policy(self):
        result = BacklogPolicy(0, 10).evaluate(BacklogSnapshot(0, SOURCE_AT, False))
        self.assertEqual(result.health, "WARN")
        self.assertIn("no queued work", result.details)


class BacklogDatasourceTests(unittest.IsolatedAsyncioTestCase):
    async def collect(self, data):
        response = MagicMock()
        response.read.return_value = json.dumps(data).encode()
        response.__enter__.return_value = response
        with patch("demo_checks.backlog.urllib.request.urlopen", return_value=response):
            snapshot = await BacklogDatasource("http://unused.invalid/data").collect()
        response.read.assert_called_once_with(65537)
        return snapshot

    async def test_optional_processing_flag_preserves_existing_source_age(self):
        for extra, enabled in (
            ({}, True),
            ({"processing_enabled": True}, True),
            ({"processing_enabled": False}, False),
        ):
            with self.subTest(extra=extra):
                snapshot = await self.collect(
                    {"backlog": 2, "source_at": SOURCE_AT, **extra}
                )
                self.assertEqual(snapshot.processing_enabled, enabled)
                self.assertEqual(snapshot.source_at, SOURCE_AT)

    async def test_non_boolean_processing_flag_is_collection_failure(self):
        for value in (None, 0, 1, "true", "false", [], {}):
            with (
                self.subTest(value=value),
                self.assertRaisesRegex(ValueError, "must be a boolean"),
            ):
                await self.collect({"backlog": 0, "processing_enabled": value})

    async def test_only_absent_source_time_uses_collection_time(self):
        with patch("demo_checks.backlog.timestamp", return_value=SOURCE_AT):
            missing = await self.collect({"backlog": 2})
            unknown = await self.collect({"backlog": 2, "source_at": None})
        self.assertEqual(missing.source_at, SOURCE_AT)
        self.assertIsNone(unknown.source_at)
        self.assertIsNone(BacklogPolicy(5, 10).evaluate(unknown).source_at)

    async def test_malformed_falsey_source_time_fails_worker_admission(self):
        assignment = fixture_assignment("consumer")
        for source_at in ("", 0, False, [], {}):
            with self.subTest(source_at=source_at):
                response = MagicMock()
                response.read.return_value = json.dumps(
                    {"backlog": 2, "source_at": source_at}
                ).encode()
                response.__enter__.return_value = response
                messages = []
                with (
                    patch(
                        "demo_checks.backlog.urllib.request.urlopen",
                        return_value=response,
                    ),
                    worker_source(backlog, assignment),
                    patch("mondek_runner.worker.emit", side_effect=messages.append),
                ):
                    await run_worker(assignment)
                self.assertEqual(len(messages), 1)
                self.assertFalse(messages[0]["complete"])
                self.assertIn("source_at", messages[0]["diagnostic"])

    async def test_existing_async_check_uses_consumer_policy_and_returns_frozen_result(
        self,
    ):
        class ApplicationSource:
            async def collect(self):
                return BacklogSnapshot(2, SOURCE_AT, False)

        result = await backlog(
            params={"warn_count": 5, "crit_count": 10},
            datasource=ApplicationSource(),
        )
        self.assertIsInstance(result, Result)
        self.assertEqual(result.health, "CRIT")
        self.assertEqual(result.summary, "2 queued items")
        self.assertEqual(result.source_at, SOURCE_AT)
        self.assertIn("Processing enabled: False", result.details)
