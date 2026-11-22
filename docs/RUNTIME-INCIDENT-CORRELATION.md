# Runtime incident correlation

Correlation cases record suspected relationships between health incident episodes. They are separate from a declared `Condition`, which still means equivalent evidence. A case can contain individual or condition episodes, with one optional suspected parent. Cases are flat; each episode has at most one current case.

## Manual grouping

Open **Incidents → Correlation cases and manual grouping**. Create a case by choosing exact open episodes, a title and a reason. An existing case supports attach, detach, merge, split and changing its suspected parent. Review precedes save. Audit records identify Local operator, the reason, time and exact proposal. Labels and notes are untrusted text, never identifiers or authority.

All selected episodes must have the same exact monitored environment. A missing environment is an exact value. Select the shared condition, rather than one of its equivalent contributions. Attach accepts ungrouped open episodes; moving between cases requires split/detach or merge. Merge moves the complete source case. Split creates a new case for selected open members. Detach can remove recovered members from an otherwise-open case. A case supports at most 250 current members, including recovered members; historical intervals are paginated separately.

Measured member recovery and case membership are independent. A recovered parent stays visible while children fail. Case state is derived from retained native episodes; reads do not write it. A case whose members have all ended cannot reopen. Moving its last unresolved member records the closure time and action. A new native failure episode needs a new relation. Removing a member says removed, never recovered.

[Exact batch delivery](EXACT-BATCH-DELIVERY.md) adds opt-in aggregation and reviewed case acknowledgements. Each episode retains all evidence and controls and its original notification identity, payload and budget. The [correlation design](INCIDENT-CORRELATION-DECISIONS-DESIGN.md) covers deterministic rules and external decisions.

## Inspect hinted candidates

Open an active health incident with [declared dependency hints](../runner/README.md) to see candidate episodes, their matching dimensions and the exact selectors that matched. Inspection reads hints from the configuration generation that supplied each active contributor’s opening measurement. Later inventory edits leave that opening provenance intact. Select a candidate to inspect its independent evidence. Candidates are hypotheses, and inspection leaves case membership and delivery unchanged.

Condition selectors match an exact namespace and key. Target selectors match an exact source, target kind and key. Both use the subject’s exact monitored environment, including an absent environment. Only open dependencies qualify. Compare controller opening times using the contributor that declared the hint. For a target within a shared Condition, use the matching target contributor’s opening time. An older open dependency remains eligible, and a dependency that opens later can appear on a subsequent read if it opens within the declared window. A matching shared Condition appears once even when several of its results match. Rank by the closest qualifying opening times, then by episode type and ID.

The health detail’s `correlation_candidates` projection includes the canonical subject, status, hint count, conflict and truncation flags, and up to 20 candidates. Inspection considers up to 16 active contributors and 32 distinct hints. Each candidate lists up to four matches with their timing and up to four opening contributors per match. `complete` with no candidates means no matches in the inspected scope. `incomplete` means some opening evidence was missing or a limit was reached. `unavailable` covers closed subjects and missing opening metadata. Different declaration sets from active shared-Condition contributors are flagged for review.

## Record a secondary relationship

In incident detail, choose a candidate and dimension, enter a reason, and review the link before saving. The link points from the incident that declared a dependency to the candidate episode. Each incident can keep multiple dimensions. The review records the selected match and its opening-generation provenance. A link ends when either endpoint closes or an operator removes it after review. The original endpoint identities and reason remain visible under normal history retention.

Secondary links help operators investigate a possible dependency. Existing primary case membership, acknowledgements, batch eligibility, and delivery records remain unchanged.

For HTTP, `POST /api/v1/incidents/relationships/preview` takes an action, request ID, canonical subject reference, and reason. For `add`, provide the target reference and dimension. For `remove`, provide the relationship ID and either endpoint as the subject. Apply with the `review_token` at `POST /api/v1/incidents/relationships/apply`. Health incident detail and MCP `get_incident` include `correlation_relationships`, with an independent `relationships_page` parameter.

## HTTP

The existing isolated deployment boundary applies; authentication remains deferred. Read routes:

- `GET /api/v1/incidents/cases?status=open&page=1` lists cases (25 per page).
- `GET /api/v1/incidents/cases/{id}?page=1&history_page=1` returns separately paginated members and decisions.
- `GET /api/v1/incidents/candidates?page=1` lists open health episodes for manual selection, with current case membership. This is not automated causal ranking. Source, runner, environment and search filters match health investigation.
- Existing health detail includes the canonical episode's current `correlation` link and the separate `correlation_candidates` projection. Candidate inspection of a contribution uses its condition.

Commands share `POST /api/v1/incidents/correlation/preview` and `/apply`. Preview accepts an exact proposal and returns a signed fifteen-minute review token. Apply accepts only `{"review_token":"..."}` and returns `case_id` and `replayed`. Identical retries reuse the original receipt; reuse of a request identity with a different proposal conflicts. Periodic unchanged failure evidence does not invalidate review, but membership, attention, controls and closure changes require review again.

Example create proposal:

```json
{"action":"create","request_id":"11111111-1111-4111-8111-111111111111","title":"Cluster network outage","reason":"Apps affected by the network failure","episodes":[{"type":"individual","id":"22222222-2222-4222-8222-222222222222"}],"anchor":{"type":"individual","id":"22222222-2222-4222-8222-222222222222"}}
```

`create` needs title/episodes and accepts anchor. `attach` and `detach` need case_id/episodes. `merge` needs case_id/other_case_id, with case_id the survivor. `split` needs case_id/title/episodes and accepts anchor for the new case. `anchor` needs case_id and a member reference, or null to remove the parent hypothesis. Every action needs a request_id and reason; fields for other actions are rejected. See [OpenAPI](../contracts/http/v1/openapi.json) for schemas and [HTTP conventions](HTTP-API.md) for response envelopes and error codes.

## MCP and retention

Read-only tools `list_cases`, `get_case` and `list_correlation_candidates` expose cases, member links and the manual candidate picker. `get_incident` with `kind: "health"` returns the same `correlation_candidates` projection as HTTP health detail. Follow health incident/result evidence tools for measurements; no private configuration is included.

Retained membership protects both current and historical episodes. Cleanup removes eligible case history before native history, only after all members ended and pending delivery settled under existing retention. Case audit and idempotency receipts have the same retention lifetime; they are not permanent records. Large cascades and queries remain outside a strict runtime bound.

## Implementation notes

Topology writers acquire correlation gate `774021`, then their complete sorted assignment/condition owner set. Native writers do not acquire it. Preview tokens bind exact proposals and relevant episode/control revisions; routine unchanged failure evidence does not invalidate review. Retention takes the gate before native owners. See [locks](TRANSACTIONS-AND-LOCKS.md).

GPT-6 Astra reviewed this implementation during development and again at completion. Review corrections covered closure after moving the last failure, canonical UUIDs, retained references, request shape/size, delivery isolation and concrete form review. Tests use isolated databases and local fixtures; no external notification or deployment is required.
