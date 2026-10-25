# SDK and HTTP boundaries

This caller inventory describes the current implementation; it is not a new versioning guarantee. It accounts for the current router, explicit Python exports, shipped commands, examples and maintained acceptance clients. No endpoint or export is removed or renamed by this inventory. Auth remains deferred; classification is about compatibility, not authorization.

## Classification and ownership

- **Supported:** an intentional consumer boundary used by the shipped runner, operator CLI, documented integration or check-authoring interface. Preserve its documented behavior and actual callers when changing it. This is an experimental release; neither its version nor `/api/v1` establishes an indefinite frozen schema or arbitrary old/new release interoperability.
- **Internal:** an application inspection/projection or implementation boundary with repository-owned callers. This is not permission to break those callers: update them and their tests together. An inspection map returned from an Ecto context is not automatically a public DTO. Do not infer a field stability promise from its visibility over HTTP.
- **Legacy:** retained compatibility behavior with current callers or persisted state. Keep it until a specific migration proves preservation of identities, settings, buffered evidence and history. Legacy does not mean unused or safe to delete.

“Owner” below means the module responsible for behavior, not a person. The controller web layer owns HTTP status, serialization and error envelopes. Domain contexts own validation, review and mutation semantics. The Python authoring layer owns consumer declarations; runtime/transport own wire protocol implementation. Changes at a supported boundary need focused contract tests and a stated transition when existing callers cannot continue unchanged. Additive fields are preferable only when existing validation accepts them; never assume strict clients ignore unknown fields.

## Runner and operator HTTP inventory

Paths in this table have the `/api/v1` prefix. Each row spells out one routed method/path; “API tests” means the matching tests in `controller/test/mondek_web`, while “browser” and “E2E” refer to maintained `tests/browser` and `tests/e2e` clients. LiveViews call domain contexts directly; they are not themselves JSON HTTP clients. “Internal” rows still have tested HTTP consumers in the harnesses. A listed context consumer alone does not establish an external HTTP integration.

