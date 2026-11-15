# Unified HTTP API plan

Status: implemented and qualified on 2026-11-15. This document describes intended work, not current API behavior. Authentication and authorization remain explicitly out of scope.

## Objective and decisions

Build one coherent Mondek HTTP API under `/api/v1`, covering runner communication, read-only integration queries and existing operator workflows. Use ordinary Phoenix controllers and explicit JSON projections with OpenApiSpex declarations, request validation, generated OpenAPI and contract tests. Do not introduce `/api/integrations/v1`, a second REST implementation, or an additional resource framework.

The controller, runners, CLI tools and repository-owned clients can change together. No HTTP compatibility aliases, deprecation period or support for mixed old/new binaries are required. Update all callers in the same implementation series. This permission does not justify discarding databases, queued reports, immutable evidence or journal state: preserve those identities and semantics and qualify coordinated upgrades with existing state.

Alignment means one route vocabulary, explicit schemas, errors, operation documentation and maintenance workflow. Different operations still have different payloads, transaction ownership and resource budgets. A runner control exchange is a command with durable effects and long polling, not a read-only inventory query.

Recommended defaults in this plan require no further product decisions to start implementation. User feedback can change the proposed route names or scope before work begins.

## Current baseline

The router currently groups runner protocol, documented operator APIs and internal inspection endpoints under `/api/v1`, largely through `MondekWeb.APIController`. Some responses directly serialize internal context maps. LiveViews generally use domain contexts directly. The MCP endpoint at `/mcp` has its own explicit read-only projections through `Mondek.AgentInspection`.

Use [API boundaries](API-BOUNDARIES.md), the actual router and caller searches together as the starting inventory. The boundary document has historical entries that no longer appear in the router; neither documentation nor existing route presence alone establishes that a route must survive. [Protocol contracts](../contracts/v1/protocol.md), [transactions](TRANSACTIONS-AND-LOCKS.md), [agent integration](AGENT-INTEGRATION.md) and workflow-specific guides supply the semantics to preserve.

## HTTP layout and route disposition

Keep `/api/v1` as the single JSON API root and use OpenAPI tags for navigation: Runner protocol, Results, Assignments, Incidents, Coverage, Publishers, Runners, Notifications, Configuration and Maintenance. These tags express purpose, not permissions. Keep `/mcp`, HTML/LiveView, static assets and the Git smart-HTTP transport outside this JSON specification. Preserve `/health` as the deployment probe and document it separately; consolidate any JSON API health alias as part of the route inventory.

Create a checked-in route disposition table during implementation, with every existing method/path assigned exactly one action: retain with explicit schema, rename with all callers updated, or remove with identified replacements. Record request/response schemas, behavior owner, actual callers, operation ID, limits and tests. No unclassified `/api/v1` route remains at completion. All retained routes, including existing mutations and the runner protocol, belong in the generated specification.

| Existing area | Target disposition |
| --- | --- |
| `/control`, `/inventory`, `/observations` | Move together to `/runner/control`, `/runner/inventory`, `/runner/observations`; retain distinct protocol semantics. |
| `/checks` and `/checks/:id` | Replace ambiguous result naming with `/results` and `/results/:id`. |
| Scheduled-check inspection at `/configuration`, `/assignments/:id`, `/assignments/:id/inspection` | Consolidate on assignment list/detail and explicit related evidence where needed; separate configuration workflow resources from execution identity. Preserve operator information through intentional DTOs rather than silently dropping required fields. |
| `/incidents`, `/monitoring-incidents` and their details | Consolidate on concrete `/incidents/health` and `/incidents/monitoring-loss` collections/details. Update acknowledgement command paths to the same incident vocabulary. |
| Policy, rules, bulk configuration, maintenance, publisher lifecycle, notification retry and assignment settings | Keep the existing capabilities and reviewed command semantics; group controllers by domain and normalize names where justified by the disposition table. POST preview/apply/cancel operations remain appropriate. |
| Coverage, publisher, runner and notification reads | Retain useful inventories and exact detail operations with explicit bounded schemas; use the common HTTP conventions. |
| Snapshot/overview and overlapping inspection routes | Retain a bounded summary only if it serves a concrete caller or integration need. Replace harness-only snapshot dependencies with focused resource queries or test-local fixtures, then remove redundant routes. Do not add a public endpoint solely to reproduce a test helper. |
| Legacy setup/assignment creation/retirement entries | Verify actual routes/callers; remove unused HTTP remnants. Source inventory and reviewed publisher lifecycle remain authoritative. Internal fixture helpers need not become public APIs. |

