# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Byte-bounded diagnostic text, shared without importing the authoring SDK."""


def truncate_utf8(value: str, max_bytes: int = 2048) -> str:
    """Keep text within a wire byte limit without splitting a Unicode character."""
    return value.encode()[:max_bytes].decode(errors="ignore")


def diagnostic_text(value: str, max_bytes: int = 2048) -> str:
    """Escape non-wire text in generated diagnostics, then bound UTF-8 bytes.

    Authored evidence is validated, never repaired. Diagnostics may describe
    arbitrary exceptions, including NUL and Python's unpaired surrogates.
    """
    safe = value.replace("\x00", "\\x00").encode("utf-8", errors="backslashreplace")
    return safe[:max_bytes].decode("utf-8", errors="ignore")