| Method and path | Class | Behavior owner | Actual callers / evidence |
| --- | --- | --- | --- |
| `GET /snapshot` | Internal | Monitoring snapshot | E2E base harness, browser `helpers.mjs`, local verification/profiling; bounded development snapshot, not full inventory export. |
| `GET /overview` | Internal | Monitoring / Inspection | Browser overview helper and attention assertions. |
| `GET /coverage` | Internal | Coverage | Coverage E2E/browser, parity browser, publisher E2E. |
| `GET /coverage/publishers` | Internal | Coverage | Coverage and publisher E2E/browser. |
| `GET /publishers/:id` | Internal | PublisherLifecycle | Publisher E2E/browser and API tests. |
| `GET /publishers/:id/successors` | Internal | PublisherLifecycle | Publisher lifecycle API tests; LiveView uses corresponding context workflow. |
| `GET /publishers/:id/events/:event_id` | Internal | PublisherLifecycle | Publisher E2E/browser, including immutable witness assertions. |
| `GET /publishers/:id/events/:event_id/evidence/:observation_id` | Internal | PublisherLifecycle | Publisher browser and API tests. |
| `POST /publishers/preview` | Internal | PublisherLifecycle | Publisher E2E/browser and API tests. |
| `POST /publishers/apply` | Internal | PublisherLifecycle | Publisher E2E/browser and API tests. |
| `GET /coverage/diagnostics` | Internal | Coverage | Coverage E2E and API tests. |
| `GET /coverage/:id/observers` | Internal | Coverage | Coverage E2E/browser and API tests. |
| `GET /coverage/:id` | Internal | Coverage | Coverage API tests; LiveView detail uses corresponding context. |
| `GET /checks` | Internal | Monitoring / Inspection | Inventory browser helper, starter/coverage/policy and other E2E evidence inspection. |
| `GET /checks/:id` | Internal | Monitoring / Inspection | Grouped/policy E2E, bulk browser and diagnostic inspection. |
| `GET /configuration` | Internal | Monitoring / Inspection | Bulk browser pages assignments; configuration context drives UI. |
| `POST /configuration/policy/plan` | Supported | ConfigurationPolicy | `mondek-policy plan`, policy E2E/browser and CLI tests. |
| `POST /configuration/policy/apply` | Supported | ConfigurationPolicy | `mondek-policy apply`, policy E2E/browser and CLI tests. |
| `GET /configuration/policy/export` | Supported | ConfigurationPolicy | `mondek-policy export`, CLI tests and policy E2E. |
| `GET /configuration/policy/values` | Supported | ConfigurationPolicy | `mondek-policy values`, CLI tests and policy E2E. |
| `GET /maintenance` | Supported | Maintenance | Documented maintenance API; maintenance E2E/API tests. |
| `GET /maintenance/seed/:assignment_id` | Supported | Maintenance | Documented API; maintenance E2E/browser/API tests. |
| `POST /maintenance/preview` | Supported | Maintenance | Documented API; maintenance E2E/browser/API tests. |
| `POST /maintenance/apply` | Supported | Maintenance | Documented API; maintenance E2E/browser/API tests. |
| `GET /maintenance/:id` | Supported | Maintenance | Documented API; maintenance E2E/browser/parity/API tests. |
| `POST /maintenance/:id/cancel` | Supported | Maintenance | Documented API; maintenance E2E/browser/API tests. |
| `POST /maintenance-series/preview` | Supported | MaintenanceSchedules | Recurring maintenance workflow; maintenance E2E/API tests. |
| `POST /maintenance-series/apply` | Supported | MaintenanceSchedules | Recurring maintenance workflow; maintenance E2E/API tests. |
| `GET /maintenance-series/:id` | Supported | MaintenanceSchedules | Maintenance E2E/browser/API tests. |
| `POST /maintenance-series/:id/cancel-preview` | Supported | MaintenanceSchedules | Maintenance E2E/API tests. |
| `POST /maintenance-series/:id/cancel` | Supported | MaintenanceSchedules | Maintenance E2E/browser/API tests. |
| `GET /configuration/rules` | Internal | ConfigurationRules | Rules API tests; corresponding LiveView context workflow. |
| `GET /configuration/rules/seed/:assignment_id` | Internal | ConfigurationRules | Policy E2E/browser and rules API tests. |
| `POST /configuration/rules/preview` | Internal | ConfigurationRules | Policy E2E/browser and rules API tests. |
| `POST /configuration/rules/apply` | Internal | ConfigurationRules | Policy browser and rules API tests. |
| `GET /configuration/rules/:id` | Supported | ConfigurationRules | **Also used by `mondek-policy adopt`**, plus policy E2E and rules API tests; cannot treat the entire rules response as UI-only. |
| `POST /configuration/exception/reset` | Internal | ConfigurationRules | Policy E2E and rules API tests. |
| `POST /configuration/bulk/select` | Internal | BulkConfiguration via Monitoring | Bulk browser dynamic action helper. |
| `POST /configuration/bulk/prepare` | Internal | BulkConfiguration via Monitoring | Bulk browser dynamic action helper. |
| `POST /configuration/bulk/preview` | Internal | BulkConfiguration via Monitoring | Bulk browser dynamic action helper. |
| `POST /configuration/bulk/apply` | Internal | BulkConfiguration via Monitoring | Bulk browser dynamic action helper. |
| `POST /configuration/bulk/status` | Internal | BulkConfiguration via Monitoring | Bulk browser dynamic action helper. |
| `GET /runners` | Supported | RunnerFleet | Documented inspection API; fleet browser and profiling. Preserve pagination and independent contact/collection fields; full internal map is not frozen. |
| `GET /runners/:id` | Supported | RunnerFleet | Documented inspection API; runner inspection workflow and tests. |
| `GET /notifications` | Supported | Monitoring / Inspection | Documented delivery inspection API; no direct maintained HTTP caller found (UI/tests use domain inspection). |
| `GET /notifications/:id` | Supported | Inspection | Documented delivery detail API; no direct maintained HTTP caller found (UI/tests use domain detail). |
| `GET /assignments/:id` | Internal | Monitoring | Policy/rules browser, policy E2E and CLI-adjacent adoption verification. |
| `GET /assignments/:id/inspection` | Internal | Monitoring / Inspection | No direct maintained HTTP caller found; corresponding result-investigation context is used by the UI. |
| `POST /assignments/:id/exception/preview` | Internal | ConfigurationRules | Policy E2E and rules API tests. |
| `GET /incidents` | Internal | Monitoring / Conditions | Grouped/publisher/coverage E2E, grouped/publisher browser. |
| `GET /monitoring-incidents` | Internal | MonitoringLoss | Monitoring-loss browser and E2E inspection. |
| `GET /monitoring-incidents/:id` | Internal | MonitoringLoss | Monitoring-loss browser detail. |
| `GET /incidents/:id` | Internal | Monitoring / Conditions | Grouped/publisher/starter/policy E2E and grouped/publisher browser; revisions feed reviewed acknowledgement. |
| `GET /health` | Supported | APIController | Health probe alias; deployment/harnesses primarily use `/health`. Returns process response, not a complete monitoring-readiness assertion. |
| `POST /setup` | Legacy | Monitoring | No direct maintained HTTP caller found; wraps historical built-in setup context still used by demo/acceptance. Current projects publish inventory instead. |
| `POST /control` | Supported | Monitoring / Protocol | Runner runtime; transport proxy fixture, protocol and polling tests. Versioned control/session/configuration contract. |
| `POST /inventory` | Supported | Monitoring / Protocol / inventory contexts | Runner runtime; coverage/publisher E2E replay/fencing assertions. Versioned complete publication contract. |
| `POST /observations` | Supported | Monitoring / Protocol | Runner runtime, fixture transport and E2E replay/malformed report assertions. Versioned evidence/admission contract. |
| `PUT /assignments/:id` | Internal | Monitoring | Current instance-exception save plus built-in compatibility; acceptance, starter/policy/maintenance E2E, rules/bulk browser concurrent-change tests. Not merely obsolete setup. |
| `POST /assignments` | Legacy | Monitoring | No direct maintained HTTP caller found; built-in context creation remains tested. Retain until setup and migration dependencies are accounted for. |
| `POST /assignments/:id/retire` | Legacy | Monitoring | No direct maintained HTTP caller found; built-in context retirement remains tested. Source-owned removal is authoritative inventory withdrawal. |
| `POST /notifications/:id/retry` | Internal | Monitoring / notification contexts | Grouped E2E retry and delivery/operator context workflow. |
| `POST /incidents/:id/acknowledge` | Supported | Monitoring / Conditions | Explicit mode and both reviewed revisions are required. Service/browser callers use this contract; seconds-only requests reject. |
| `POST /assignments/:id/maintenance` | Removed | — | Use the reviewed maintenance seed/preview/apply/cancel APIs. Service/browser callers exercise those routes. |