Exact path changes beyond the decisions above are implementation details recorded in the disposition table. This is a complete unification project delivered in focused waves, not a permanently parallel new API plus an indefinitely undocumented old one.

## Initial integration surface

The first usable slice supports this workflow: list incidents or results needing attention, inspect an incident, follow exact result identities into evidence, then inspect the scheduled assignment and source provenance.

All paths below are relative to `/api/v1`.

| Method and path | Contract |
| --- | --- |
| `GET /incidents/health` | Individual and shared-condition episodes, rolled up once by default; `status=open|closed|all`, default open. Acknowledged episodes remain included. |
| `GET /incidents/health/:id` | Explicit discriminated individual/shared detail; exact evidence references and paginated contributors for a shared condition. Contributor records retain their own incident and result-stream identities. |
| `GET /incidents/monitoring-loss` | Monitoring-loss episodes, with the same lifecycle filter and default. |
| `GET /incidents/monitoring-loss/:id` | Episode and affected membership; distinguish live members from a retained historical snapshot. |
| `GET /results` | All active result streams by default; `attention=true` selects failures and knowledge gaps, including pre-incident problems. Provide explicit `membership=active|retired|all` for historical inventory. |
| `GET /results/:id` | Identity, target/environment/source and current state, separating retained measurement from latest execution. Historical retired stream IDs remain resolvable while retained. |
| `GET /results/:id/evidence` | Paginated reports projected to this exact result incarnation, never sibling output payloads. |
| `GET /results/:id/evidence/:observation_id` | One exact projected observation; no paging parameters. Return 404 when unavailable, pruned or outside this incarnation without claiming which explanation applies. |
| `GET /assignments` | Scheduled-check inventory, distinct from result streams; replaces the inspection use of `/configuration`. |
| `GET /assignments/:id` | Schedule, source identity, adoption generations and paginated result references. Ordinary integration projection excludes parameter values and private deployment settings. |
| `GET /assignments/:id/configuration` | Editable settings, complete parameter schema/values, ownership and reviewed revision needed by existing operator saves; a separate explicit configuration DTO rather than leaking editable state into ordinary investigation responses. |

Use `source_id`, `runner_id`, `environment`, bounded `search` and `page` filters where they have meaningful domain semantics. Incident acknowledgement filtering is `acknowledgement=all|acknowledged|unacknowledged`, default all. Declare supported filters per operation; do not accept a common bag of ignored parameters. Health list filters apply to rolled-up episode selection; explicitly document contributor matching versus episode scope so filtering cannot imply that a shared incident only affects the selected runner/source.

Coverage, runners and notifications already have useful reads; align them in the subsequent inventory wave rather than inventing additional integration-specific variants. No new mutation capability is required by this plan. Existing mutation workflows continue to be callable and receive the same documentation and contract discipline.

## Phoenix organization and shared logic

Use `MondekWeb.API.V1` controllers grouped by domain, matching `*JSON` rendering modules, reusable schema modules and one `ApiSpec`. Controllers own transport validation, status selection and response rendering. Domain contexts retain validation of business rules, locks, transactions, reviewed revisions and durable effects. A small fallback/error renderer normalizes HTTP errors; no generic workflow or service framework is needed.

Extract neutral investigation functions from `AgentInspection` and existing inspection contexts where semantics overlap. HTTP and MCP adapters own their envelopes, wording, defaults, schemas and error mapping. Neither calls the other transport, dispatches using the other's operation names, or requires the other's schema version. Shared functions preserve selected-output projection, incarnation boundaries, source provenance and consistent clocks. Avoid carrying UI-only facets, coverage scans or unrelated counts into a focused detail query.

MCP remains a separate protocol and tool catalog at `/mcp`. Keep its read-only scope and safe projection boundary. Any MCP contract adjustment needed by extraction is deliberate and tested; HTTP cleanup alone is not a reason to expand tool authority or expose more data. LiveViews continue calling contexts directly rather than making HTTP requests to their own controller.

## Schemas and generated OpenAPI

