# SDK and HTTP boundaries

This caller inventory describes the current implementation; it is not a new versioning guarantee. It accounts for the current router, explicit Python exports, shipped commands, examples and maintained acceptance clients. No endpoint or export is removed or renamed by this inventory. Auth remains deferred; classification is about compatibility, not authorization.

## Classification and ownership

The supported read-only `/mcp` integration has its own explicit [agent investigation contract](AGENT-INTEGRATION.md). It uses internal inspection contexts without promoting their full maps or existing HTTP endpoints to public DTOs. `mondek-mcp` is a thin local stdio adapter for this same endpoint. Neither transport adds authentication or mutation authority.

- **Supported:** an intentional consumer boundary used by the shipped runner, operator CLI, documented integration or check-authoring interface. Preserve its documented behavior and actual callers when changing it. This is an experimental release; neither its version nor `/api/v1` establishes an indefinite frozen schema or arbitrary old/new release interoperability.
- **Internal:** an application inspection/projection or implementation boundary with repository-owned callers. This is not permission to break those callers: update them and their tests together. An inspection map returned from an Ecto context is not automatically a public DTO. Do not infer a field stability promise from its visibility over HTTP.
- **Legacy:** retained compatibility behavior with current callers or persisted state. Keep it until a specific migration proves preservation of identities, settings, buffered evidence and history. Legacy does not mean unused or safe to delete.

“Owner” below means the module responsible for behavior, not a person. The controller web layer owns HTTP status, serialization and error envelopes. Domain contexts own validation, review and mutation semantics. The Python authoring layer owns consumer declarations; runtime/transport own wire protocol implementation. Changes at a supported boundary need focused contract tests and a stated transition when existing callers cannot continue unchanged. Additive fields are preferable only when existing validation accepts them; never assume strict clients ignore unknown fields.

## Unified JSON HTTP inventory

All retained runner, resource and operator operations share `/api/v1` and the generated [OpenAPI contract](../contracts/http/v1/openapi.json). The [route disposition inventory](API-ROUTES.md) accounts for every current method/path and records renamed predecessors; it is generated and checked alongside the spec. See [HTTP API conventions](HTTP-API.md) for envelopes, query validation, DTO ownership, operation budgets, errors and extension rules.

Runner communication uses `/runner/control`, `/runner/inventory` and `/runner/observations` under that root. Result streams use `/results`; scheduled executions use `/assignments`, with editable state at `/assignments/:id/configuration`. Health and monitoring-loss episodes have separate concrete collections under `/incidents`. Existing reviewed commands retain their domain contexts, token/revision checks and atomicity. The bounded snapshot and selected result inspection are intentional documented operator diagnostics, with explicit limits rather than a complete-export guarantee.

No old HTTP aliases are retained. Controller, runner, policy CLI and repository-owned clients change together under the experimental same-release policy. Durable journals, buffered report identities, original evidence age, replay/admission authority and stored configuration history survive the cutover. HTTP path alignment does not change those persistence contracts.

Closed schemas define the explicitly rendered DTO fields. Dynamic consumer parameter values/schema metadata and heterogeneous reviewed/audit aggregates are declared JSON subtrees; their domain validators retain ownership of semantic, numeric and byte constraints. A context map is not automatically the public response. Changed output must be reflected in the declaration and serialized-response/behavior tests. The public Python SDK and Git transport remain separately owned boundaries.

## Browser and framework HTTP surfaces

The following GET routes are operator navigation. HTML, internal assigns and event payloads are internal; they are not a scraping API. All pages use the one `operator_ui` LiveView session and shared Pearl root. URL shape has no compatibility guarantee in this experimental project. Deep links, validated filter context and entity identity still have behavioral tests.

