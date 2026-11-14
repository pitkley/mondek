# Mondek 0.0.1

This release replaces the operator interface with the Pearl design. The Python SDK and controller versions are both `0.0.1`; the Git tag is `v0.0.1` and controller image tag is `0.0.1`. Mondek remains experimental, with no stable compatibility or production-readiness guarantee; removing the prerelease suffix does not change that scope.

## Operator interface

The new interface replaces the legacy UI at the root URL. A compact overview combines results, monitoring gaps and open incidents. Incidents, checks, coverage, maintenance, configuration, discovery, runners and notification delivery use consistent tables, status colors, filters and pagination.

Search accepts plain text and editable filter chips, with keyboard navigation. Related incidents, contributing results and evidence open in stacked investigation panels. Panels and full detail pages share their entity content, including acknowledgement controls, maintenance settings, delivery evidence and histories. Check details support rendered Markdown with unsafe HTML and links excluded.

Coverage separates declared results from runner diagnostics so unresolved declarations can be reviewed without mistaking them for measurements. Current health, monitoring freshness, retained evidence and notification controls remain distinct. Webhook destination secrets are excluded from operator views.

## Security update

The locked Ecto dependency is updated to 3.14.3 to address CVE-2026-118391, unbounded query-cache growth from interpolated JSON paths, `splice/1` lists and `constant/1` values. Dependency notices and inventories are regenerated for the patched version. The dependency advisory audit remains a release gate.

## Upgrading

Back up PostgreSQL and each runner's durable state before replacing artifacts. Use matching controller/SDK releases or build both from the same reviewed source revision. Preserve runner installation/state identities and verify fresh adopted measurements after the update. This release adds no database schema migration; packaged startup continues to apply pending migrations automatically. See [upgrading](UPGRADING.md).

Browser routes have changed. The legacy interface and `/next` prefix are removed rather than redirected. Existing bookmarks and links in previously sent notifications may no longer resolve; open the root interface and find the relevant entity again. Stored measurements, incidents and configuration history are retained.

For installations upgrading from 0.0.1a2, the already published [0.0.1a3 release](https://github.com/pitkley/mondek/releases/tag/v0.0.1a3) also introduced PostgreSQL TLS, production webhooks and explicit production database defaults. Directly launched controllers must supply the intended database name and port; retain old webhook destination definitions and credentials until queued work drains. The [upgrade guide](UPGRADING.md) records these requirements.

Externally accessible installations still require an authentication gateway: Mondek has no built-in operator authentication or permission management. Review the [access boundary](CONTROLLER-AUTH.md) and [acceptance coverage](ACCEPTANCE-COVERAGE.md). Notification routing and fan-out remain outside this release. The sample runner image remains a demo, not a generic consumer deployment base.
