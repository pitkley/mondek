# External correlation decisions

A configured decisions provider can review a bounded set of upstream candidates for an open health episode. An operator starts the request from incident detail or HTTP and can review a suggested candidate after the provider responds. Applying a review uses the ordinary reviewed case workflow. Delivery keeps its original schedule throughout the request and while a proposal awaits review. [Incident correlation](RUNTIME-INCIDENT-CORRELATION.md)

## Configure a provider

Set `MONDEK_CORRELATION_DECISIONS_CONFIG` to a private JSON file readable by the controller with mode 0400 or 0600. The HTTPS endpoint may implement the JSON contract below directly or map it to another provider. Choose which evidence categories the controller may send.

```json
{
  "id": "operator-decisions",
  "url": "https://decisions.example.net/v1/correlation",
  "evidence": ["dimensions", "timing", "health"],
  "binding_key": "<deployment-specific secret of at least 32 printable ASCII bytes>",
  "timeout_ms": 5000
}
```

An optional `bearer_token` authenticates to the provider. Keep the file and secrets outside source control. Mount the file and pass the environment variable to the controller service when using Compose. The controller rereads configuration before admissions and revalidates it before accepting an unapplied decision. A changed destination, evidence list, or credential invalidates requests bound to the earlier configuration. Rotate the binding key if you restore a disabled configuration and want old requests to stay invalid. An already admitted HTTP request may still reach the previous destination.

The controller sends request-local handles and the explicitly selected categories. An empty evidence list sends the handles and search status alone. Incident and assignment IDs, check and target labels, selectors, raw observations, configuration values, and credentials are excluded from the JSON body. The bearer credential is used only as an HTTPS authorization header.

## JSON adapter contract

The controller sends an HTTPS `POST` with `Content-Type: application/json` and an `Idempotency-Key` equal to the request ID. A request contains `version: 1`, `request_id`, `expires_at` in UTC, `subject`, `search`, and `candidates`. The subject contains `health` only when authorized. Search reports completeness and any truncation or differing hints. Each candidate contains a request-local `handle` and any authorized `dimensions`, `timing`, and `health`. Timing values are `overlap` or `later_opening`.

Return HTTP 200 and JSON with exactly one `Content-Length` header, no transfer encoding or compression, and at most 8192 response bytes. Response headers are limited to 16 KiB. The response includes `version: 1`, the original `request_id`, and `outcome`. Use `suggest` with one supplied candidate handle in `candidate`, or use `standalone` or `abstain` with the candidate field omitted. A response may include a reason of at most 512 bytes and a confidence between zero and one. Confidence is advisory.

```json
{
  "version": 1,
  "request_id": "a5bb1b70-9906-4f3e-bff2-505d4a460d35",
  "outcome": "suggest",
  "candidate": "candidate-handle-from-this-request",
  "reason": "The infrastructure episode is consistent with the observed timing."
}
```

Requests expire five minutes after creation. There can be one pending request per episode and up to 100 per installation. Up to three outbound admissions share the original deadline, request ID, and payload. Configure providers to treat duplicate IDs as retries of the same request. The controller performs outbound I/O outside its database transactions. Invalid, late, or stale replies leave the current incident and notification work available.

## Review and apply

Request a decision from health incident detail, or send `subject` and a client-generated `request_id` to `POST /api/v1/incidents/decisions/request`. Request IDs make exact request resubmissions idempotent. Health detail and MCP `get_incident` expose the paged decision history with `decisions_page`.

For a suggestion, send its `request_id` to `POST /api/v1/incidents/decisions/preview`. Review the proposed case or attachment and submit the review token through `POST /api/v1/incidents/decisions/apply`. Mondek checks relevant episode state, approved disclosure and the specific candidate at review and apply. A provider's recommendation to leave an incident standalone is advisory. Use the separate operator override to block automatic grouping.
