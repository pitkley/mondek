# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Real additive consumer schema deployment and rejected-update recovery."""

from __future__ import annotations

import json
import urllib.parse
from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:
    from parity import ParityAcceptance


class SchemaEvolutionMixin:
    def additive_schema(self: ParityAcceptance) -> dict[str, Any]:
        target = "node:node-a/export"
        before = self.stream(target)
        assignment_id = before["assignment_id"]
        old = self.assignment(assignment_id)
        edited = self.request(
            "/api/v1/assignments/" + assignment_id,
            {
                "revision": old["revision"],
                "params": old["params"] | {"warn_age_seconds": 45},
            },
            method="PUT",
        )
        self.eventually(
            "existing operator values are measured before source upgrade",
            lambda: (
                self.assignment(assignment_id)["current"].get("confirmed_generation")
                == edited["desired_generation"]
            ),
        )
        history_ids = {item["id"] for item in self.detail(before)["incidents"]}
        original = self.compose(
            "exec",
            "-T",
            "node-a-runner",
            "python",
            "-c",
            "from pathlib import Path; import mondek_examples.node as m; print(Path(m.__file__).read_text(),end='')",
            capture=True,
        )

        def replace(source: str) -> None:
            script = (
                "from pathlib import Path; import importlib.util; "
                "p=Path(importlib.util.find_spec('mondek_examples.node').origin); "
                + f"p.write_text({source!r})"
            )
            self.compose(
                "exec", "-T", "--user", "0", "node-a-runner", "python", "-c", script
            )
            self.compose("restart", "node-a-runner")

        additions = {
            'params={"warn_age_seconds": 60, "crit_age_seconds": 120},': 'params={"warn_age_seconds": 60, "crit_age_seconds": 120, "minimum_records": 2},',
            '        "warn_age_seconds": Parameter("integer", "Warning after", "seconds", 1, 86400),': '        "minimum_records": Parameter("integer", "Minimum records", "records", 1, 10000),\n'
            '        "warn_age_seconds": Parameter("integer", "Warning after", "seconds", 1, 86400),',
            '            raise ValueError("records must be a nonempty list")': '            raise ValueError("records must be a nonempty list")\n'
            '        if len(records) < params["minimum_records"]:\n'
            '            raise ValueError("records below configured minimum")',
        }
        added = original
        for old_text, new_text in additions.items():
            assert added.count(old_text) == 1, (
                "Schema test no longer matches the real consumer"
            )
            added = added.replace(old_text, new_text)
        replace(added)
        failed = self.eventually(
            "new default evaluates the actual one-record export as a failure",
            lambda: (
                item
                if (
                    (item := self.stream(target))["current"]["knowledge"] == "fresh"
                    and item["current"]["health"] == "CRIT"
                    and "records below configured minimum" in item["current"]["summary"]
                )
                else False
            ),
            timeout=90,
        )
        evolved = self.assignment(assignment_id)
        assert failed["id"] == before["id"]
        assert evolved["params"] == edited["params"] | {"minimum_records": 2}
        assert evolved["current"]["confirmed_params"] == evolved["params"]
        assert evolved["desired_generation"] > edited["desired_generation"]
        assert history_ids <= {item["id"] for item in self.detail(failed)["incidents"]}
        incident = next(
            item
            for item in self.detail(failed)["incidents"]
            if item["status"] == "open"
        )
        self.request(
            "/api/v1/assignments/" + assignment_id,
            {"revision": edited["revision"], "params": edited["params"]},
            method="PUT",
            code=409,
        )

        # A revisited list must find desired-version lag even while old evidence
        # is fresh. Stop only this test's node runner to make the stage stable.
        self.compose("stop", "node-a-runner")
        repaired = self.request(
            "/api/v1/assignments/" + assignment_id,
            {
                "revision": evolved["revision"],
                "params": evolved["params"] | {"minimum_records": 1},
            },
            method="PUT",
        )
        query = urllib.parse.urlencode(
            {"search": target, "configuration_stage": "saved"}
        )
        pending = self.request("/api/v1/configuration?" + query)
        assert pending["total"] == 1 and pending["items"][0]["id"] == assignment_id
        assert pending["configuration_summary"]["scope_total"] == 1
        self.compose("start", "node-a-runner")
        healthy = self.eventually(
            "the extended complete parameter set restores healthy measured monitoring",
            lambda: (
                item
                if (
                    (item := self.stream(target))["current"]["knowledge"] == "fresh"
                    and item["current"]["health"] == "OK"
                    and item["current"].get("confirmed_generation")
                    == repaired["desired_generation"]
                )
                else False
            ),
        )
        closed = next(
            item
            for item in self.detail(healthy)["incidents"]
            if item["id"] == incident["id"]
        )
        assert (
            closed["status"] == "closed"
            and closed["closure_reason"] == "configuration_changed"
        )
        measured_query = urllib.parse.urlencode(
            {"search": target, "configuration_stage": "measured"}
        )
        measured = self.request("/api/v1/configuration?" + measured_query)
        assert measured["total"] == 1 and measured["items"][0]["id"] == assignment_id

        # An old source cannot silently drop the new operator-owned field. Its
        # complete inventory must fail while the accepted snapshot still runs.
        accepted_revision = healthy["source_revision"]
        previous_session = healthy["current"]["session_id"]
        replace(original)

        def rejected_but_collecting() -> dict[str, Any] | bool:
            item = self.stream(target)
            runner = next(
                r
                for r in self.request("/api/v1/runners")["items"]
                if r["id"] == item["runner_id"]
            )
            return (
                item
                if (
                    "inventory not accepted"
                    in (runner["status"].get("diagnostic") or "")
                    and item["source_revision"] == accepted_revision
                    and item["current"]["session_id"] != previous_session
                    and item["current"].get("confirmed_session_id")
                    == item["current"]["session_id"]
                    and item["current"]["knowledge"] == "fresh"
                    and item["current"]["health"] == "OK"
                )
                else False
            )

        retained = self.eventually(
            "incompatible schema retains accepted code and values after restart",
            rejected_but_collecting,
            timeout=90,
        )
        assert retained["id"] == before["id"]
        assert self.assignment(assignment_id)["params"] == repaired["params"]
        restored_session = retained["current"]["session_id"]
        replace(added)

        def restored_and_accepted() -> dict[str, Any] | bool:
            item = self.stream(target)
            runner = next(
                r
                for r in self.request("/api/v1/runners")["items"]
                if r["id"] == item["runner_id"]
            )
            return (
                item
                if (
                    item["id"] == before["id"]
                    and item["source_revision"] == accepted_revision
                    and item["current"]["session_id"] != restored_session
                    and item["current"].get("confirmed_session_id")
                    == item["current"]["session_id"]
                    and item["current"]["knowledge"] == "fresh"
                    and item["current"]["health"] == "OK"
                    and "inventory not accepted"
                    not in (runner["status"].get("diagnostic") or "")
                )
                else False
            )

        self.eventually(
            "restoring the additive deployment resumes without replacing identities",
            restored_and_accepted,
        )
        details = {
            "assignment_id": assignment_id,
            "stream_id": before["id"],
            "original_history_ids": sorted(history_ids),
            "operator_values_before": edited["params"],
            "merged_source_defaults": evolved["params"],
            "measured_repaired_values": repaired["params"],
            "incident_id": incident["id"],
            "closing_observation_id": closed["closing_observation_id"],
            "rejected_schema_preserved_revision": accepted_revision,
            "configuration_stage_filter": {
                "saved_total": pending["total"],
                "measured_total": measured["total"],
            },
        }
        (self.output / "schema-evolution.json").write_text(
            json.dumps(details, indent=2)
        )
        return details
