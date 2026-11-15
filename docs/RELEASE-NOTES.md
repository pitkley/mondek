# Mondek 0.0.3

This release makes incident reads self-contained for lightweight clients. Controller and SDK versions are both `0.0.3`; the intended Git tag is `v0.0.3` and controller image tag is `0.0.3`. Mondek remains experimental.

## Incident investigation

Incident lists and details include a canonical `display_title` shared with the web UI, nullable check/result/environment/runner labels and an authoritative `acknowledgement_active` boolean evaluated at the response time. Shared incidents retain their own identity instead of inventing a single contributing check or runner. Incident reads need no result-endpoint lookup to identify or explain the incident.

Individual health details and each shared contribution expose `recorded_measurement`: selected historical WARN/CRIT evidence, Markdown details, original source/evaluation/receipt times, observation provenance and explicit fallback/unavailable reasons. Current results and recovery evidence stay separate. Shared contributions replace the ambiguous `measured_result` response field; update clients from the generated [OpenAPI contract](../contracts/http/v1/openapi.json). Monitoring-loss incidents do not imply measured target failure.

A dedicated latest-failure observation reference advances on every admitted failure, including unchanged severity, and survives recovery and ordinary receipt retention. Previously recorded opening/notification evidence can be an explicitly labelled fallback; historical latest evidence is never invented from current state or notification text.

## Upgrading

Back up PostgreSQL and complete runner state, then use matching controller/SDK releases. Packaged startup applies an additive database migration for the nullable failure reference; existing baseline history is unchanged. Existing incident/report identities, buffered reports, runner transport format and configuration history are preserved. No journal or database reset is needed. Existing incidents without a provable latest failure remain explicit fallback/unavailable until new evidence establishes it. See [upgrading](UPGRADING.md#003-historical-incident-findings).

Authentication and authorization remain the deployment's responsibility. An incident-read policy exposes that incident's selected evidence and details without granting unrelated result access; see the [access boundary](CONTROLLER-AUTH.md).
