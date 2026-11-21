#!/usr/bin/env python3
# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Qualify installed catalog-generated assignments with 24 independent nodes."""

import json
from datetime import datetime, timezone

from acceptance import Acceptance, run_compose

SOURCE = "node-catalog"
NODES = {f"node-{index:02}" for index in range(1, 25)}
CHANGED = "node-01"
ADDED = "node-25"


class NodeCatalogAcceptance(Acceptance):
    def __init__(self):
        super().__init__(dynamic_ports=True)
        self.inputs = self.output / "node-inputs"
        self.inputs.mkdir(mode=0o755)
        self.override = self.output / "catalog.json"
        self.override.write_text(
            json.dumps(
                {
                    "services": {
                        "controller": {
                            "environment": {"MONDEK_NOTIFICATION_ADAPTER": "off"}
                        },
                        "runner": {
                            "build": {"dockerfile": "examples/consumers/Dockerfile"},
                            "environment": {
                                "MONDEK_CONSUMER": "mondek_examples.node_catalog:app",
                                "MONDEK_NODE_CATALOG_DIR": "/catalog",
                                "MONDEK_SPOOL_MAX_REPORTS": "128",
                                "MONDEK_SPOOL_MAX_BYTES": "524288",
                            },
                            "volumes": [
                                {
                                    "type": "bind",
                                    "source": str(self.inputs),
                                    "target": "/catalog",
                                    "read_only": True,
                                }
                            ],
                        },
                    }
                }
            )
        )

    def compose(self, *args, capture=False, timeout=900):
        return run_compose(
            [
                "docker",
                "compose",
                "-p",
                self.project,
                "-f",
                "compose.yaml",
                "-f",
                str(self.override),
                *args,
            ],
            env=self.env,
            log=self.log,
            capture=capture,
            timeout=timeout,
        )

    def write_input(self, name, content):
        path = self.inputs / name
        temporary = path.with_suffix(".next")
        temporary.write_text(content)
        temporary.chmod(0o644)
        temporary.replace(path)

    def roster(self, nodes):
        self.write_input("nodes.json", json.dumps(sorted(nodes)))

    def results(self):
        rows = self.request(f"/api/v1/results?source_id={SOURCE}&page_size=100")
        nodes = {
            row["source_key"].removeprefix("node."): row
            for row in rows["items"]
            if row["source_key"].startswith("node.")
        }
        return nodes

    def measured(self, nodes, *, critical=None, after=None):
        rows = self.results()
        if rows.keys() != nodes:
            return False
        for node, row in rows.items():
            current = row["current"]
            if (
                current.get("knowledge") != "fresh"
                or current.get("health") != ("CRIT" if node == critical else "OK")
                or not current.get("complete")
                or current.get("confirmed_observation_id")
                != current.get("observation_id")
                or current.get("confirmed_generation") != row["desired_generation"]
                or row["active_generation"] != row["desired_generation"]
                or (
                    after is not None
                    and datetime.fromisoformat(current["source_at"]) <= after
                )
            ):
                return False
        return rows

    def exact_observation(self, row, observation_id):
        return self.request(f"/api/v1/results/{row['id']}/evidence/{observation_id}")

    def capture_report(self, observation_id):
        return next(
            report
            for row in self.request("/transport-records", fixture=True)["records"]
            for report in row["request"]["reports"]
            if report["id"] == observation_id
        )

    def clean_catalog(self):
        self.roster(NODES)
        for node in NODES | {ADDED}:
            self.write_input(f"{node}.status", "up\n")
        self.compose("up", "--build", "--detach", "--wait", "--wait-timeout", "180")
        self.resolve_host_ports()
        self.platform_evidence()
        initial = self.eventually(
            "24 fresh generated node results", lambda: self.measured(NODES)
        )
        assert len({row["id"] for row in initial.values()}) == len(NODES)
        assert len({row["assignment_id"] for row in initial.values()}) == len(NODES)
        for node, row in initial.items():
            assert row["target"]["key"] == f"node:{node}"
            assert row["result_key"] == "health"
        self.initial = initial
        return {"generated_nodes": len(initial)}

    def independent_health(self):
        self.write_input(f"{CHANGED}.status", "down\n")
        changed_at = datetime.now(timezone.utc)
        current = self.eventually(
            "one fresh Critical and 23 freshly collected healthy peers",
            lambda: self.measured(NODES, critical=CHANGED, after=changed_at),
        )
        failed = current[CHANGED]
        failure_id = failed["current"]["observation_id"]
        self.failure_report = self.eventually(
            "capture exact failure report from real HTTP transport",
            lambda: self.capture_report(failure_id),
        )
        assert self.exact_observation(failed, failure_id)["result"]["health"] == "CRIT"
        assert all(current[node]["id"] == self.initial[node]["id"] for node in NODES)
        assert all(
            current[node]["source_revision"] == self.initial[node]["source_revision"]
            for node in NODES
        )

        self.write_input(f"{CHANGED}.status", "up\n")
        restored_at = datetime.now(timezone.utc)
        healthy = self.eventually(
            "measured recovery on the same result",
            lambda: self.measured(NODES, after=restored_at),
        )
        assert healthy[CHANGED]["id"] == failed["id"]
        assert healthy[CHANGED]["current"]["observation_id"] != failure_id
        assert (
            self.exact_observation(healthy[CHANGED], failure_id)["result"]["health"]
            == "CRIT"
        )
        return {"failed_result": failed["id"], "failure_observation": failure_id}

    @staticmethod
    def identity(result):
        return result["assignment_id"], result["id"]

    def membership_and_replay(self):
        changed = (NODES - {CHANGED}) | {ADDED}
        retired = self.initial[CHANGED]
        self.roster(changed)
        current = self.eventually(
            "complete scan adds one node, retires one after grace, and measures survivors",
            lambda: self.measured(changed),
        )
        for node in NODES & changed:
            assert self.identity(current[node]) == self.identity(self.initial[node])
        after_withdrawal = current
        assert self.request(f"/api/v1/results/{retired['id']}")["retired"]
        assert (
            self.send_report(self.failure_report)["dispositions"][0]["disposition"]
            == "duplicate"
        )

        self.roster(NODES | {ADDED})
        current = self.eventually(
            "returned node records fresh evidence on a new result",
            lambda: self.measured(NODES | {ADDED}),
        )
        for node in changed:
            assert self.identity(current[node]) == self.identity(after_withdrawal[node])
        returned = current[CHANGED]
        assert returned["id"] != retired["id"]
        assert returned["assignment_id"] != retired["assignment_id"]
        failure_id = self.failure_report["id"]
        assert self.exact_observation(retired, failure_id)["result"]["health"] == "CRIT"
        self.request(
            f"/api/v1/results/{returned['id']}/evidence/{failure_id}", code=404
        )
        self.returned = current
        return {"retired_result": retired["id"], "returned_result": returned["id"]}

    def reject_overflow(self):
        self.roster({f"node-{index:02}" for index in range(1, 34)})
        self.eventually(
            "runner records an actual failed scan and retains previous resources",
            lambda: (
                "node-catalog: discovery failed (ValueError); prior resources retained"
                in (self.status().get("diagnostic") or "")
            ),
        )
        after = datetime.now(timezone.utc)
        retained = self.eventually(
            "previous catalog still executes after the rejected scan",
            lambda: self.measured(NODES | {ADDED}, after=after),
        )
        assert {
            key: (row["id"], row["source_revision"]) for key, row in retained.items()
        } == {
            key: (row["id"], row["source_revision"])
            for key, row in self.returned.items()
        }
        return {"overflow_nodes": 33, "retained_nodes": len(retained)}

    def run(self):
        success = False
        try:
            self.run_step(
                "installed catalog with 24 distinct node checks", self.clean_catalog
            )
            self.run_step(
                "independent health and exact evidence", self.independent_health
            )
            self.run_step(
                "membership generations and exact replay", self.membership_and_replay
            )
            self.run_step("oversized scan preserves measurements", self.reject_overflow)
            success = True
        finally:
            self.finish(success)
            print(f"Evidence: {self.output}", flush=True)


if __name__ == "__main__":
    NodeCatalogAcceptance().run()
