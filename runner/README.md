# Runner and SDK reference

Start with [your first monitoring project](../docs/GETTING-STARTED.md) and the [Python authoring guide and API map](../docs/SDK.md). The sections below describe optional packs, advanced declarations, runtime behavior and bounds; they are not prerequisites for a first check. The [concepts guide](../docs/CONCEPTS.md) explains the server/runner/project vocabulary.

## Optional standard checks

Import `mondek_runner.packs.linux` to opt into memory, CPU load, filesystem capacity/inodes and interface link checks. Enable `LinuxHost(discover=True, ...)` for automatic mount/interface discovery. Code defines required expectations; existing configuration rules and project policy manage discovery inclusion/exclusion and thresholds. Import alone enables nothing. See [check packs](../docs/CHECK-PACKS.md) for semantics and native/container deployment.

## Declared coverage

Complete inventories include every registered check before placement filtering, along with selected/excluded decisions and public scope identities. This lets the controller's Coverage page show a concrete check even when no observer selects it. Declare an explicit `Binding` roster when you need to detect a node that has never connected; inherited local targets describe known deployments. Package-code and runtime fingerprints are separate from the installation-specific executable revision. Private datasource settings remain outside public catalogues. See [coverage auditing](../docs/COVERAGE.md) for the operator flow and runnable example.

An `App.metadata` override can change selected output identity arbitrarily. The SDK cannot infer equivalent excluded scopes from that override, so it retains excluded candidates as unbound diagnostics by default. Prefer ordinary `Binding`/`Output` target declarations; a custom `coverage_metadata` override can supply a complete truthful catalogue when a consumer needs custom metadata construction. Invalid or incomplete replacement discovery preserves the previously accepted inventory.

## Checks, monitored environments and runner placement

`App(checks=[checks_module])` recursively discovers decorated functions; plain functions also work directly. `Binding` is optional and is useful for distinct instances of reusable code. Monitored `Environment` values such as Staging/Production are separate from a `RunnerContext` describing execution location and declared capabilities. Datasources can require capabilities with `Placement`, and `@check(environments=(STAGING, PRODUCTION))` runs separately for both scopes on an eligible shared runner. See [runner contexts and the runnable three-runner example](../docs/RUNNER-CONTEXTS.md) for the authoring model and failure semantics.

Use `Capability("log-search", environments=("staging",))` when deployment access is scoped. `Placement(locality="same-environment")` relates execution and monitored scope; `"runner-target"` additionally enforces the exact runner subject across every output. A deterministic `Placement(policy=...)` can express consumer-specific relationships. A broken policy rejects discovery and retains accepted coverage; an unavailable datasource remains a collection failure.

## Start your own monitoring project

From the Mondek checkout:

```sh
mkdir -p .local
devenv shell -- uv run --project runner --locked mondek-runner init .local/my-monitoring --sdk-path ./runner
devenv shell -- uv sync --project .local/my-monitoring
devenv shell -- uv run --directory .local/my-monitoring --locked mondek-runner validate --consumer monitoring.app:app
devenv shell -- uv run --directory .local/my-monitoring --locked mondek-runner run --consumer monitoring.app:app --all --results
```

Generation creates an installable Python project, an example check with UI-delegated limits, local input, tests and agent guidance. It refuses an existing destination and performs no installation, network call or registration. The parent directory must exist. The generated README explains connecting to `devenv shell -- mondek start`, failure/recovery and persistent runner state. Use `--directory` or enter the project directory so its default local input resolves correctly. Local execution uses source defaults unless you supply `--params`; it does not fetch saved UI settings.