| Owner | GET routes |
| --- | --- |
| NextOverviewLive | `/`, `/checks`, `/results/:id`, `/results/:id/full`, `/checks/:id`, `/checks/:id/full`, `/expected/:id`, `/expected/:id/full`, `/coverage`, `/coverage/:id`, `/coverage/:id/full`, `/coverage/diagnostics/:id`, `/coverage/diagnostics/:id/full` |
| NextIncidentsLive | `/incidents`, `/incidents/health/:id`, `/incidents/health/:id/full`, `/incidents/loss/:id`, `/incidents/loss/:id/full` |
| ExecutionLive | `/executions/:id` |
| NotificationsLive | `/notifications`, `/notifications/:id`, `/notifications/:id/full` |
| PublicationInventoryLive / PublisherLive | `/coverage/publishers`, `/coverage/publishers/:id` |
| MaintenanceLive | `/maintenance`, `/maintenance/new`, `/maintenance/series/:id`, `/maintenance/series/:id/full`, `/maintenance/:id`, `/maintenance/:id/full` |
| ConfigurationLive | `/configuration`, `/configuration/:id` |
| ConfigurationRulesLive | `/configuration/rules`, `/configuration/rules/new`, `/configuration/rules/:id` |
| ConfigurationRepositoryLive | `/configuration/history` |
| DiscoveryLive | `/checks/:id/discovery` (result-stream identity; read-only source proposal) |
| DiscoveryConfigurationLive | `/configuration/discovery/:id`, `/configuration/discovery/changes/:id` |
| RunnersLive | `/runners`, `/runners/:id`, `/runners/:id/full` |
| GuideLive / LicensesLive | `/guide`, `/licenses` |

Result, execution and incident routes have distinct identities. Fly-overs opened from a host use its bounded typed `inspect` trail; page promotion uses a validated `page_entity`. Editing destinations keep their explicit workflow owners. See [UI architecture](UI-ARCHITECTURE.md).

`GET /health` outside the API scope is a supported probe owned by API.V1.SystemController outside the JSON API specification; its former JSON API alias was removed. Endpoint also mounts Phoenix's `/live` WebSocket transport (long polling disabled) and serves static `/assets/*` and `/favicon.ico`; these are internal framework/browser assets, not controller integration APIs. `Plug.Head` supplies HEAD behavior for GET routes. Fixture-server `/mode`, `/records`, proxy controls and SMTP test controls belong to isolated test services, not this controller's API.

## Python public SDK inventory

The authoritative package surface is `runner/mondek_runner/__init__.py::__all__`, with lazy loading tested by `runner/tests/test_public_api.py`. The authoring exports are listed below; the consumer-state extension is described at the end. Supported authoring declarations do not make every non-underscore method of their implementation classes a consumer contract.

| Export | Class / owner | Actual caller or verification anchor |
| --- | --- | --- |
| `App` | Supported / authoring | All consumer applications, generated starter, demo and policy examples. |
| `Binding` | Supported / authoring | Demo, node-local/load examples, explicit per-environment bindings and authoring tests. |
| `CheckGroup` | Supported / authoring | Optional output browsing metadata and binding defaults, scoped by source and monitored environment; [group semantics](CHECK-GROUPS.md). |
| `Capability` | Supported / authoring | Placement-policy tests and documented scoped runner capability declarations. |
| `Condition` | Supported / authoring | Grouped example and grouped-incident guide/tests. |
| `Consumer` | Legacy alias / authoring | Exact alias of `App`; public-export identity and consumer compatibility tests. Prefer `App` in new code, retain alias. |
| `Datasource` | Supported / authoring | Demo backlog; Prometheus, node/grouped/load integration consumers. |
| `DatasourceFactory` | Supported / authoring | Factory dependency injection in authoring tests and migration guide. |
| `Environment` | Supported / authoring | All consumer applications and placement policy. |
| `FromFactory` | Supported / authoring | Factory dependency injection in authoring tests and migration guide. |
| `Impact` | Supported / result API | Grouped example, result tests and grouped-incident guide. |
| `Output` | Supported / authoring | Consumer examples, policy example and declared result/target metadata. |
| `Parameter` | Supported / authoring | Demo/policy/consumer declarations and generated configuration controls. |
| `Placement` | Supported / authoring | Placement tests, runner deployment guidance. |
| `PlacementContext` | Supported / authoring | Typed custom placement predicate argument; placement-policy tests. |
| `Discovery`, `DiscoveryCandidate`, `DiscoveryChoice` | Supported / result evidence | Source-defined review metadata; bounded optional Result extension, shared Python/controller contract, installed consumer and browser coverage. Choices propose source changes and do not grant controller inventory authority. |
| `Result` | Supported / result API | Consumer outputs, built-in checks and result tests. |
| `ResultBuilder` | Supported / result API | Result aggregation tests and documented authoring; returned by `build_result`. |
| `RunnerContext` | Supported / authoring | Grouped/placement examples. |
| `Target` | Supported / authoring | Consumer examples, grouping and cross-environment target identity. |
| `build_result` | Supported / result API | Demo backlog and result aggregation tests. |
| `check` | Supported / result API | Decorated declarations throughout starter, examples and consumers. |
| `crit` | Supported / result API | Starter/local and result tests, consumer check outputs. |
| `discover_checks` | Supported / authoring | Module discovery and placement tests; `App` module registration. |
| `ok` | Supported / result API | Starter/local and result tests, consumer check outputs. |
| `unknown` | Supported / result API | Result tests and consumer unavailable/indeterminate verdicts. |
| `warn` | Supported / result API | Result tests and consumer warning verdicts. |

