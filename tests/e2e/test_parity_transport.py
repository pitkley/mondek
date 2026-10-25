# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Transport-harness checks; packaged runs supply the actual acceptance proof."""

import contextlib
import copy
import json
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from parity_transport import JOURNAL_SCRIPT, exact_buffered_evidence


class TransportWitnessTests(unittest.TestCase):
    def test_changed_payload_and_replaced_arrival_age_are_rejected(self):
        report = {
            "id": "report-one",
            "evaluated_at": "2009-09-15T08:00:00.000000+00:00",
            "results": [{"health": "CRIT", "source_at": "original-source-time"}],
        }
        stored = {
            "id": report["id"],
            "payload": copy.deepcopy(report),
            "received_at": "2009-09-15T08:01:00.000000+00:00",
            "disposition": "historical",
        }
        self.assertEqual(
            exact_buffered_evidence([report], [stored]),
            {"captured": 1, "historical": 1},
        )
        postgres_timestamp = copy.deepcopy(stored)
        postgres_timestamp["received_at"] = "2009-09-15T08:01:00.000000"
        self.assertEqual(
            exact_buffered_evidence([report], [postgres_timestamp]),
            {"captured": 1, "historical": 1},
        )
        changed = copy.deepcopy(stored)
        changed["payload"]["results"][0]["health"] = "OK"
        with self.assertRaisesRegex(AssertionError, "rewrote original"):
            exact_buffered_evidence([report], [changed])
        changed = copy.deepcopy(stored)
        changed["received_at"] = report["evaluated_at"]
        with self.assertRaisesRegex(AssertionError, "arrival time"):
            exact_buffered_evidence([report], [changed])
        changed["received_at"] = "2009-09-15T08:00:00.000000"
        with self.assertRaisesRegex(AssertionError, "arrival time"):
            exact_buffered_evidence([report], [changed])

    def test_actual_inline_journal_script_reads_a_consistent_read_only_snapshot(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "runner.sqlite3"
            payload = {"id": "original", "sequence": 7, "results": []}
            with contextlib.closing(sqlite3.connect(path)) as database, database:
                database.execute(
                    "CREATE TABLE metadata(key TEXT PRIMARY KEY,value TEXT)"
                )
                database.execute(
                    "CREATE TABLE spool(payload TEXT,bytes INT,sequence INT)"
                )
                database.executemany(
                    "INSERT INTO metadata VALUES (?,?)",
                    [("boot", "2"), ("sequence", "7"), ("dropped", "0")],
                )
                database.execute(
                    "INSERT INTO spool VALUES (?,?,?)", (json.dumps(payload), 99, 7)
                )
            script = JOURNAL_SCRIPT.replace("/state/runner.sqlite3", str(path))
            output = subprocess.check_output([sys.executable, "-c", script], text=True)
            sample = json.loads(output)
            self.assertEqual(sample["reports"], [payload])
            self.assertEqual(sample["status"]["queue_count"], 1)
            self.assertEqual(sample["status"]["queue_bytes"], 99)
            self.assertEqual(sample["status"]["boot"], 2)
            with contextlib.closing(sqlite3.connect(path)) as database, database:
                self.assertEqual(
                    database.execute("SELECT count(*) FROM spool").fetchone()[0], 1
                )


if __name__ == "__main__":
    unittest.main()
