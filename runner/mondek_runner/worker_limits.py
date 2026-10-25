# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Shared supervisor and orphan-watchdog limits."""

# Imports and saved-source verification need headroom on small native runners.
# This is independent of the check's collection deadline.
PREPARATION_TIMEOUT_SECONDS = 30
WATCHDOG_GRACE_SECONDS = 1