`App` construction/registration (`add`, datasource/factory registration), declaration dataclasses, placement predicates and result-building operations are consumer-facing. `App.private_settings`, `restore_private_settings`, `arguments`, metadata serialization and runtime selection plumbing primarily serve discovery/worker snapshot execution; do not establish a new public persistence format from those method names. `Result.to_dict` is shared with wire production; any change must preserve worker/controller validation, not just Python unit tests. Placement declarations select execution independently from monitored target/environment identity.

The module attributes `mondek_runner.api` and `mondek_runner.authoring` are intentionally available and identity-tested, but are not entries in `__all__`. Direct imports of the public names from their defining modules retain the same objects. Extra helpers are implementation boundaries with real dependencies: demo/load import `api.timestamp`; grouped example imports `authoring.stable_key`; consumer tests import `authoring.validate_params`; public API tests assert `api.truncate_utf8` compatibility. Do not delete or move these silently merely because they are not root exports. Inventory a specific helper's callers before changing it; this document does not promote all helpers/constants into a supported SDK.


## Commands and persisted compatibility

| Surface | Classification / owner | Callers and compatibility concern |
| --- | --- | --- |
| `mondek-runner` (`python -m mondek_runner`) | Supported command / `__main__` | Compose/deployment and acceptance start the actual runtime. Source entrypoints and state directory persist installation/session and replay evidence. |
| `mondek-runner init`, `validate`, `run` | Supported authoring commands / starter and local modules | Generated projects, starter/local acceptance and tests; generated imports and output conventions are consumer dependencies. |
| `mondek-policy validate`, `plan`, `apply`, `export`, `adopt`, `values` | Supported command / policy module | Declarative configuration, policy E2E/CLI tests. `adopt` additionally fetches a rule detail. Saved plans bind controller URL, exact manifest and review token; do not auto-replan an ambiguous apply. |
| `mondek_runner.checks` built-in checks | Supported packaged examples/check implementations, with legacy execution adapters | Policy example imports `filesystem`; demo/acceptance exercise built-ins. Preserve declared identity and configuration compatibility before removing old setup paths. |
| `worker`, `bundle`, `transport`, `runtime`, `config`, `state`, policy transport subprocess | Internal implementation / runner | Executed by shipped runtime/CLI and tests; module invocation and retained snapshots are real dependencies even without root exports. Consumer code should emit results, not invoke controller management transport. |

The legacy `App` behavior when no `RunnerContext` is supplied and restored private settings without the new context fields also remain in authoring. Worker compatibility supports old built-in/consumer execution paths. Their removal requires TD-12's explicit migration evidence; this inventory is not that migration.

## Machine-readable errors

JSON errors use `{error: {code, message, details?}, request_id}`. Parser/content/body failures are normalized before controller actions where a response can be produced. HTTP status and `error.code` are machine-readable; explanatory wording is not a discriminant. See [HTTP conventions](HTTP-API.md) and the generated error/operation schemas for statuses and bounds.

