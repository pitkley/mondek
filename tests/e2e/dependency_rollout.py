# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Verify a real installed-dependency rollout through an isolated controller."""

import argparse
from datetime import UTC, datetime
import json

from acceptance import Acceptance, ROOT

GRACE_SECONDS = 25

WITNESS = """
SELECT json_build_object(
  'at', clock_timestamp(),
  'runner', (SELECT to_jsonb(r) FROM runners r),
  'assignment', (SELECT to_jsonb(a) FROM assignments a WHERE retired_at IS NULL),
  'gap', (SELECT to_jsonb(g) FROM monitoring_gaps g),
  'episodes', (SELECT coalesce(json_agg(i ORDER BY opened_at), '[]') FROM monitoring_incidents i)
)
"""


def utc_time(value):
    # Ecto stores UTC timestamps without an offset. PostgreSQL's clock emits one.
    instant = datetime.fromisoformat(value)
    return instant if instant.tzinfo is not None else instant.replace(tzinfo=UTC)


class Rollout(Acceptance):
    def __init__(self, controller, baseline, candidate):
        super().__init__(dynamic_ports=True)
        self.baseline, self.candidate = baseline, candidate
        overlay = self.output / "rollout.compose.yaml"
        overlay.write_text(
            """
services:
  controller:
    image: ${ROLLOUT_CONTROLLER_IMAGE:?}
    build: !reset null
    environment:
      MONDEK_NOTIFICATION_ADAPTER: off
      MONDEK_MONITORING_LOSS_GRACE_SECONDS: ${ROLLOUT_GRACE_SECONDS:?}
  runner:
    image: ${ROLLOUT_RUNNER_IMAGE:?}
    build: !reset null
    environment:
      MONDEK_CONSUMER: dependency_rollout_check:app
      PYTHONPATH: /fixture
    volumes:
      - ./tests/e2e/fixtures/dependency_rollout_check.py:/fixture/dependency_rollout_check.py:ro
"""
        )
        self.env.pop("MONDEK_CI_IMAGES", None)
        self.env.update(
            COMPOSE_FILE=f"{ROOT / 'compose.yaml'}:{overlay}",
            PGUSER="mondek",
            PGDATABASE="mondek_dev",
            ROLLOUT_CONTROLLER_IMAGE=controller,
            ROLLOUT_RUNNER_IMAGE=baseline,
            ROLLOUT_GRACE_SECONDS=str(GRACE_SECONDS),
        )

    def witness(self):
        return json.loads(
            self.compose(
                "exec",
                "-T",
                "postgres",
                "psql",
                "-XqAt",
                "-v",
                "ON_ERROR_STOP=1",
                "-U",
                "mondek",
                "-d",
                "mondek_dev",
                "-c",
                WITNESS,
                capture=True,
            )
        )

    def established(self):
        row = self.witness()
        assignment = row["assignment"]
        return (
            row
            if assignment
            and assignment["current"].get("confirmed_generation")
            == assignment["desired_generation"]
            and assignment["current"].get("knowledge") == "fresh"
            and not row["gap"]
            else None
        )

    def switch(self, image, starting, prolonged):
        previous = starting["assignment"]
        self.mode(hold_runner_preparation=True, ready=False)
        self.env["ROLLOUT_RUNNER_IMAGE"] = image
        self.compose(
            "up", "-d", "--no-deps", "--force-recreate", "--pull", "never", "runner"
        )

        def awaiting():
            row = self.witness()
            assignment = row["assignment"]
            gap = row["gap"]
            return (
                row
                if gap
                and assignment
                and assignment["source_revision"] != previous["source_revision"]
                and assignment["desired_generation"] > previous["desired_generation"]
                and assignment["authorized_generation"]
                != assignment["desired_generation"]
                and "installed Python dependencies changed"
                in row["runner"]["status"].get("diagnostic", "")
                else None
            )

        blocked = self.eventually(
            "new inventory arrives while authorization is held", awaiting
        )
        gap = blocked["gap"]
        assert blocked["assignment"]["id"] == previous["id"]
        assert blocked["runner"]["id"] == starting["runner"]["id"]
        assert blocked["runner"]["boot"] > starting["runner"]["boot"]
        assert gap["details"]["knowledge"] != "control_contact_overdue", gap
        assert utc_time(gap["ready_at"]) > utc_time(blocked["at"])

        self.mode(hold_runner_preparation=False)

        def active():
            row = self.witness()
            assignment = row["assignment"]
            return (
                row
                if assignment["active_generation"] == assignment["desired_generation"]
                and assignment["authorized_generation"]
                == assignment["desired_generation"]
                and assignment["current"].get("generation")
                == assignment["desired_generation"]
                and assignment["current"].get("knowledge") == "unavailable"
                else None
            )

        adopted = self.eventually(
            "replacement is active without a new measurement", active
        )
        self.assert_same_gap(gap, adopted)
        contact = utc_time(adopted["runner"]["last_seen_at"])
        assert contact > utc_time(blocked["runner"]["last_seen_at"])
        old_report = previous["current"]["confirmed_observation_id"]
        assert adopted["assignment"]["current"].get("confirmed_observation_id") in (
            None,
            old_report,
        )

        episode = None
        if prolonged:
            opened = self.eventually(
                "one loss episode opens at the original deadline",
                self.with_episode,
                timeout=GRACE_SECONDS + 20,
            )
            self.assert_same_gap(gap, opened)
            (episode,) = opened["episodes"]
            assert episode["status"] == "open"
            assert utc_time(episode["opened_at"]) >= utc_time(gap["ready_at"])

        release_after = utc_time(self.witness()["at"])
        self.mode(ready=True)
        restored = self.eventually(
            "fresh authorized evidence restores monitoring", self.established
        )
        assert (
            restored["assignment"]["current"]["confirmed_observation_id"] != old_report
        )
        assert utc_time(restored["assignment"]["current"]["source_at"]) >= release_after
        if prolonged:
            (closed,) = restored["episodes"]
            assert closed["id"] == episode["id"]
            assert closed["status"] == "closed"
            assert closed["closure_reason"] == "monitoring_restored"
        else:
            assert utc_time(restored["at"]) < utc_time(gap["ready_at"])
            after_grace = self.eventually(
                "original brief deadline passes",
                lambda: self.after_deadline(gap["ready_at"]),
                timeout=GRACE_SECONDS + 10,
            )
            assert not after_grace["episodes"]
        return {"gap": gap, "episode": episode, "restored": restored["at"]}

    def with_episode(self):
        row = self.witness()
        return row if row["episodes"] else None

    def after_deadline(self, cutoff):
        row = self.witness()
        return row if utc_time(row["at"]) > utc_time(cutoff) else None

    @staticmethod
    def assert_same_gap(original, row):
        assert row["gap"], "Gap cleared before fresh authorized evidence"
        for field in ("key", "since_at", "ready_at"):
            assert row["gap"][field] == original[field], (field, original, row["gap"])
        assert row["gap"]["details"]["knowledge"] != "control_contact_overdue"

    def run(self):
        success = False
        try:
            self.compose("build", "target")
            self.compose(
                "up", "-d", "--no-build", "--pull", "never", "controller", "runner"
            )
            initial = self.eventually(
                "initial installed runner measures", self.established
            )
            self.run_step(
                "brief installed dependency change",
                lambda: self.switch(self.candidate, initial, False),
            )
            next_start = self.eventually(
                "runner remains fresh before downgrade", self.established
            )
            self.run_step(
                "prolonged dependency downgrade",
                lambda: self.switch(self.baseline, next_start, True),
            )
            success = True
        finally:
            self.finish(success)
            print(f"Evidence: {self.output}", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--controller", required=True)
    parser.add_argument("--baseline", required=True)
    parser.add_argument("--candidate", required=True)
    args = parser.parse_args()
    Rollout(args.controller, args.baseline, args.candidate).run()