OpenApiSpex operation declarations next to controller actions and named schema modules are the maintained HTTP contract source. Router discovery and schema resolution generate the document; do not maintain handwritten YAML or infer public fields from Ecto schemas. Select a compatible locked OpenApiSpex release and its supported OpenAPI dialect, update third-party credits and use idiomatic Phoenix 1.8 JSON rendering.

Declare required, optional and nullable properties explicitly. Health incidents use a required discriminator such as `incident_type=individual|condition`, rendered in every corresponding list/detail/contributor variant. Preserve wire health values such as `OK`, `WARN`, `CRIT`, `UNKNOWN`; knowledge/freshness is a separate field. Assignment IDs are opaque strings, not assumed UUIDs, regardless of what fresh inventory currently generates.

That opaque assignment-ID rule applies to historical resource lookup. Use a distinct UUID-constrained schema for runner report assignment IDs and prepared/active map keys where the current protocol requires it. Do not widen the runner admission contract merely to reuse a read schema.

Document the current experimental same-release compatibility policy for all maintained callers. Newly written integration clients should tolerate unknown response object properties; required property removal, type/nullability changes and expansion of a closed enum require explicit review and coordinated caller updates. Do not assert that every additive change is compatible with generated clients. The current cleanup needs no compatibility aliases; a future stable release will need its own published support/deprecation policy rather than retroactively treating the `v1` label as such a promise.

OpenAPI does not capture every constraint. Byte budgets, exact decimal handling, canonical identity, replay rules, ownership, token scope, cross-field constraints and concurrency rules remain explicit semantic contracts enforced by domain validation and behavioral tests. Check existing runner extension-field behavior before applying closed schemas; unknown-field handling is intentional per schema, not a global prohibition.

Use request casting/validation for the new read surface immediately. Introduce it into existing command and runner endpoints only after proving it does not mutate semantically significant request values or replace exact-number validation with floating-point coercion. Preserve original decoded report maps for admission and storage; schema defaults, struct casting or removal of unknown properties must never rewrite evidence identity. Domain validation remains authoritative for semantic rules.

Preserving original decoded maps preserves the existing Jason/JSONB numeric behavior; it does not recover arbitrary precision from fractional/exponent tokens already decoded as binary floats. Characterize actual raw JSON request, storage and replay cases before enabling validation, including exact integers, exponent spellings, adjacent large integers and fractional values. Do not incidentally promise a lossless-decimal wire parser. HTTP regression and generated read-client tests must exercise large parameter/evidence numbers, including `1e24` normalized by storage into a large integer, its adjacent integer differing by one, and the maximum supported 4096-digit integer rather than only IDs and strings. If the selected client tooling cannot preserve documented numeric meaning, choose an explicit numeric representation/schema or narrow the supported tooling claim before declaring that check passed; any report-format change remains a separately reviewed decision.

For observation ingestion, boundary validation checks the envelope, identity fields, report count, object-shaped report entries and body budget. Individual report validation stays inside admission so a malformed report can receive its own rejected disposition alongside valid reports. The OpenAPI request schema must describe that accepted envelope with unconstrained report objects, and separately document canonical valid-report/result schemas for producers. Do not attach a strict nested report schema as a request-wide gate or assert that report-invalid envelopes cannot receive HTTP success. Test mixed valid/invalid reports through the actual schema-validation plug and HTTP endpoint.

Serve `GET /api/v1/openapi.json`, with one generated document covering all retained JSON operations and a documentation viewer at `/api/docs`. Use a relative server URL. Keep a deterministic generated copy at `contracts/http/v1/openapi.json`, stripped of framework-internal vendor extensions where appropriate. Export/check it with application startup disabled so no database or service is needed. Choose stable explicit operation IDs independent of module names.

Add short `mondek` commands for spec generation/checking and include freshness, exact route coverage, unique operation IDs and reference resolution in `mondek check`. Validate real serialized success and error responses against schemas in tests. Freshness proves synchronization, not semantic compatibility; review generated diffs and test intended behavior. Validate one generated client against the read API as a tooling smoke test without committing to maintaining a full SDK or introducing client generation into the Python runner.

## HTTP conventions

### Representation and errors

Resource reads use `{data, meta}`. `data` is an object or array; `meta` includes `as_of` and collection pagination where applicable. Nested collections have independent metadata. `as_of` is the operation's evaluation time for freshness and derived state; it is not a durable cursor or proof that all visible commits predate that timestamp. Use UTC RFC 3339 timestamps with explicit precision and nullability documented in schemas.

