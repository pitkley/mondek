# Checks spanning several monitored environments

## Decision

Keep one monitored environment per scheduled check instance. Register one decorated function with `environments=(STAGING, PRODUCTION)` to create two independently scheduled instances, each receiving its own `Environment`. A single invocation may report several declared targets within that environment. A runner in Shared Services can execute both instances; its execution location does not determine their monitored environment.

One function can be registered for several environments while each scheduled invocation keeps its own environment. See the [runner-context model](RUNNER-CONTEXTS.md) and [placement consumer](../examples/consumers/src/mondek_examples/placement.py).

The evaluated extension is deliberately not added to the result protocol. `Result` has no environment override. Giving one execution authority over several environments would couple their configuration and placement policies. Sharing expensive raw input can be addressed separately while keeping independently evaluated results.

Unsupported `environment` and `environment_label` fields on output declarations or emitted results are rejected, including explicit null values. Custom metadata must not appear to change a scope that the controller would otherwise ignore. Declare the monitored environment on the check instance instead; ordinary assignment-level environment metadata remains valid.

## Which pattern to use

| Consumer need | Supported pattern |
| --- | --- |
| The same log or Prometheus query for Staging and Production | Declare both environments on one check; use the injected environment to choose/filter the query. Each scope gets independent evidence and failures. |
| Different threshold values | Use environment-specific `Binding(..., environment=..., params=...)` defaults. Parameters explicitly delegated through `parameters=` can also use durable rules scoped to the monitored environment; source-owned values remain code-owned. Bindings retain the decorator's generated scope identity when the base key is unchanged. |
| Different cadence, timeout or freshness policy | Declare separate decorated wrappers or generate declarations in a consumer factory, reusing ordinary query/evaluation helpers. These values belong to the check declaration; `Binding` currently has no schedule override. |
| Several services or volumes in one environment from one query | Declare several `Output` targets on one check and emit their separate results. They share that invocation's schedule and parameter set; split checks when those policies should differ. |
| One expensive response containing data for several environments | Keep per-environment evaluation, and explicitly choose whether repeated acquisition is acceptable or use a consumer-owned persistent input cache/collector. Shared acquisition is not automatically deduplicated by Mondek. |
| A temporary outage for one environment | Report collection failure for that declared instance. Other environments continue independently; the outage must not remove the failing environment from discovery. |
| Adding/removing an environment | Update the consumer's declared environments, validate and publish a complete inventory. Stable environment IDs preserve unchanged scope identities; removal retires only that instance. |

Environment expansion counts toward the existing 512-instance source limit, with at most sixteen declared outputs per instance. Expanded instances share the runner's bounded worker pool: independent scheduling does not guarantee simultaneous or immediately due execution. See [runner limits](../runner/README.md). Outputs must be declared; returning a previously unknown environment or target does not discover new monitoring. For a changing environment roster, publish a deliberate complete source update from authoritative deployment data. Do not infer membership from whichever environments happen to respond successfully during collection.

## Shared helpers are not shared acquisition

Each supervised execution has its own worker process and datasource instances. Module globals, functools.cache and an App's in-memory datasource cache do not provide shared lifetime across scheduled executions. A consumer port must account for this when preserving amortized acquisition behavior.

A consumer can use an external collector or its own process-safe persistent cache through ordinary Python code. Keep that live data outside the snapshotted source bundle; supply its stable path/endpoint through private datasource settings. Cache raw input together with its acquisition time and scope/query identity, rather than a reusable verdict. Coordinate concurrent writers, bound storage and wait time, and keep failures distinguishable from a valid empty dataset. These are properties of the consumer's acquisition implementation, not a framework standard library.

Every due invocation still evaluates its own active parameters. Emit the original input acquisition time as `source_at`; reading cached input must not reset its age. Expired or unavailable input cannot become a fresh result because another environment's evaluation succeeded. A shared collector may reduce query cost, but its availability then affects all dependent scopes. Separate monitored instances preserve that visibility rather than silently treating another scope's evidence as a substitute.

## Why an output-level environment is a larger contract

Environment identity participates in placement grants, configuration-rule matching, result incarnation, maintenance, shared-condition identity and retained incident history. Today those all follow the assignment's declared environment and immutable configuration generation. A free-form field on an emitted result could bypass the scope reviewed at discovery or configuration time.

A future cross-environment collection feature would therefore need explicit source-declared output scopes, admission validation for each scope, clear parameter-policy conflicts, partial-failure semantics and historical generation matching. It also needs a version/capability boundary that older controllers reject, since earlier v1 controllers ignored these extra fields. It should be justified by a concrete requirement such as a rate-limited single response whose scopes must be acquired together. That is distinct from letting reusable check code run for several environments, which already works.

## Try the existing implementation

```sh
devenv shell -- mondek placement
devenv shell -- mondek placement-acceptance
```

Open [Checks](http://localhost:4013/checks) and select the runner **Placement shared services** to see its independent Staging and Production service results. The same project also runs two node-local filesystem checks. The disposable acceptance command exercises a Staging-only failure/recovery, restricted environment access, failed source discovery, reconnect and deliberate withdrawal/restoration. It does not claim cross-environment single-query caching.
