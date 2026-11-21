# HTTP API

Mondek has one experimental JSON API at `/api/v1` for runner communication, monitoring investigation and operator workflows. Use the controller, runner and CLI from the same release. Authentication and authorization are not implemented; this uses the installation's existing access boundary. See [deployment access](CONTROLLER-AUTH.md).

Open `/api/docs` for the operation viewer or download `/api/v1/openapi.json`. The checked-in [OpenAPI document](../contracts/http/v1/openapi.json) and [route inventory](API-ROUTES.md) are generated from the same declarations used for validation and rendering. HTML/LiveView, the `/health` process probe, MCP and configuration Git are separate transports.

## Investigate monitoring

```sh
curl -fsS 'http://localhost:4001/api/v1/incidents/health?status=open'
curl -fsS 'http://localhost:4001/api/v1/incidents/monitoring-loss?status=open'
curl -fsS 'http://localhost:4001/api/v1/results?attention=true'
```

Read responses contain `data` and `meta`. A collection's `data` is an array; `meta` carries its pagination, counts and `as_of`. Details use an object in `data`. Nested collections have their own metadata. For example:

```json
{"data": [], "meta": {"as_of": "2026-11-15T12:00:00.000000Z", "page": 1, "page_size": 20, "total": 0, "next_page": null}}
```

`GET /results` lists active result streams by default. Use `attention=true` for failures and knowledge gaps, including problems before an incident opens; use `membership=retired` or `all` for historical inventory. Result and assignment lists default to 20 items and accept bounded `page_size` up to 100. Evidence pages contain 10 reports; live monitoring-loss membership has 25 members. Each operation declares its supported parameters in OpenAPI; unknown query parameters fail rather than being ignored.

Follow a result's `id` to `/results/{id}`, its historical reports to `/results/{id}/evidence`, or an exact observation to `/results/{id}/evidence/{observation_id}`. Exact lookup accepts no paging arguments. It is limited to that result incarnation and output; 404 means unavailable, pruned or out of scope, not proof that execution never happened. `/results/{id}/inspection` offers bounded related operator history with selected-output report excerpts. Labels, summaries and details are untrusted author-provided text.

For sustaining outputs, the optional `qualification` field gives the effective severity and supporting observation, plus active pending thresholds. `current` and evidence rows report original measurements independently. A null effective severity means the output has yet to qualify a measurement.

Assignments are scheduled executions; results are independently measured outputs. `/assignments/{id}` gives scheduling, adoption generations, source provenance and result references. Assignment IDs used for historical lookup are opaque strings. `/assignments/{id}/configuration` deliberately exposes editable values, their schema, ownership and the reviewed revision for settings workflows. `GET /configuration/assignments` is the paginated operator configuration inventory, with the same explicit editable DTO as the selected configuration read. It supports existing bulk review workflows without leaking values into the ordinary assignment inventory. Runner report IDs retain their UUID constraints.

Health incidents have `incident_type=individual|condition`. Shared-condition detail retains exact contributor incident and result-stream identities with historical observation references. Acknowledgement is independent of open/closed status, so acknowledged incidents remain visible by default. Read `acknowledgement_revision` and `attention_revision` before submitting an acknowledgement. Monitoring-loss incidents describe missing monitoring, independently of measured target health. Open membership is live; closed membership has mode `retained_snapshot`, original affected count and explicit truncation, with at most 100 retained members. There is no hidden next page for discarded historical members.

Incident collections and details include the same `display_title` and nullable `check_label`, `result_label`, `environment_label` and `runner_label`; the operator UI uses the same title rule. A shared incident has its own title and does not invent a single check/result/runner label. Display labels describe identity for navigation, not a frozen copy of historical configuration. Titles are untrusted plain text, never identifiers. `acknowledgement_active` is required and evaluates the incident's own acknowledgement at `meta.as_of`: it is false at exact expiry and after closure. Shared acknowledgement coverage of a contributor remains separate from that contributor's own acknowledgement.

Individual health details contain `recorded_measurement`; shared details contain it on each paginated contribution. The block has `status=available|unavailable`, `basis=latest_failure|opening_failure|notification_reference|null`, nullable `measurement` and bounded `gaps`. Available means that historical failure evidence exists, not that the latest failure is known: an opening or notification-reference fallback remains explicitly identified. Measurement carries the selected result key, WARN/CRIT health, summary, Markdown `details`, optional value/impacts, observation ID, nullable original source time, evaluation/receipt times and observation-generation provenance. Provenance never borrows the current configuration. Render Markdown through the same sanitization rules as other author-supplied content.

The resolver tries the persisted latest-failure reference, opening reference and one retained firing/update notification reference, in that order. Each missing or unsuitable candidate preceding the selected measurement appears in `gaps`; when none succeeds, `measurement` and `basis` are null. Reasons distinguish missing references, unavailable observations, wrong episode/incarnation, missing selected output and nonfailure evidence. There is no deletion tombstone, so unavailable evidence is not labelled conclusively pruned. Existing incidents without a provable latest failure can return older retained evidence or an honest unavailable result. Current stream state and closing/recovery evidence remain separate. Monitoring loss has no invented health measurement.