Commands may keep purpose-specific receipts, especially the runner protocol's `version`, authoritative assignment membership and per-report dispositions. Do not wrap all commands merely to make their top-level JSON resemble a list response. Standardize shared primitives and error transport without hiding essential operation-specific outcomes.

Errors use `{error: {code, message, details?}, request_id}` with bounded safe messages and field errors. Codes are stable machine-readable values; omit raw private responses, credentials and submitted parameter values. Use 400 for malformed syntax/unsupported query parameters, 415 for unsupported write content type, 422 for validly encoded invalid values, 404 for unavailable selected resources, 409 for reviewed-state/session/replay conflicts, 413 for request size, and 503 for temporary inability to serve. Specify any additional statuses intentionally. Normalize parser, validation and API fallback failures into the same format where a response can be produced.

Per-report rejections/conflicts remain dispositions in a successful batch receipt when the envelope is accepted; do not convert them into whole-request failures. A rejected report can contain an ID of any JSON type. Normalize an invalid report ID to null in the HTTP disposition and preserve request order for batch correlation; valid UUID IDs retain their identity. Test malformed string, numeric, object and absent IDs through the actual pipeline, and declare UUID-or-null only after applying that normalization. Existing review-token and configuration conflict reasons remain meaningful codes. A long-poll timeout with no change is a successful control response, not an unavailable error.

### Pagination and bounds

Use page-based live pagination initially, with fixed sizes: 20 results/assignments/health episodes/contributors, 10 evidence reports and 25 live monitoring-loss members/episodes. Other retained inventories explicitly declare their bounded size. Pages are positive bounded integers; a page beyond the end returns an empty page and does not clamp to the last page. Every ordering is documented and has an immutable ID tie-breaker. Expose next-page navigation; clients must treat pages as independent live reads that may skip or repeat items while state changes.

Closed monitoring-loss membership is a retained snapshot of at most 100 members. Represent its mode, retained count, original affected count and truncation explicitly. It has no promise of further recoverable pages. If the HTTP representation slices that retained snapshot, terminal metadata must still disclose permanent truncation. Do not label retained count as complete affected membership.

Enforce operation-specific request, response, query-time and collection bounds. Preserve the existing 256 KiB ordinary request, 4 MiB inventory/control-response and 2 MiB maintenance request exceptions unless a focused change justifies another budget. Set a documented read-response cap, initially 1 MiB as for MCP, with a bounded stable `response_too_large` error and guidance to narrow evidence queries. Test worst-case exact observations and closed snapshots against that cap; do not silently truncate evidence to fit it. A response cap and page size do not establish bounded SQL cost: avoid unnecessary counts/facets and qualify representative query plans.

Every retained valid exact observation and closed snapshot needs a usable retrieval path within the documented budgets. If worst-case validation shows that a fixed page or singleton cannot fit, adjust that operation's limit or provide bounded explicit subresources before completion; a permanent oversized-response error is not an acceptable substitute for access to retained evidence.

Moving runner and command routes requires updating `BodyReader`, the runner's response-size selection, proxy/gateway route lists, doctor probes, fixtures and documentation together. Do not accidentally apply ordinary response limits to a valid 4 MiB control exchange.

## Data correctness and transport cutover

Short compound reads own one repeatable-read, read-only transaction and one evaluation clock. A shared transaction wrapper must run before any query and must not reset isolation in a nested transaction. Pure process probes need no database transaction. Command contexts keep their established transactional boundaries; never surround control long polling, preparation, Git processes or external I/O with a request-long database transaction.

Retained health is display state and cannot authorize skipped executions or claim a new measurement. Keep source/evaluation/receipt times, original observation/session/generation identities, `result_present`, missing evidence and configuration-retention metadata. Acknowledgement, maintenance, collection knowledge and measured health remain independent. Shared incidents retain exact contributor identity and historical observation references rather than reconstructing evidence through current assignment outputs.

Retain the current runner envelope/report format and `version: 1` for this transport/layout refactor unless an explicit semantic change requires otherwise. HTTP root version and stored report version serve different purposes. Do not add a new redundant schema version to each resource read. Do not rewrite buffered reports, persisted configurations or observation payloads to conform to new response DTOs. If implementation reveals a required stored-format change, document and test that migration separately before proceeding.

