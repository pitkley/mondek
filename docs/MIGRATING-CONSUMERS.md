# Port an existing Mondek consumer

Port the monitoring logic into an installed `mondek_runner` consumer; the new SDK does not load the original `mondek.Mondek` application or translate its Checkmk output. This guide compares the actual APIs in the original sibling checkout with the [current authoring interface](../runner/README.md). It describes a manual port, not automatic source, state or history compatibility.

Your monitoring abstractions belong in your Python project. Use helper functions, classes, generators and dependencies to express your policies. The examples demonstrate authoring and deployment patterns, rather than a comprehensive check standard library.

The small [demo policy class](../examples/demo_checks/backlog.py) separates acquisition, an application snapshot and policy evaluation using ordinary Python. It combines two findings into one result; the controller handles that result without knowing either rule. Reuse this pattern for your own abstractions or choose a different structure appropriate to your project.

## Map the concepts first

| Original Mondek | Current SDK and porting decision |
| --- | --- |
| `Mondek(checks=..., execution_environment=...)`, served as ASGI for Checkmk polling | `App(source_id=..., runner=RunnerContext(...), environment=..., checks=...)`, loaded locally by `mondek-runner`. The runner collects independently and sends reports to the controller. |
| `@check(name=..., environments=[...], cache_for=...)` | Declare `@check(id=..., name=..., expected_keys=(...))` or explicit `outputs`. Set collection interval, execution timeout and evidence freshness separately. |
| Optional check ID; otherwise function/service-derived execution identity | A required stable check ID. Reuse a function with explicit `Binding(key=..., environment=..., outputs=...)` entries, each with a distinct key. A display-name change is not a new identity. |
| Checkmk hostname, service name and result `name_suffix` / `alternative_hostname` | Choose an explicit `Output.key` for each independently monitored condition and a `Target.key` for its subject. Labels describe them; they do not determine identity. Two checks for the same target still have independent results/incidents. |
| `ok("summary")`, `CheckResult`, numeric `CheckState` | `ok("output-key", "summary")` or `Result(key, "OK", summary, value, source_at)`. Health names are `OK`, `WARN`, `CRIT`, `UNKNOWN`; helpers also require an output key. |
| Result details and composite result builders | Optional `details=` carries bounded plain text; `build_result` combines findings into one declared result with `CRIT > UNKNOWN > WARN > OK`. Your own helper can return `Result` directly for a different policy. |
| `Environment("production", hostname=..., **metadata)` and `EnvironmentRegistry` | `Environment("stable-id", "Display name", metadata={...})` is the monitored scope. Use the app default, a binding environment or `@check(environments=(STAGING, PRODUCTION))` for independent scoped invocations. Host identity belongs to `Target`, execution location to `RunnerContext`. |
| `SchedulingStrategy` on checks and datasources | `Placement` declares context restrictions, required capabilities, supported environments and locality. Scoped `Capability` grants describe deployment access; `Placement(policy=...)` handles custom deterministic relationships. Temporary `SKIP`/cached-result behavior is not a placement outcome. |
| Annotated `Datasource`, registered constructor, factory selection | Subclass the new `Datasource` / `DatasourceFactory`, register them on `App`, and retain typed injection. Use `Annotated[Source, FromFactory(Factory, ...)]` with an explicit factory type. |
| Code-defined thresholds or Checkmk metric levels | Evaluate thresholds in consumer code. Flat scalar `params` remain source-owned unless a complete `parameters` schema explicitly delegates editing to the UI. |

The runner is the observer, the target is what it observes, and the environment is a monitored scope. A dedicated monitoring runner can query a database about other nodes; a node runner reads the files/processes its own account can access. `Environment` does not move execution to another machine. The same project can run on many observers, with placement selecting each inventory before datasource construction. The [placement guide](RUNNER-CONTEXTS.md) maps locality, scoped access and consumer policy to the new model. Explicit targets replace the old hostname resolution chain.

An old `MustRunInTargetEnvironmentStrategy` may have used an environment to identify a particular machine. Choose `locality="same-environment"` only when the monitored scope match is sufficient; use `locality="runner-target"` for an exact host subject. Two hosts in Production share an environment but not local bytes. For local volume/service subjects, express the ownership relationship in consumer policy without assuming shared names establish identity.

