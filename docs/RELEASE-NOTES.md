# Mondek 0.0.1a3

This experimental alpha adds optional PostgreSQL TLS and production webhooks, and improves database configuration and packaged startup. The Python SDK version is `0.0.1a3`, the controller version is `0.0.1-alpha.3`, and the intended Git/image tags are `v0.0.1a3` and `0.0.1a3`. Use matching controller/SDK releases or build both from the same reviewed source revision. Mondek remains experimental, with no stable compatibility or production-readiness guarantee.

## PostgreSQL connections

The controller supports plain PostgreSQL and optional TLS through `PGSSLMODE=disable|require|verify-ca|verify-full`. Plain connections remain the default. Verified modes support a private CA through `PGSSLROOTCERT`; `require` enforces encryption without authenticating the server, while `verify-full` verifies both the certificate chain and hostname. TLS modes never fall back to plaintext. Outside deployment mode, Ecto's `DATABASE_URL` `ssl=true` option remains available; conflicting TLS settings and unsupported URL `sslmode` are rejected. See [database setup](../deploy/README.md#optional-postgresql-tls).

`MONDEK_DATABASE_POOL_SIZE` now configures connections per controller instance, with the existing default of 12. It must be a positive integer. Production builds default to the standard PostgreSQL port 5432 and require an explicit database name through `PGDATABASE` or, outside deployment mode, `DATABASE_URL`. Development and test database defaults remain unchanged.

## Webhooks and Microsoft Teams

Production notifications can use a generic webhook destination with a versioned Mondek JSON document or a custom JSON template. A shipped Microsoft Teams Adaptive Card template uses the same renderer and transport. Templates support typed field references, string concatenation, conditionals and bounded iteration, with JSON escaping and rendering limits; they do not execute application code. A local preview command renders lifecycle examples or supplied documents without starting services or sending requests. See [webhooks and Teams](WEBHOOK-NOTIFICATIONS.md).

One installation-level destination receives new notifications. Destination IDs and frozen delivery snapshots provide a foundation for future routing, but this release does not add routing, fan-out or target management. Credentials and secret webhook URLs stay in private runtime configuration. Queued notifications retain their original body and destination binding; old destination definitions can remain configured while those queues drain. Template failures preserve admitted monitoring evidence and become inspectable exhausted deliveries. Delivery is bounded and at least once, so duplicate delivery remains possible. HTTP acceptance does not prove that a downstream workflow posted a card or that a person read it.

## Packaged startup and documentation

Packaged startup logs a concise migration count at INFO; detailed migration instructions move to DEBUG. The runtime image includes the SCTP library expected by Erlang, removing the missing `libsctp.so.1` warning. Migration errors continue to prevent startup.

Installation documentation now reflects published GHCR images and PyPI packages, keeps local builds as a contributor alternative, and uses generic infrastructure and gateway examples.

## Upgrade notes

Back up PostgreSQL and each runner's durable state before upgrading. This release introduces no database schema migration. Startup continues to apply pending migrations automatically. Keep runner installation/state identities and verify fresh adopted measurements after replacing matching controller/SDK artifacts; see [upgrading](UPGRADING.md).

Directly launched production controllers that previously relied on development defaults must explicitly set `PGPORT=55432` and `PGDATABASE=mondek_dev` if those remain their intended database settings. Otherwise set the actual database name and use the production port default of 5432. The maintained Compose recipes already supply both settings.

Existing SMTP and local recording-webhook occurrences retain their formats and destinations. Keep inactive transport credentials and old webhook destination definitions available until their queued work drains. Authentication gateways remain necessary for externally accessible installations: Mondek has no built-in operator authentication or permission management. Review the [controller access boundary](CONTROLLER-AUTH.md) and the [acceptance coverage map](ACCEPTANCE-COVERAGE.md) for operational and verification limits. The sample runner image remains a demo, not a generic consumer deployment base.
