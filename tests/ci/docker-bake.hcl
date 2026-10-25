# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
# Build graph only; see docs/CI.md for Compose orchestration and exact-image reuse.
variable "MONDEK_CI_REF" { default = "local" }

group "smoke" { targets = ["controller", "runner", "fixture", "browser"] }
group "full" { targets = ["controller", "runner", "fixture", "browser", "consumer", "node", "fleet"] }

target "controller" {
  context = "."
  dockerfile = "controller/Dockerfile"
  tags = ["mondek-ci/controller:${MONDEK_CI_REF}"]
  output = ["type=docker"]
  cache-from = ["type=gha,scope=mondek-controller"]
  cache-to = ["type=gha,scope=mondek-controller,mode=max"]
}

target "runner" {
  context = "."
  dockerfile = "runner/Dockerfile"
  tags = ["mondek-ci/runner:${MONDEK_CI_REF}"]
  output = ["type=docker"]
  cache-from = ["type=gha,scope=mondek-runner"]
  cache-to = ["type=gha,scope=mondek-runner,mode=max"]
}

target "fixture" {
  context = "."
  dockerfile = "tests/fixtures/Dockerfile"
  tags = ["mondek-ci/fixture:${MONDEK_CI_REF}"]
  output = ["type=docker"]
  cache-from = ["type=gha,scope=mondek-fixture"]
  cache-to = ["type=gha,scope=mondek-fixture,mode=max"]
}

target "browser" {
  context = "."
  dockerfile = "tests/browser/Dockerfile"
  tags = ["mondek-ci/browser:${MONDEK_CI_REF}"]
  output = ["type=docker"]
  cache-from = ["type=gha,scope=mondek-browser"]
  cache-to = ["type=gha,scope=mondek-browser,mode=max"]
}

target "consumer" {
  context = "."
  dockerfile = "examples/consumers/Dockerfile"
  tags = ["mondek-ci/consumer:${MONDEK_CI_REF}"]
  output = ["type=docker"]
  cache-from = ["type=gha,scope=mondek-consumer"]
  cache-to = ["type=gha,scope=mondek-consumer,mode=max"]
}

target "node" {
  context = "."
  dockerfile = "tests/fixtures/Dockerfile.node"
  tags = ["mondek-ci/node:${MONDEK_CI_REF}"]
  output = ["type=docker"]
  cache-from = ["type=gha,scope=mondek-node"]
  cache-to = ["type=gha,scope=mondek-node,mode=max"]
}

target "fleet" {
  context = "."
  dockerfile = "tests/browser/fleet/Dockerfile"
  tags = ["mondek-ci/fleet:${MONDEK_CI_REF}"]
  output = ["type=docker"]
  cache-from = ["type=gha,scope=mondek-fleet"]
  cache-to = ["type=gha,scope=mondek-fleet,mode=max"]
}