This contributor walkthrough deliberately uses the checkout as an editable SDK dependency. Ordinary installations use the published [mondek package on PyPI](https://pypi.org/project/mondek/) through the [getting-started guide](../docs/GETTING-STARTED.md). Commit the consumer's generated `uv.lock` and source in its own repository for ongoing monitoring. This walkthrough's `.local` directory is ignored by the Mondek checkout. Production packaging should use an immutable SDK/consumer deployment; see [deployment guidance](../docs/RUNNER-DEPLOYMENT.md).

For a separate consumer that must move independently of the SDK checkout, follow [the portable wheel installation path](../docs/DISTRIBUTION.md#contributor-alternative-a-consumer-with-a-portable-local-sdk-wheel). It retains a locally built wheel with the consumer and installs both packages non-editably, without a registry upload.

## Type checking consumer code

The installed SDK includes `py.typed` metadata. `@check` preserves the original function's argument names, keyword-only arguments and return type, including coroutines and generators. Editors can check `Output`, `Parameter`, placement declarations and supported comparison operators before a runner starts. Ordinary consumer abstractions and synchronous/asynchronous functions remain supported; the decorator does not wrap or replace the function.

Use your consumer project's type checker with its installed SDK environment. Runtime `mondek-runner validate` is still required: static types do not prove coverage keys, JSON values, parameter defaults, datasource injection or cross-field constraints. The SDK does not infer a typed `params` dictionary from parameter declarations or claim every internal transport dictionary is statically typed.

From this checkout, `devenv shell -- python3 tests/typing/run.py` builds and installs the actual wheel into a temporary environment, checks valid consumers and expected invalid declarations with strict Pyright, and verifies export identity and lazy imports. `mondek check` includes this check.

## Execution and persistence

The runner executes its accepted schedule independently of control and uploads. Each run gets a durable ID/sequence before an isolated worker starts. SQLite retains configuration, installation identity, boot progress and original buffered evidence; restart emits interrupted-run diagnostics and skips obsolete intervals.

```sh
devenv shell -- env PYTHONPATH=runner:examples MONDEK_CONTROLLER_URL=http://localhost:4000 MONDEK_STATE_DIR=.local/runner uv run --project runner --locked python -m mondek_runner
devenv shell -- env PYTHONPATH=runner:examples uv run --project runner --locked python -m unittest discover -s runner/tests -v
```

Use `devenv shell -- mondek demo` for the packaged Linux runner. `docker compose exec runner python -m mondek_runner --status` reads live queue/session state without claiming a new session. Workers are trusted repository code, isolated for failure and resource bounds, not a hostile-code sandbox.

`--status` includes only operational state and a compact inventory summary (source, revisions and check/result counts). The full catalog and internal metadata are omitted from both this output and control heartbeats. Use `validate --consumer module:app` to inspect a consumer's complete definitions without altering the running journal.

The default limits are 512 accepted check groups, three concurrent execution workers, one execution per assignment, 64 KiB combined captured output per run, 16 results per group, 2048-byte result summaries/diagnostics, 1000 buffered reports and 2 MiB buffered payloads. Assignment timeout bounds each worker process group, and the oldest due assignment gets the next available execution slot. Preparation uses one separate worker; control and uploads each own at most one HTTP helper process with an absolute deadline covering connection setup, headers and response reads. Timed-out helpers are killed and reaped, and their own lifetime alarm remains effective if the runner is killed. Spool overflow discards the oldest evidence, persists a loss counter/time, and never refreshes surviving evidence. `MONDEK_MAX_CONCURRENCY`, `MONDEK_SPOOL_MAX_REPORTS` and `MONDEK_SPOOL_MAX_BYTES` override the corresponding local limits. These are safety bounds, not a throughput guarantee; choose intervals and concurrency for measured collection cost.

Control heartbeats include a compact `scheduler` snapshot: accepted/running checks, execution worker limit, due checks waiting for a slot, the oldest waiting check's scheduling lag, pending preparation and prepared changes awaiting activation. Waiting counts exclude checks already executing; lag is zero when no due checks wait, uses the runner's monotonic clock, and describes the last reported instant. This is execution backlog, separate from buffered reports awaiting upload and from result freshness. Sustained waiting/lag indicates that collection cost and configured intervals exceed the available execution capacity; adjust intervals, group related collection, or provision appropriate runner capacity. No estimated finish time or on-time measurement guarantee is implied, and control disconnection makes this snapshot old.

Each check has a stable instance ID separate from its implementation kind, so several HTTP checks keep independent schedules, execution locks and evidence. A control response with `assignments_authoritative: true` establishes the complete accepted membership: omitted checks stop future scheduling and preparation, and the removal is durable before the next scheduler tick. An already running check may finish and upload its original evidence; controller retirement fences that evidence from current state. While disconnected, the runner continues its last accepted schedule until it receives the complete baseline. Missing authority markers and malformed baselines cannot remove accepted checks, and stale preparation results cannot restore a removed check.

## Ordinary consumer packages

`mondek` is an installable Python package with the `mondek-runner` console command. Install it and a consumer's locked dependencies into the same local environment. The entry point is an installed `module:app`, selected locally through `MONDEK_CONSUMER` or `--consumer`; the controller never supplies executable module names. The repository demo uses `demo_checks.app:app` and explicitly adopts the three legacy sample identities.

```python
from pathlib import Path
from mondek_runner import App, Environment, check, crit, ok

@check(id="export-present", name="Application export", expected_keys=("present",))
def export_present():
    if Path("/srv/application/export.json").is_file():
        return ok("present", "Export file exists")
    return crit("present", "Expected export file is missing")

app = App(
    source_id="application-checks",
    environment=Environment("node-a", "Production"),
    checks=[export_present],
)
```

```sh
mondek-runner validate --consumer my_checks:app
mondek-runner run --consumer my_checks:app --check export-present
mondek-runner run --consumer my_checks:app --all --concurrency 3
mondek-runner run --consumer my_checks:app --all --results
MONDEK_CONSUMER=my_checks:app MONDEK_STATE_DIR=./runner-state MONDEK_CONTROLLER_URL=http://localhost:4000 mondek-runner
```

`validate` imports and validates the whole consumer in a bounded subprocess and prints its complete inventory without constructing datasources. `run` executes one registered check through the real process supervisor; it exits unsuccessfully for incomplete collection. An optional `--params` accepts one complete JSON parameter set. These commands create only temporary snapshots, not runner sessions or controller registrations. In this repository, prefix them with `devenv shell -- env PYTHONPATH=runner:examples python3 -m mondek_runner` in place of the executable name when using source files directly.

`run --all` executes every registered scheduled check once, using source parameter defaults. Repeat `--check key` to select several code groups; each selected group produces all its expected results. Batch output is a JSON summary sorted by stable check key, with collection completeness, expected/received result counts, measured health counts and diagnostics for each group. Exit status is 0 when every collection completes, even when measured health is WARN, CRIT or UNKNOWN; incomplete collection or invalid selection exits 1 (invalid command options exit 2). Use one `--check` for full result summaries and timestamps, or to override its complete parameter set with `--params`. Batch runs reject `--params` to avoid applying one check's settings to others.

Add `--results` to a batch run to retain each result's original key, health, summary, value and source timestamp, including valid results from incomplete collections. These are the same executions counted in the summary; the command does not rerun checks to obtain details. Each check gains `results` and `omitted_results`, and the top-level `result_evidence` reports total included/omitted results. The complete JSON output, including its final newline, is limited to 8 MiB. Results are considered in check-key then result-key order, and only whole entries that fit are included; later smaller entries may still fit after a larger entry is omitted. No result text or timestamp is shortened. Omission counts describe display limits, while expected/received counts, measured health, collection completeness and exit status still describe all executions. With one `--check`, full results are already returned within the existing per-run bounds, so `--results` leaves that output unchanged.

Local runs validate the complete consumer before executing any check, including when selecting a subset. The pool defaults to three workers; `--concurrency` accepts 1–16, with at most 512 selected groups and one execution per group. Existing per-check process, timeout and output limits apply. A slow or failed group does not stop the others, and batch summaries retain partial measured health alongside incomplete collection. This command executes consumer code with local datasource access; it creates no persistent runner identity and does not contact the controller.

Functions may return one `Result`, a list/iterable, a coroutine or an async generator. Iteration is streamed within the output/time bounds. `ok`, `warn`, `crit` and `unknown` timestamp result creation by default. A reused result retains that timestamp. Pass `source_at=<original collection time>` for cached or remotely timestamped input; creating a new helper result does not make cached input fresh. Pass `source_at=None` when source age is unknown. Direct `Result(...)` retains its explicit nullable timestamp behavior. Exceptions and missing/duplicate outputs produce incomplete collection, preserving any valid earlier outputs.

Several declared environments create separate scheduled instances, each with its own injected `Environment`. An invocation's results all belong to that declared scope. Every execution has isolated datasource instances and module state; an in-memory cache does not persist across workers. Reuse query helpers freely, but use consumer-owned persistent input storage or a collector if acquisition must be shared. See [multiple-environment checks](../docs/MULTI-ENVIRONMENT-CHECKS.md) for scope, configuration and source-age guidance.

Pass `details="..."` to a result helper for multiline diagnostic context, such as observed timestamps and validation findings. Details are plain UTF-8 text, limited to 16 KiB per result, with NUL rejected; they are never rendered as HTML. Omitted details retain the previous wire shape. `Result` remains immutable and its existing positional arguments are unchanged. Details count toward the existing 64 KiB combined worker output cap, so several individually valid large results can still make a collection incomplete. Keep credentials and other secrets out of result text. Local `run --results` preserves details as part of each whole result within its documented display budget.

Use `build_result` to combine several findings about one fixed expected output:

```python
from mondek_runner import build_result

result = build_result(
    "validation",
    ok_summary="Export is valid",
    fail_summary="Export validation failed",
    base_details="Checked the current export document",
)
result.ok("Document can be read")
result.warn("Optional field is absent", details="Field: description")
# Return or yield result from the check; result.finalize() also returns a Result.
```

A builder selects the worst finding using `CRIT > UNKNOWN > WARN > OK`, uses `ok_summary` only for OK (including an empty builder), and retains finding summaries/details in call order. It accepts at most 128 findings and 16 KiB of combined details, including labels and separators. Exceeding either bound raises an error and invalidates that builder; it cannot later emit a misleading partial verdict even if the author catches the error. Returning or yielding a builder from synchronous or asynchronous code freezes a `Result` at that emission; subsequent builder changes cannot alter earlier results. Source time defaults to builder creation, not finalization. Set `source_at` explicitly when evaluating older input or when its age is unknown. A builder is an authoring convenience, not a result cache or a way to discover output membership.

Exported metadata and source parameters normalize finite integral floats to their exact integer values before definition hashing and serialization. For example, Python's `1e23` becomes `99999999999999991611392`, which is exactly that binary float's value; use an integer literal when you mean exactly `100000000000000000000000`. Fractional floats remain floats, explicit integers remain exact, and booleans remain booleans. This prevents PostgreSQL JSONB's exponent expansion from changing prepared definitions. Numeric comparisons use exact values, with no tolerance; a one-unit change to a large saved integer remains a different configuration. Parameter consumers should accept either Python numeric type for integral values. Private datasource/factory settings and environment metadata preserve their existing Python numeric types through snapshots; observation payload transport is unchanged.

Check IDs and `Binding(key=...)` values are explicit stable identifiers, independent of Python function names and display labels. `App(checks=[module])` discovers decorated functions recursively and fails the complete inventory on import errors. For the same function bound more than once, provide distinct `Binding` keys. IDs use 1–128 ASCII letters, digits and `_.:/@-` with an alphanumeric first character. An `Output(key, label, Target(key, label, kind))` gives each result an explicit monitored subject; `Binding(target=...)` supplies a common subject. The default subject is the execution environment's identity. `MONDEK_RUNNER_LABEL` names the observer separately from its environment grouping.

`Environment.id` is the stable grouping identity exported as `environment`; its optional `name` is exported separately as `environment_label`, falling back to the ID. Two environments may share a display name while retaining different IDs. Renaming the display name changes the prepared definition's metadata but keeps the environment and default target identities. Keep the ID unchanged when renaming; private `Environment.metadata` remains only in the runner's saved source settings and dependency injection.

Subclass `Datasource` and register its constructor with `app.register_datasource(MyDatasource, **local_settings)`; a function parameter annotated `MyDatasource` receives that instance. `Environment` parameters receive the binding's explicit environment or the app environment. Factories subclass `DatasourceFactory`, implement `new`, and register through `register_datasource_factory`; `Annotated[MyDatasource, FromFactory(MyFactory, "service", region="local")]` selects a constructed datasource. `new` may be an instance method, classmethod or staticmethod, including an inherited method; discovery validates its arguments without constructing the factory or datasource. Factory selection arguments are JSON-compatible values. Constructors are lazy and shared only within one execution process, not across scheduled runs. Datasource failures remain collection failures; constructor settings and credentials are never exported in inventory. Consumer code and deployment determine datasource access and node locality.

The `params` decorator argument supplies flat scalar defaults. Without `parameters`, values remain source-owned and a schema is inferred for inspection. To make the whole set operator-configurable, supply `parameters={name: Parameter(type, label, ...)}` for every value; supported types are number, integer, string and boolean. The UI and [explicit project policy workflow](../docs/CONFIGURATION-AS-CODE.md) share the same values and precedence. No separate policy document is needed when source defaults are sufficient. Numeric bounds, string byte lengths, scalar choices and numeric comparisons such as `(("warning", "lt", "critical"),)` are validated before execution. A singleton choice represents a fixed legacy value within a complete set. Targets, dependencies, output membership and schedule stay source-owned. New integrations should keep datasource settings outside the delegated threshold set.

Integer literals are limited to 4096 decimal digits, excluding the sign, in values, numeric bounds, choices and snapshotted JSON metadata. Integers within this limit remain exact; floating-point values and bounds must be finite. Complete parameter sets still have a 16 KiB JSON budget. These limits match the controller and stay below Python's default integer conversion limit without overriding runtime safeguards.

An explicitly delegated check may opt into compatible bulk editing with `@check(..., parameter_contract="capacity.used-percent.v1")`. This optional stable ID declares that the complete parameter set has the same meaning, units and comparison direction across its bindings; it is scoped by `App.source_id`, and the controller must also require exact complete schema equality. All `Binding` instances inherit the check's declaration. Omit it when target-dependent settings change parameter meaning, or use distinct check declarations/contracts. Change the contract ID when meaning changes even if field shapes remain identical. Checks without a contract remain individually editable; no contract is inferred from similar names or schemas. Contract IDs use the same 1–128 character identifier rules as check keys, are exported only when present, and are part of the snapshotted definition/source identity. Source-owned and empty parameter sets cannot declare one.

## Related failures and material impacts

Outputs may declare an explicit `Condition(key, label, namespace=None)` to group equivalent failures across checks and observers in the same monitored environment. The namespace defaults to `App.source_id`; crossing source boundaries requires an explicit shared namespace. Optional `Impact(key, label)` values on failed results express consumer-defined material consequences. Ordinary checks omit both. See [shared incidents](../docs/GROUPED-INCIDENTS.md) for authoring, acknowledgement coverage, independent maintenance and a runnable two-observer example.

## Source revisions and recovery

Each startup snapshots the consumer's top-level package, including data files, into the owned state directory before discovery. Bundles are limited to 4096 files/32 MiB, reject symlinks and omit bytecode. Source bytes, installed dependency versions, Python/SDK identity, binding metadata and an opaque identity for private declared settings determine the source revision. Discovery has a 15-second process deadline and a 4 MiB metadata limit. Worker assignment input has the same 4 MiB bound; result output remains capped at 64 KiB. The supervisor never imports consumer code. Successful complete inventories advance a durable monotonic inventory revision; a lost reply reuses that revision and original payload. Startup failure retains the prior inventory and accepted schedule, with a visible diagnostic. Restart after installing a corrected package retries discovery.

Datasource/factory constructor settings, factory selection arguments and environment metadata are JSON-compatible declared configuration. Snapshots preserve these privately in owner-only files inside owner-only bundle directories. An installation-local HMAC key binds their identity without exporting settings or an independently guessable credential hash. Previously accepted code therefore uses its original declared datasource settings after a deployment changes them. The state directory contains these private settings and must stay local and protected. An inventory-mode handshake prevents these runners from claiming another source's unbound legacy checks, even after discovery failure. Explicit adoption leaves previously retired demo checks retired and reports the skipped entries in runner status.

If importing a consumer reads environment variables to build its app, declare those construction inputs explicitly. Include every relevant name even when absent; `None` freezes absence, including optional check membership:

```python
import os

app = App(
    source_id="application-checks",
    environment=Environment("node-a"),
    checks=[export_present],
    construction_environment={
        "APPLICATION_SETTINGS": os.environ.get("APPLICATION_SETTINGS"),
        "OPTIONAL_EXPORT": os.environ.get("OPTIONAL_EXPORT"),
    },
)
```

These declared values remain only in the authenticated private snapshot. An accepted worker verifies them before importing its consumer, overlays exactly the declared values or absences during app construction and metadata validation, and restores its process environment afterward, including on failure. Malformed replacement settings therefore cannot break construction of the previously accepted app. The node and Prometheus starters declare their complete construction inputs. Consumers without this optional declaration keep their existing behavior; undeclared import-time inputs are not preserved. At most 64 names are allowed, each using 1–128 conventional environment identifier characters, with text or null values and a 64 KiB total JSON limit. Do not capture the entire environment.

The declaration covers construction only. A check that reads `os.environ` during execution sees the current deployment environment. Pass runtime configuration through registered datasource/factory settings or injected `Environment.metadata` so each accepted revision uses its original inputs. This mechanism does not preserve external configuration files read during import; place their bounded contents in a declared construction variable or keep them inside the snapshotted consumer package.

Accepted workers load the exact saved source snapshot and verify its revision, expected outputs and complete parameter set before execution. Changed or withdrawn definitions cannot reinterpret old evidence. Unreferenced bundles are pruned during the next successful discovery; active, prepared and running revisions remain retained. A broken source upgrade can therefore continue using the previous source code. This mechanism does not preserve independently upgraded third-party environments: do not modify dependencies or the SDK in place while expecting old revisions to execute. Use immutable deployment environments or restore the prior locked environment; changed runtime dependencies fail visibly. Changes to environment-derived binding metadata also require a newly prepared revision.

New snapshots include an installation-local, domain-separated MAC over the complete bounded manifest. Workers authenticate its exact bytes before trusting source paths, dependencies or inventory, retain all source/private/runtime verification and exact registration membership, and validate only the selected check's complete metadata against that authenticated inventory. Complete discovery still validates every check. Unrelated dynamic metadata drift therefore cannot veto an unchanged selected check, while changed selected targets, schemas, schedules or other definition fields reject execution. Unsupported snapshot formats and missing or invalid authentication fail closed. A matching authenticated format marker in private settings prevents dropping the manifest marker from bypassing authentication. Custom App metadata overrides retain full snapshot verification with the original revision argument.

This is a native authoring interface inspired by the original Mondek framework. It does not import that repository, provide drop-in `CheckResult`/Checkmk compatibility, or reuse its HTTP polling/result-cache runtime. Fixed expected outputs remain necessary; discovery of a partial result set cannot silently retire missing monitoring.

## Native command defaults

An installed persistent runner defaults to `.mondek-state` relative to its working directory and controller `http://127.0.0.1:4000`. Use `--state-dir` and `--controller`, or MONDEK_STATE_DIR and MONDEK_CONTROLLER_URL, for a service or remote server; flags take precedence. Keep the same absolute state directory across service updates. Explicit existing settings are unchanged. Docker Compose supplies its own container paths and controller origin. Local validate/run commands do not create persistent runner state. `mondek-runner init DIRECTORY` generates an ordinary registry-dependent project; the optional --sdk-path override is for editable contributor development.