Qualify the coordinated cutover by stopping the old runner, upgrading controller and runner together, then reconnecting the same journal and installation to the preserved database. Buffered replay retains report identity, original age, duplicate semantics and historical admission. No old binary support or route aliases are needed. Document the requirement to upgrade both components; never require an empty installation as the migration strategy.

Authentication/authorization, CORS expansion, new external deployments, new notification sends, a durable change feed and automatic generated SDK distribution are outside this work. Existing browser protections remain. Polling incident views cannot guarantee seeing every transition; cursor pagination alone would not provide that guarantee either.

## Delivery sequence

1. **Inventory and foundation:** record every current route/caller/disposition, intended DTOs and exact status/size policies. Add OpenApiSpex and deterministic spec tooling, licensing updates and new grouped controllers. Establish the route/spec coverage check for migrated operations and make the remaining migration list explicit; the final check covers the complete root.
2. **Read investigation slice:** implement the proposed result, assignment and incident reads with explicit projections and contract tests. Extract shared neutral investigation logic and verify MCP behavior. Update incident/check/configuration harness callers and remove their superseded routes.
3. **Runner alignment:** move the three runner operations, document complete requests/receipts/errors in OpenAPI, preserve original report maps and exact numeric behavior, update all size/path-dependent code and clients. Qualify replay, partial batches, fencing, restart and real control long polling without open transactions.
4. **Remaining operator surface:** align existing coverage/publisher/runner/notification reads and configuration/maintenance/lifecycle commands. Give every retained operation explicit schemas and update CLI, harnesses, docs and fixtures. Preserve reviewed tokens, revisions, source/operator ownership, concurrency and durable notification behavior. Remove redundant routes and obsolete direct-map serialization.
5. **Completion and cutover qualification:** finish whole-root route/spec coverage, documentation viewer and generated-client smoke test. Update API boundaries, protocol docs, operational/deployment guides and upgrade instructions to describe only the final paths and contracts. Verify no stale caller references remain except intentional historical documentation. Record validation and remaining limits in the implementation summary.

Use focused commits for review, but treat the completed series as one coordinated controller/runner change. Do not publish or deploy an intermediate incompatible revision. The final result includes all five waves; the investigation slice is an early milestone, not the definition of done.

## Verification and acceptance

Implementation was explicitly authorized in the accompanying chat. During implementation use the committed devenv environment, inspect `devenv version`/`devenv info`, and run focused native suites against isolated test PostgreSQL. Select service/browser qualification from [acceptance coverage](ACCEPTANCE-COVERAGE.md), based on changed behaviors, rather than duplicating full CI runs.

- Validate every serialized DTO variant and error status, required/null/omitted fields, malformed IDs/queries, unknown fields, invalid enum values, empty and oversized pages, byte limits, exact decimal values and unsupported content types.
- Test individual/shared incidents, acknowledgements at expiry boundaries, fresh versus retained/failed collection, result retirement/reincarnation, historical contributor navigation, exact/out-of-incarnation/pruned evidence, closed truncated loss snapshots and consistent reads with controlled clocks/concurrent writes.
- Run real runner HTTP/database tests for registration, authoritative membership, configuration adoption, partial collection, mixed report dispositions, exact replay after a lost reply, changed-payload conflict, session fencing, outage/restart and the same persisted journal across the coordinated upgrade. Include maximum inventory/control response handling and long-poll wake/timeout behavior.
- Exercise changed operator commands with real database constraints and concurrent revision/review conflicts. Keep configuration/maintenance/publisher ownership, token expiry, retry identity and transaction/I/O boundaries intact. Use test-local notification recipients only.
- Run MCP HTTP/stdio regression tests after shared extraction, and focused browser journeys for changed operator workflows even though LiveViews call contexts directly. No UI redesign or new UI surface is required.
- Run static/format/package checks and license generation/checking after dependency changes, spec generation/freshness/reference checks, exact whole-root route coverage and one generated read-client smoke test. Choose packaged suites that exercise each changed route family; record coverage rather than implying a small smoke run validates every command.

Completion means one documented `/api/v1` surface with no accidental unclassified routes, all maintained callers on the final paths, a generated and enforced specification, explicit safe projections, preserved durable evidence and reviewed command semantics, and recorded passing checks. Future additions follow the same operation/schema/behavior-test workflow.

