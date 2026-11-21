# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""A packaged controller resumes per-output sustain after recreation."""

from acceptance import Acceptance, ROOT


class SustainAcceptance(Acceptance):
    def detail(self):
        stream = next(iter(self.request("/api/v1/results")["items"]))
        return self.request(f"/api/v1/results/{stream['id']}/inspection")

    def pending(self):
        detail = self.detail()
        qualification = detail["stream"]["qualification"] or {}
        if (
            detail["stream"]["current"].get("health") == "CRIT"
            and qualification.get("effective_health") == "OK"
        ):
            return next(p for p in qualification["pending"] if p["health"] == "CRIT")

    def trial(self):
        self.compose(
            "up",
            "--build",
            "-d",
            "--wait",
            "--wait-timeout",
            "180",
            "controller",
            "runner",
        )
        self.eventually(
            "installed runner establishes qualified OK",
            lambda: (
                (self.detail()["stream"]["qualification"] or {}).get("effective_health")
                == "OK"
            ),
        )
        self.mode(ready=False)
        before = self.eventually("failure is measured and pending", self.pending)
        assert not self.detail()["incidents"]
        assert not self.records()
        self.compose(
            "up",
            "-d",
            "--no-deps",
            "--force-recreate",
            "--wait",
            "--wait-timeout",
            "60",
            "controller",
        )
        after = self.eventually(
            "controller restores the same pending candidate", self.pending, timeout=10
        )
        assert before == after
        assert not self.detail()["incidents"]
        assert not self.records()

        def qualified():
            detail = self.detail()
            qualification = detail["stream"]["qualification"]
            if qualification["effective_health"] == "CRIT" and detail["incidents"]:
                return detail

        detail = self.eventually("fresh evidence qualifies CRIT", qualified, timeout=45)
        (incident,) = detail["incidents"]
        assert incident["health"] == "CRIT" and incident["status"] == "open"
        evidence = detail["stream"]["qualification"]["effective_observation_id"]
        assert evidence != before["first_observation_id"]
        assert evidence == incident["latest_failure_observation_id"]
        self.eventually(
            "local recording receiver gets the firing delivery",
            lambda: any(
                record["payload"].get("incident_id") == incident["id"]
                and record["payload"].get("kind") == "firing"
                for record in self.records()
            ),
        )
        return {
            "pending": before,
            "qualified_observation": evidence,
            "incident": incident["id"],
        }

    def run(self):
        overlay = self.output / "sustain.compose.yaml"
        overlay.write_text(
            "services:\n  runner:\n    environment:\n"
            "      MONDEK_CONSUMER: output_sustain:app\n    volumes:\n"
            "      - ./tests/e2e/fixtures/output_sustain.py:/app/examples/output_sustain.py:ro\n"
        )
        self.env.pop("MONDEK_CI_IMAGES", None)
        self.env["COMPOSE_FILE"] = f"{ROOT / 'compose.yaml'}:{overlay}"
        success = False
        try:
            self.run_step("qualified delivery across controller recreation", self.trial)
            success = True
        finally:
            self.finish(success)


if __name__ == "__main__":
    SustainAcceptance(dynamic_ports=True).run()