The supported operator interfaces above preserve their documented operations, scope/revision rules and shipped-client fields. This inventory does not retroactively promise every context-map field as stable. Before introducing a DTO or changing a response, extract exact field dependencies from the named clients and add a contract test; retain current fields until that transition is explicit. Publisher, bulk and configuration review tokens are opaque, short-lived capabilities for an exact reviewed proposal, not durable identifiers to manufacture or reinterpret.

## Browser and framework HTTP surfaces

All following GET routes are **supported operator navigation**, owned by the listed LiveView. Their HTML, internal assigns and event payloads are **internal**; browser acceptance tests deliberately exercise real navigation, draft persistence and reconnect. Preserve deep links, filter/return-context semantics and the approved List / By target view. This does not make the pages a scraping API.

| Owner | GET routes |
| --- | --- |
| DashboardLive | `/`, `/checks`, `/checks/:id`, `/checks/:id/diagnostics`, `/resources/:id`, `/resources/:id/diagnostics`, `/incidents`, `/incidents/:id`, `/configuration`, `/configuration/new`, `/configuration/:id`, `/guide` |
| NotificationsLive | `/notifications`, `/notifications/:id` |
| CoverageLive | `/coverage`, `/coverage/publishers`, `/coverage/diagnostics`, `/coverage/:id` |
| PublisherLive | `/coverage/publishers/:id` |
| MonitoringIncidentsLive | `/monitoring-incidents`, `/monitoring-incidents/:id` |
| MaintenanceLive | `/maintenance`, `/maintenance/new`, `/maintenance/series/:id`, `/maintenance/:id` |
| ConfigurationRulesLive | `/configuration/rules`, `/configuration/rules/new`, `/configuration/rules/:id` |
| DiscoveryLive | `/checks/:id/discovery` (result-stream identity; read-only proposal flow) |
| RunnersLive | `/runners`, `/runners/:id` |

`GET /health` outside the API scope is a supported probe owned by APIController with the same body as its `/api/v1/health` alias. Endpoint also mounts Phoenix's `/live` WebSocket transport (long polling disabled) and serves static `/assets/*` and `/favicon.ico`; these are internal framework/browser assets, not controller integration APIs. `Plug.Head` supplies HEAD behavior for GET routes. Fixture-server `/mode`, `/records`, proxy controls and SMTP test controls belong to isolated test services, not this controller's API.

## Python public SDK inventory

The authoritative package surface is `runner/mondek_runner/__init__.py::__all__`, with lazy loading tested by `runner/tests/test_public_api.py`. All 28 exports are listed below. Supported authoring declarations do not make every non-underscore method of their implementation classes a consumer contract.

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

## Machine-readable errors: current behavior and required discipline

`APIController.respond/2` currently maps errors as follows. Human `error` prose is explanatory, not a stable discriminant. Direct detail endpoints have their own 404 prose. Framework/parser/body-limit errors can occur before the controller and do not necessarily use this envelope.

