# Experimental alpha candidate

Mondek's first planned publication is experimental. It includes a Phoenix/LiveView controller with PostgreSQL/Oban, an independently scheduled Python runner/SDK, standard packs, generic consumers, versioned protocols and real acceptance/browser suites.

Start an empty local controller or the isolated demo using the [README](../README.md). For your own monitoring project, follow the [installation and distribution guide](DISTRIBUTION.md), retain the selected SDK artifact/checksum and keep runner state across updates. The [porting guide](MIGRATING-CONSUMERS.md) describes translating existing checks into a separate consumer project. Run a representative subset in parallel before expanding it.

The controller provides result inventory and history, incidents, local notification delivery, delegated configuration with Git history, maintenance windows and runner/adoption inspection. Runners preserve original evidence identity and age through outages and restart. The maintained [coverage map](ACCEPTANCE-COVERAGE.md) distinguishes native, packaged smoke, selected browser and manual exhaustive verification.

The SDK version is 0.0.1a2 and controller version is 0.0.1-alpha.2. These alpha versions do not establish a stable compatibility promise. Use the same reviewed source revision for controller and SDK initially. The [upgrade guide](UPGRADING.md) explains the fresh database baseline, state preservation and update verification; it does not promise arbitrary mixed versions or zero-downtime upgrades.

See the [contract guide](../contracts/README.md) for protocol versioning and shared fixture coverage.

This preview ships source, not published container images or registry packages. Build locally from the selected revision. The sample runner image is a demonstration rather than a generic deployment base. See [licensing](LICENSING.md) for image inventory and notice coverage. Review the [controller access boundary](CONTROLLER-AUTH.md) before hosting an installation and [security guidance](../SECURITY.md) for private vulnerability reporting. Production replacement and production-readiness guarantees are outside this preview.
