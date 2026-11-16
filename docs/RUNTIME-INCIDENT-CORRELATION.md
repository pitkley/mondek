# Runtime incident correlation

Correlation cases record suspected relationships between health incident episodes. They are separate from a declared `Condition`, which still means equivalent evidence. A case can contain individual or condition episodes, with one optional suspected parent. Cases are flat; each episode has at most one current case.

## Manual grouping

Open **Incidents → Correlation cases and manual grouping**. Create a case by choosing exact open episodes, a title and a reason. An existing case supports attach, detach, merge, split and changing its suspected parent. Review precedes save. Audit records identify Local operator, the reason, time and exact proposal. Labels and notes are untrusted text, never identifiers or authority.

All selected episodes must have the same exact monitored environment. A missing environment is an exact value. Select the shared condition, rather than one of its equivalent contributions. Attach accepts ungrouped open episodes; moving between cases requires split/detach or merge. Merge moves the complete source case. Split creates a new case for selected open members. Detach can remove recovered members from an otherwise-open case. A case supports at most 250 current members, including recovered members; historical intervals are paginated separately.

Measured member recovery and case membership are independent. A recovered parent stays visible while children fail. Case state is derived from retained native episodes; reads do not write it. A case whose members have all ended cannot reopen. Moving its last unresolved member records the closure time and action. A new native failure episode needs a new relation. Removing a member says removed, never recovered.

[Exact batch delivery](EXACT-BATCH-DELIVERY.md) adds opt-in aggregation and reviewed case acknowledgements. This release does not invoke a model or accept SDK correlation hints. Each episode retains all evidence and controls and its original notification identity, payload and budget. Later phases of the [reviewed proposal](RUNTIME-INCIDENT-CORRELATION-PLAN.md) add those capabilities, including an OpenAI Decisions API integration.

## HTTP

The existing isolated deployment boundary applies; authentication remains deferred. Read routes:

- `GET /api/v1/incidents/cases?status=open&page=1` lists cases (25 per page).
- `GET /api/v1/incidents/cases/{id}?page=1&history_page=1` returns separately paginated members and decisions.
- `GET /api/v1/incidents/candidates?page=1` lists open health episodes for manual selection, with current case membership. This is not automated causal ranking. Source, runner, environment and search filters match health investigation.
- Existing health detail and MCP investigation include the canonical episode's current `correlation` link. Contribution lookup follows its condition.

Commands share `POST /api/v1/incidents/correlation/preview` and `/apply`. Preview accepts an exact proposal and returns a signed fifteen-minute review token. Apply accepts only `{"review_token":"..."}` and returns `case_id` and `replayed`. Identical retries reuse the original receipt; reuse of a request identity with a different proposal conflicts. Periodic unchanged failure evidence does not invalidate review, but membership, attention, controls and closure changes require review again.

Example create proposal:

```json
{"action":"create","request_id":"11111111-1111-4111-8111-111111111111","title":"Cluster network outage","reason":"Apps affected by the network failure","episodes":[{"type":"individual","id":"22222222-2222-4222-8222-222222222222"}],"anchor":{"type":"individual","id":"22222222-2222-4222-8222-222222222222"}}
```

`create` needs title/episodes and accepts anchor. `attach` and `detach` need case_id/episodes. `merge` needs case_id/other_case_id, with case_id the survivor. `split` needs case_id/title/episodes and accepts anchor for the new case. `anchor` needs case_id and a member reference, or null to remove the parent hypothesis. Every action needs a request_id and reason; fields for other actions are rejected. See [OpenAPI](../contracts/http/v1/openapi.json) for schemas and [HTTP conventions](HTTP-API.md) for response envelopes and error codes.

## MCP and retention

Read-only tools `list_cases`, `get_case` and `list_correlation_candidates` expose cases, member links and provenance. No MCP mutation authority was added. Follow health incident/result evidence tools for measurements; no private configuration is included.

Retained membership protects both current and historical episodes. Cleanup removes eligible case history before native history, only after all members ended and pending delivery settled under existing retention. Case audit and idempotency receipts have the same retention lifetime; they are not permanent records. Large cascades and queries remain outside a strict runtime bound.

## Implementation notes

Topology writers acquire correlation gate `774021`, then their complete sorted assignment/condition owner set. Native writers do not acquire it. Preview tokens bind exact proposals and relevant episode/control revisions; routine unchanged failure evidence does not invalidate review. Retention takes the gate before native owners. See [locks](TRANSACTIONS-AND-LOCKS.md).

GPT-6 Astra reviewed this implementation during development and again at completion. Review corrections covered closure after moving the last failure, canonical UUIDs, retained references, request shape/size, delivery isolation and concrete form review. Tests use isolated databases and local fixtures; no external notification or deployment is required.