Keep source, check, output and target IDs stable when their meanings stay the same. Give a different subject a new target ID, even if it reuses a path or display name. Each runner state directory owns a separate installation identity; copying it is not how to add a node. It cannot switch source IDs. See [deployment and replacement](RUNNER-DEPLOYMENT.md#several-applications-on-one-node).

## Declare membership before collecting

An old generator could emit Checkmk services through varying suffixes or hostnames. The new consumer must declare the complete expected output set before execution: at most 16 outputs per scheduled check and 512 checks per runner. Split larger inventories into stable, explicitly named groups; avoid regrouping targets by their changing position in a query response. These are admission limits, not throughput promises.

A missing output is missing evidence, not withdrawal. Emit a measured failure when collection proves a subject is absent; report unknown source age when it cannot be inspected. Exceptions, duplicate outputs and partial collection remain visible as collection problems rather than inventing a fresh Critical measurement for every target. Previously measured health may remain displayed with unavailable or stale evidence. Replace old error-expansion handlers with explicit expected membership and deliberate result handling.

Withdraw monitoring by publishing a successful complete inventory without the check/output. Failed import or collection must not supply an empty replacement inventory. Withdrawal retires the affected result and preserves its history; returning later creates a new monitored incarnation. Unchanged siblings remain monitored. Module discovery is strict: `App(checks=[module])` rejects the complete discovery on import failure, unlike the original discovery helper's optional skip-on-error behavior.

## Keep execution and evidence time separate

Synchronous functions, coroutines, lists/iterables, generators and async generators are supported. Each scheduled execution has its own bounded worker process. A generator streams that execution's results; it is not a permanent background service. One execution cannot overlap another for the same scheduled check. Bound datasource reads and network timeouts inside the overall worker deadline.

The original HTTP poll started or collected work, and `cache_for` controlled reuse after pickup. There is no direct conversion of `cache_for="5m"` to a new freshness policy. Choose `interval_seconds` for how often new collection is due, `timeout_seconds` for its execution budget, and `freshness_seconds` for how old source evidence may be. A remembered verdict never suppresses a due run or becomes fresh because the UI refreshed. Starting or failing a new run does not erase the last measurement.

The new helpers timestamp result creation by default; direct `Result(...)` defaults `source_at` to `None`. Pass the original collection timestamp for cached or remote samples, and `source_at=None` when it is unknown. For a file-age check, inspection time can be the measurement time while the file's modification age is the measured condition: a three-hour-old file can be a freshly measured failure. Do not give a cached database sample the current time merely because it was returned now.

## Port datasource configuration and thresholds

Registered constructor settings, factory arguments and `Environment.metadata` must be JSON-compatible. Datasources are constructed lazily and shared only inside one execution process; old application-wide caches, clients and connections do not survive across runs. To collect once and evaluate several related targets, use one bounded multi-result check. For different private bindings of the same datasource type, use a factory; registering that type repeatedly replaces its earlier registration.

Keep credentials, URLs, paths, query definitions, target membership and schedules in the source deployment. Registered private settings are retained with accepted source snapshots and are not exported as inventory parameters. Declare import-time environment inputs through `App(construction_environment=...)`, including absent optional values, when they determine the app's construction. Execution-time environment reads are not frozen; inject runtime settings through datasources or environment metadata. [Source recovery](../runner/README.md#source-revisions-and-recovery) explains the package and dependency limits.

To permit operator edits, declare every parameter through `Parameter` with its type, label, units, bounds/choices and any numeric comparisons; the function receives the complete `params` dictionary. Targets and access remain source-owned. Bulk editing additionally requires a consumer-declared `parameter_contract` whose meaning is shared within the same source ID and an exactly matching complete schema. Similar field names alone do not establish compatibility. Saving multiple checks is atomic; each runner prepares, activates and measures its saved versions independently.

## Run an existing ordinary-file consumer

The complete [node-local consumer](../examples/consumers/src/mondek_examples/node_local.py) is an executable porting reference: stable bindings, private file access, typed delegated thresholds and explicit source time. Its [file policy](../examples/consumers/src/mondek_examples/node_common.py) handles existence, regularity, readability, size and age. From this repository root, the following inspects the existing README without changing it or registering a runner:

```sh
devenv shell -- uv sync --project examples/consumers --locked --no-dev --no-editable \
  --reinstall-package mondek-local-examples --reinstall-package mondek

devenv shell -- env MONDEK_LOCAL_NODE_ID=author-workstation \
  MONDEK_LOCAL_FILE="$PWD/README.md" MONDEK_LOCAL_FILE_ID=repository-readme \
  examples/consumers/.venv/bin/mondek-runner validate \
  --consumer mondek_examples.node_local:app

devenv shell -- env MONDEK_LOCAL_NODE_ID=author-workstation \
  MONDEK_LOCAL_FILE="$PWD/README.md" MONDEK_LOCAL_FILE_ID=repository-readme \
  examples/consumers/.venv/bin/mondek-runner run \
  --consumer mondek_examples.node_local:app --check configured-file
```

Inspect the returned health and summary: a completed collection exits successfully even when its measured health is Warning or Critical. Validation checks the whole catalog without constructing datasources; the selected local run executes real collection without a persistent session or controller registration. Follow the [deployment walkthrough](RUNNER-DEPLOYMENT.md) to start continuous collection with the same source settings and a new persistent state directory. Use [node resources](../examples/consumers/src/mondek_examples/node_resources.py) for several independent local subjects, or [Prometheus groups](../examples/consumers/src/mondek_examples/prometheus_groups.py) for several remote queries.

## Remaining porting limits

There is no Checkmk agent/piggyback export, imported Checkmk history, `CheckResult`/`OngoingCheckResult` adapter, service-label mapping, hostname strategy, custom scheduling/error-handler protocol, or old cache/Redis backend compatibility. The current result carries one optional numeric value, a bounded summary and up to 16 KiB of plain-text details. It does not carry the old collection of named metrics or graph boundaries; full historical metrics/charting remains outside this implementation. The [result builder](../runner/README.md#ordinary-consumer-packages) is optional and domain-neutral. Composite findings share one result's incident; declare separate outputs when independent histories are needed.

Keep the previous locked consumer environment while validating a port. Accepted snapshots retain declared source/private settings, not an independently upgraded Python/SDK/third-party environment. Existing package tests can inform the new consumer tests, but successfully importing a port does not establish equivalent measurements, timing, membership or notifications. Check those behaviors against known healthy, failed, unavailable and partially collected inputs before replacing monitoring.