Domain review/fencing codes retain their meaning: `publisher_retired`, `publication_refresh_required`, `stale_selection`, `review_expired`, `review_changed`, `invalid_review` and `configuration_conflict`. Stale selected IDs are bounded structured details. Generic domain atom conflicts retain an explicit code, rather than requiring message parsing. Successful observation envelopes still use independent per-report dispositions; they are not HTTP errors.

Runner transport preserves HTTP status and safe gateway diagnostics without branching on private controller prose. Policy transport understands read envelopes and reports the nested bounded error message; it still refuses redirects and automatic retries/replanning. The coordinated migration updates every maintained HTTP caller, including native, service, browser and profiling harnesses.

## Rechecking completeness

Use the source lists rather than trusting a manually maintained count: compare every `get`/`post`/`put` and `live` declaration in `controller/lib/mondek_web/router.ex` with the tables, include `controller/lib/mondek_web/endpoint.ex` mounts, and compare every literal in `mondek_runner.__all__` with the SDK table. Search both literal URLs and constructed paths: policy adds `/api/v1/configuration/`, browser bulk appends its action, and runtime appends its three protocol endpoints and the consumer-state client adds `/api/v1/runner/state`. Search imports in `runner/tests`, `examples`, `tests`, generated starter source and any specifically authorized consumers. No hosted traffic inventory or universal third-party compatibility claim is implied.

The static consistency check used devenv Python to extract method/path pairs and LiveView routes from the router and AST literals from `__all__`: **64 API routes, 30 browser routes and 25 public exports, zero missing table entries**. This is static completeness verification, not a new execution test of all endpoints. Behavioral evidence remains in the existing native/API, CLI and real acceptance suites.

Source anchors: [router](../controller/lib/mondek_web/router.ex), [endpoint](../controller/lib/mondek_web/endpoint.ex), [API controllers](../controller/lib/mondek_web/api/v1), [public exports](../runner/mondek_runner/__init__.py), [policy client](../runner/mondek_runner/policy.py), [runner transport](../runner/mondek_runner/transport.py), [runner entrypoint](../runner/mondek_runner/__main__.py), [maintenance API](MAINTENANCE.md), [recurring maintenance API](RECURRING-MAINTENANCE.md), [acknowledgements](ACKNOWLEDGEMENTS.md), [runner/delivery inspection](RUNNERS-AND-NOTIFICATIONS.md).

## Optional pack API

`mondek_runner.packs.linux` supports `LinuxHost`, `Interface`, `Selection` and `linux_checks` as an opt-in consumer authoring surface. It returns ordinary bindings and uses the existing inventory/execution contracts; no new HTTP endpoint is introduced. The v1 memory/load/filesystem parameter contracts retain meaning across compatible pack updates. The discovery contract delegates selection policy; accepted catalogues are frozen separately from persisted disappearance bookkeeping. Membership changes use normal source publication/retirement. Kernel parsers, catalogue materialization machinery and fixture helpers are internal. See [check packs](CHECK-PACKS.md) for semantics and deployment limits.

## Consumer state extension

The supported execution-only SDK adds `CheckContext`, `StateStore`, `StateEntry`, `StateError`, `StateConflict` and `StateWriteIndeterminate`; [consumer state](CONSUMER-STATE.md) owns their behavior. `consumer_state` client internals are not additional public exports. `POST /api/v1/runner/state` uses existing gateway transport with independent live admission and no observation replay. Operator reads are `GET /api/v1/consumer-state` (metadata) and `/api/v1/consumer-state/:id` (selected current value); browser inspection lives at `/consumer-state`. No value data is added to ordinary snapshots, configuration Git or MCP.

## Correlation

`Mondek.Correlations` owns reviewed topology changes independently of native episode lifetimes. `/incidents/cases` and `/incidents/candidates` expose bounded projections; `/incidents/correlation/preview` and `/apply` preserve exact selection and idempotency. The CorrelationLive page owns manual editing at `/incidents/cases` and `/incidents/cases/:id`; it currently has no paired fly-over. Read-only MCP remains read-only. See [correlation](RUNTIME-INCIDENT-CORRELATION.md).