| Status / `code` | Current meaning | Client expectation |
| --- | --- | --- |
| 422, no code | Invalid parameters or domain validation | Correct the request; do not parse message wording as an enum. |
| 409, `configuration_conflict` | **Generic** `{:conflict, reason}` from multiple domains | Treat as conflict requiring current state/review; the name does not prove this is exclusively a configuration conflict. |
| 404, no code | Missing resource | Handle absence; preserve caller's selected identity rather than substituting another resource. |
| 409, `publisher_retired` | Publication fenced after operator retirement | Do not bypass fence by silently changing source/installation identity. |
| 409, `publication_refresh_required` | Restoration requires current successful discovery/new complete inventory | Honor current restoration request; replaying the old inventory is not restoration. |
| 409, `stale_selection` plus `stale_ids` | Selected assignments changed | Retain draft, refresh and review again. |
| 409, `review_expired` | Review lifetime expired | Retain draft and obtain a fresh review. |
| 409, `review_changed` | Reviewed proposal or matching records changed | Review current draft/state before apply. |
| 422, `invalid_review` | Missing/invalid review capability | Obtain a valid review; do not manufacture tokens. |
| 409, no code | Other domain atom/error fallback | Unknown conflict; no uniform machine-readable taxonomy exists yet. |
| 415, no code | API write is not `application/json` | Send the required JSON media type; this is the router's browser-cross-origin defense. |

Runner transport currently preserves HTTP status but does **not** parse the controller's error-body code into domain-specific runtime control flow. Successful runner responses require `version: 1`; session fencing, complete-inventory authority, replay identity and original evidence age are more important compatibility contracts than human error wording. Policy transport currently reports HTTP status plus bounded `error` text and does not branch on JSON `code`; its existing behavior refuses redirects and automatic retries. Acceptance/API tests do assert specific codes for review, retirement and restoration outcomes. A future specialized error must therefore preserve those tests and consider old clients; do not rename `configuration_conflict` globally without an alias/version or coordinated migration.

For future supported response changes: define the exact endpoint/fields or error variants being stabilized; add independent request/response contract tests for the shipped client and controller; document unknown-code behavior and retriable versus re-review-required outcomes; state the compatibility path. Keep internal inspection projections separate from that explicit promise. No generic API framework or blanket serializer rewrite is justified by this inventory.

## Rechecking completeness

Use the source lists rather than trusting a manually maintained count: compare every `get`/`post`/`put` and `live` declaration in `controller/lib/mondek_web/router.ex` with the tables, include `controller/lib/mondek_web/endpoint.ex` mounts, and compare every literal in `mondek_runner.__all__` with the SDK table. Search both literal URLs and constructed paths: policy adds `/api/v1/configuration/`, browser bulk appends its action, and runtime appends the three protocol endpoints. Search imports in `runner/tests`, `examples`, `tests`, generated starter source and any specifically authorized consumers. No hosted traffic inventory or universal third-party compatibility claim is implied.

The static consistency check used devenv Python to extract method/path pairs and LiveView routes from the router and AST literals from `__all__`: **64 API routes, 30 browser routes and 25 public exports, zero missing table entries**. This is static completeness verification, not a new execution test of all endpoints. Behavioral evidence remains in the existing native/API, CLI and real acceptance suites.

Source anchors: [router](../controller/lib/mondek_web/router.ex), [endpoint](../controller/lib/mondek_web/endpoint.ex), [API controller](../controller/lib/mondek_web/controllers/api_controller.ex), [public exports](../runner/mondek_runner/__init__.py), [policy client](../runner/mondek_runner/policy.py), [runner transport](../runner/mondek_runner/transport.py), [runner entrypoint](../runner/mondek_runner/__main__.py), [maintenance API](MAINTENANCE.md), [recurring maintenance API](RECURRING-MAINTENANCE.md), [acknowledgements](ACKNOWLEDGEMENTS.md), [runner/delivery inspection](RUNNERS-AND-NOTIFICATIONS.md).

## Optional pack API

`mondek_runner.packs.linux` supports `LinuxHost`, `Interface`, `Selection` and `linux_checks` as an opt-in consumer authoring surface. It returns ordinary bindings and uses the existing inventory/execution contracts; no new HTTP endpoint is introduced. The v1 memory/load/filesystem parameter contracts retain meaning across compatible pack updates. The discovery contract delegates selection policy; accepted catalogues are frozen separately from persisted disappearance bookkeeping. Membership changes use normal source publication/retirement. Kernel parsers, catalogue materialization machinery and fixture helpers are internal. See [check packs](CHECK-PACKS.md) for semantics and deployment limits.