## Review record

The initial design and this unified Markdown plan were reviewed by GPT-6 Astra. The second review judged the unified architecture sound and identified no required user product decision. Its findings are incorporated: envelope-only observation validation with per-report admission, an explicit editable-configuration read, operation-specific assignment ID schemas, raw-body and generated-client numeric verification, normalized invalid report IDs, and a usable retrieval requirement for worst-case evidence sizes. The earlier findings on exact evidence lookup, historical stream incarnation, list scope, closed loss snapshots, pagination consistency and specification enforcement are also incorporated. This review is design evidence, not implementation qualification.

## Tooling references

- [Phoenix JSON APIs](https://hexdocs.pm/phoenix/json_and_apis.html)
- [OpenApiSpex controller operation declarations](https://open-api-spex.hexdocs.pm/OpenApiSpex.ControllerSpecs.html)
- [OpenApiSpex request validation](https://open-api-spex.hexdocs.pm/OpenApiSpex.Plug.CastAndValidate.html)
- [OpenApiSpex response assertions](https://open-api-spex.hexdocs.pm/OpenApiSpex.TestAssertions.html)
- [OpenApiSpex spec generation and checking](https://open-api-spex.hexdocs.pm/Mix.Tasks.Openapi.Spec.Json.html)

## Implementation decisions

The implemented resource list convention uses a default page size of 20 with a bounded optional `page_size` up to 100 for results and assignments, retaining useful operator pagination instead of accepting an ignored parameter. Nested evidence/contributor and monitoring-loss sizes remain operation-specific. The bounded diagnostic snapshot and selected result inspection remain intentional operations because maintained operator qualification uses their coherent related history; their schemas and limits are explicit. Ordinary investigation projections exclude parameter values and report extensions; editable configuration and the diagnostic snapshot have their documented wider scope. See [HTTP usage](HTTP-API.md) and the generated [route inventory](API-ROUTES.md) for the final contract.

Numeric qualification found that Jason's default 1024-digit decoder limit was below the existing documented 4096-digit protocol/domain limit. Its bounded limit now accommodates 4096 digits plus a negative sign; domain validation still enforces the original numeric bounds. Configuration repository initialization moved to the application lifecycle before HTTP, so revision GET is a read. These decisions change no stored report or configuration format.

The final full-scope review identified that existing bulk workflows require a paginated editable configuration inventory, not only a safe assignment summary. `GET /configuration/assignments` provides that explicit operator representation alongside `/assignments` and `/assignments/:id/configuration`. It preserves an existing read capability without adding mutation authority or making parameter values part of ordinary investigation responses.

## Implementation qualification

GPT-6 Astra reviewed the implementation at two intermediate checkpoints and then performed a fresh full-scope review. The full review found missed dynamic callers, dropped retry/configuration fields and ignored filters; those findings were corrected, and Astra's final re-review reported no remaining material defects. The API now has 64 declared operations; the checked-in specification and route inventory are current.

Validation performed on the completed implementation:

- `mondek check` passed, including OpenAPI freshness/route/ID/reference checks, native formatting, workflow/license checks and installed SDK typing.
- Runner suite: 330 tests passed; harness suite: 78 tests passed.
- Full controller suite: 959 of 960 tests passed on the final full run. The remaining failure was the test adapter dropping already-correct `error.details.stale_ids`; that adapter was corrected, and all 26 focused bulk/API/runner-page tests passed afterward. The earlier operator/MCP and real HTTP runner regression suites also passed. There is no remaining known failing product assertion.
- The generated read-client check passed against real HTTP with JSONB-normalized exponent values, adjacent large integers and a 4096-digit integer.
- The isolated packaged acceptance suite passed every scenario, including independent collection, configuration adoption/fencing, lost-reply replay, partial collection, original-age reconnect, worker/controller restart, real local notification retries, acknowledgements/maintenance and payload bounds.
- The packaged browser lifecycle suite passed all three journeys, including desktop/narrow layouts and accessibility checks. Test projects cleaned up their own containers and volumes.

Qualification used synthetic/local fixtures only. Authentication/authorization, external deployments, public artifact publication, arbitrary mixed-release operation and lossless event synchronization remain outside this implementation. Service/browser suites for every other operator workflow were not exhaustively rerun; their native/API and caller checks remain in place. No database migration or persisted report/configuration format change was introduced.
