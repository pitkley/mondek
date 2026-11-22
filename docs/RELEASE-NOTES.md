# Mondek 0.0.11

Controller and SDK versions are both `0.0.11`, with Git tag `v0.0.11` and controller image tag `0.0.11`. Mondek remains experimental. Run matching controller and SDK versions.

## Incident correlation

- Declare typed dependencies on exact Conditions and targets in the SDK. Incident detail, HTTP and MCP show ranked upstream candidates and the opening evidence behind each match.
- Review and save secondary relationships across dimensions, keeping primary case membership and notification policy independent.
- Explicitly approve a deterministic rule to group two eligible standalone episodes with one matching parent. Operators can keep an episode standalone, and cases created by a rule start with batching off.
- Request advice from a configured HTTPS decisions provider. Mondek preserves the request's evidence scope and expiry across retries. Applying a proposed grouping requires operator review. See [provider setup and contract](CORRELATION-DECISIONS.md).

## Upgrading

Back up PostgreSQL and complete runner state directories before updating both components. Controller startup adds correlation policy, relationship and decision storage. See [upgrade guidance](UPGRADING.md#0011-incident-correlation-hints-relationships-and-decisions) and the [operator guide](RUNTIME-INCIDENT-CORRELATION.md).
