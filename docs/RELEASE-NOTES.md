# Mondek 0.0.4

This security release updates Plug to 1.20.4 for [CVE-2026-120287 / GHSA-qj4r-jh2r-rw3f](https://github.com/elixir-plug/plug/security/advisories/GHSA-qj4r-jh2r-rw3f). Controller and SDK versions are both `0.0.4`; the Git tag is `v0.0.4` and controller image tag is `0.0.4`. Mondek remains experimental.

## Multipart request limits

Plug's multipart parser did not charge all consumed framing and header bytes against the request-length budget, allowing unauthenticated memory exhaustion. Mondek enables this parser; Plug 1.20.4 corrects the accounting. The dependency lock and generated license inventories/notices are updated together. Regression coverage exercises bounded multipart framing rejection and ordinary form parsing through Mondek's API parser wrapper.

Published 0.0.3 and earlier controller images retain the affected dependency. Upgrade to 0.0.4; see [upgrading](UPGRADING.md#004-plug-multipart-security-fix) for gateway mitigation until upgraded.

## Upgrading

Use matching published 0.0.4 controller and SDK artifacts. This patch adds no database migration, HTTP API or runner transport format change; keep existing database, journal, buffered report and configuration identities. Upgrades from versions before 0.0.3 still apply the previously published additive incident failure-reference migration automatically at controller startup. Incident investigation improvements from 0.0.3 remain available.