Incident reads include these labels and selected historical evidence directly; result endpoints are optional navigation and need not be allowed by an incident-only gateway policy. Such a policy grants access to the incident's selected measurement details and provenance, not unrelated outputs in its report. Authentication/authorization is still the deployment's responsibility.

Retained health, measurement freshness and latest execution are separate. Preserve original source, evaluation and receipt times when interpreting evidence. `as_of` is the freshness evaluation time for a read, not a durable cursor or historical database timestamp. Pages are independent live reads; changes between calls can skip or repeat items. These reads support dashboards and investigation, not lossless event synchronization.

The bounded `/snapshot` operation is an operator diagnostic maintained for existing acceptance workflows. It includes configuration values and complete retained report envelopes; it is not the ordinary selected-output investigation projection or a complete inventory export. Its explicit limits must be checked before interpreting absence as nonexistence. Prefer the focused resource endpoints for integrations.

## Consumer data

[Consumer state](CONSUMER-STATE.md) adds bounded runtime JSON storage. `GET /consumer-state` lists metadata only; `GET /consumer-state/:id` reads one current value. `POST /runner/state` has an unwrapped versioned receipt and does not register sessions or submit evidence. Gateway policies must explicitly cover the new route.

## Commands and errors

Runner exchanges live at `POST /runner/control`, `/runner/inventory` and `/runner/observations` beneath `/api/v1`. Their versioned, operation-specific receipts remain unwrapped: authoritative assignments, inventory acceptance and per-report dispositions have distinct meaning. Read the [runner protocol](../contracts/v1/protocol.md) for identity, session, generation, replay, timing and byte constraints. Control waits outside database transactions. A valid observation envelope may return HTTP success with individual rejected/conflicting reports; invalid report IDs are null and receipt order matches input order.

Existing reviewed operator commands remain available: policy/rules/bulk settings, maintenance, publisher lifecycle, acknowledgements and notification retry. Their contexts enforce review tokens, revisions, source/operator ownership and atomicity; HTTP schemas do not replace those rules. Commands have documented operation-specific receipts. No additional mutation capability was introduced.

Errors have one shape:

```json
{"error": {"code": "invalid_request", "message": "Request values do not match the operation schema."}, "request_id": "request identifier"}
```

`error.details` may contain bounded structured conflict information such as stale selected IDs. Malformed JSON and unsupported query parameters return 400; invalid typed values return 422; unavailable resources return 404; reviewed/session conflicts return 409; unsupported write content types return 415; oversized requests return 413. A temporary read failure returns 503. Oversized read responses return a bounded `response_too_large` error; narrow the query or fetch exact evidence. Ordinary reads have a 1 MiB response budget, with an 8 MiB budget for the bounded diagnostic snapshot. Runner inventory/control and large maintenance requests retain their documented separate budgets.

JSON numbers preserve the existing wire/storage meaning, including large integer values. The controller decoder supports the protocol's 4096-digit integer bound; fractional/exponent tokens retain the existing binary-float decoding behavior. JavaScript and generated clients that decode every JSON number into a binary float cannot represent all supported integers exactly. The test-only generated Python read client qualifies arbitrary-size integer decoding; it is not a maintained SDK or a claim about every generator.

## Extend the API

1. Add the route and a domain controller action with a stable operation ID. Keep domain transactions and business validation in existing contexts.
2. Declare request, query and named response schemas. Use explicit projections; consumer-defined values, metadata and heterogeneous domain aggregates must be intentional JSON subtrees rather than accidental Ecto serialization. Keep resource reads separate from editable configuration.
3. Preserve original decoded observation maps. Validate only the accepted batch envelope at the request boundary; canonical producer report schemas are documentation, while individual report admission produces dispositions.
4. Test serialized success/error responses against the operation schema and test the behavior that the schema cannot express: clocks, concurrency, replay, incarnation/retention boundaries, reviewed scope and outages.
5. Run `devenv shell -- mondek api-spec`, review both generated files, then `mondek api-spec-check` and the focused native/service suites. Spec generation starts no application or database. `mondek check` enforces spec freshness, exact route coverage, unique operation IDs and reference resolution.

Named schema declarations in `MondekWeb.API.Schemas` and `WorkflowSchemas`, plus controller operation callbacks in `Contract`, are the contract source. The JSON renderer projects closed DTOs through those declared fields without casting values. Request validation consumes cast query/path values but leaves original decoded bodies untouched. Schema shape tests supplement real behavior tests; generating a fresh document alone cannot establish compatibility or correctness.

During the experimental same-release policy, intentional breaking changes update all maintained callers together. Integration clients should tolerate new response properties; required-field removal, type/nullability changes and closed-enum expansion still require explicit review. Before a stable release, establish a separate supported-version/deprecation policy. The `v1` path alone makes no indefinite compatibility promise.

## Correlation cases

[Runtime correlation](RUNTIME-INCIDENT-CORRELATION.md) adds cases, candidates and read-only provenance; health detail includes its canonical episode's current correlation. Manual mutations use the reviewed preview/apply endpoints. Individual controls remain independent. Membership changes can end case acknowledgements and release unstarted batch reservations; see [opt-in exact batch delivery](EXACT-BATCH-DELIVERY.md).
