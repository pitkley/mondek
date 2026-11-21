# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Two local CPU profiling workloads built from ordinary check bindings."""

import os

from mondek_runner import App, Binding, Environment, check, ok

COUNT = int(os.environ["MONDEK_CPU_PROFILE_CHECKS"])
API_URL = os.environ["MONDEK_CPU_PROFILE_API"]


if API_URL:
    from kubernetes import client

    @check(id="sample", expected_keys=("sample",), timeout_seconds=5)
    def sample():
        configuration = client.Configuration(host=API_URL)
        configuration.proxy = None
        with client.ApiClient(configuration) as transport:
            namespace = client.CoreV1Api(transport).read_namespace(
                "runner-cpu", _request_timeout=3
            )
        if namespace.metadata.name != "runner-cpu":
            raise ValueError("unexpected namespace from local profiling API")
        return ok("sample", "Read namespace")

else:

    @check(id="sample", expected_keys=("sample",), timeout_seconds=5)
    def sample():
        return ok("sample", "Trivial result")


app = App(
    source_id="runner-cpu-profile",
    environment=Environment("isolated-profile"),
    construction_environment={
        "MONDEK_CPU_PROFILE_CHECKS": str(COUNT),
        "MONDEK_CPU_PROFILE_API": API_URL,
    },
    checks=[Binding(sample, key=f"sample-{index:03}") for index in range(COUNT)],
)
