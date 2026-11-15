# Mondek 0.0.2

This release unifies the controller HTTP APIs and adds a documented API for read-only integrations, including incident investigation. The SDK and controller versions are both `0.0.2`; the intended Git tag is `v0.0.2` and controller image tag is `0.0.2`. Mondek remains experimental.

## Breaking HTTP and runner changes

Upgrade the controller and SDK/runners together. Version 0.0.1 runners cannot communicate with the 0.0.2 controller, and 0.0.2 runners cannot communicate with the 0.0.1 controller. Runner exchanges move from `/api/v1/{control,inventory,observations}` to `/api/v1/runner/{control,inventory,observations}` with no compatibility aliases.

Resource reads use `{data,meta}` envelopes and structured errors include a request ID. Result inspection uses `/api/v1/results`; assignment inspection uses `/api/v1/assignments`, with editable settings under `/api/v1/assignments/:id/configuration`. Health and monitoring-loss incidents use separate collections. Update integrations and any gateway path policies using the [route disposition table](API-ROUTES.md).

## API contracts and integrations

The unified `/api/v1` surface covers results, incidents, observations, runners, coverage, maintenance, configuration and existing runner exchanges. Read-only integrations can inspect monitoring state and evidence without using the operator UI. OpenAPI is generated from the Phoenix operation and schema definitions, checked into `contracts/http/v1/openapi.json`, served at `/api/v1/openapi.json` and browsable at `/api/docs`. Contract checks reject stale generated output and duplicate operation IDs.

MCP remains a separate transport and shares investigation projections with the HTTP API. HTTP version 1, runner report format version 1 and MCP schema version 1 are unchanged; these identify formats rather than release numbers. Built-in authentication and permission management remain out of scope; retain the existing [external access boundary](CONTROLLER-AUTH.md).

## Upgrading

Back up PostgreSQL and each runner's complete durable state, then stop the old runners, upgrade the controller against the existing database and start the matching 0.0.2 SDK/runners. Retain installation identities, journals, buffered reports and configuration history. SDK updates require normal discovery/preparation for the new runtime identity. Verify fresh adopted measurements, retained incidents and pending notifications after the update. See the [coordinated upgrade guide](UPGRADING.md#002-unified-http-api-cutover).

This release adds no database migration or stored report/configuration format change. Packaged startup continues to apply pending migrations automatically. Controller configuration repository identity is initialized before HTTP starts; reading its revision no longer creates durable state. Buffered reports retain their original identities, ages and replay dispositions.
