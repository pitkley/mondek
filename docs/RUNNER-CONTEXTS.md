# One project, several runners and monitored environments

## Three separate questions

| Concept | Question it answers | Example |
| --- | --- | --- |
| `Environment` | Which monitored scope does this check describe? | Staging or Production |
| `RunnerContext` | Where does this code execute, and which capabilities did that deployment declare? | Node A with local filesystem access; a shared observer with log-search access |
| `Target` | Which particular subject does this result describe? | Node A, a persistent volume, a service or an environment-wide condition |

Datasource-driven selection does not require a deployment list of enabled integrations. A datasource can declare `Placement(locality="same-environment")` when it must run in the monitored environment, or `Placement(runner_contexts=("shared-observer",))` when it belongs on a named observer. Every dependent check inherits those requirements automatically. Declare the runner's context and local environment once; use capability grants only when they express an additional access distinction. Missing credentials and network failures are collection failures, not reasons to exclude expected checks.

A shared observer can measure Production and Staging. Its physical location does not determine the result's environment. `App.environment` is only a fallback monitored scope; omit it when every selected check declares its own scopes. `RunnerContext.local_environment` independently declares the environment where execution takes place. It is needed by locality constraints, but remote checks do not need to declare it. Never infer execution location from the default monitored scope.

`RunnerContext.id` is a source-owned logical execution identity, separate from the controller's durable runner installation ID and each restart's session ID. Capabilities describe declared access, `Placement` determines eligibility, and the runner's scheduler determines when an eligible check runs. Placement does not elect an owner among eligible runners.

## Ordinary checks and module discovery

Use decorated functions directly, or give `App` a module/package. Recursive discovery imports its modules and finds decorated functions; an import failure rejects the whole proposed inventory.

```python
from mondek_runner import App, Environment, RunnerContext, Target
from . import checks

PRODUCTION = Environment("production", "Production")

app = App(
    source_id="my-monitoring",
    environment=PRODUCTION,
    runner=RunnerContext(
        "node-a",
        "Node A observer",
        capabilities=("local-files",),
        target=Target("host:node-a", "Node A", "host"),
        local_environment=PRODUCTION,
    ),
    checks=[checks],
)
```

An ordinary node check inherits Production and the Node A subject. Install the same package on Node B with its own declared context/default subject; it measures Node B separately. Use the locality declaration below when a check must measure its executing node. The SDK does not copy the node's filesystem into another runner or infer access from a successful probe.

`Binding` is optional. Use it to instantiate one function several times with distinct stable keys, parameter defaults, labels or subjects. It describes one use of reusable code. A simple function or recursively discovered module needs no explicit binding.

## A shared observer measuring multiple environments

The check declares monitored scopes. Its datasource declares the execution capability it needs:

```python
from mondek_runner import Datasource, Environment, Placement, check

STAGING = Environment("staging", "Staging")
PRODUCTION = Environment("production", "Production")

class LogSearch(Datasource):
    placement = Placement(requires=("log-search",))
    # Constructor/access/query helpers belong to your consumer project.

@check(
    id="emergency-logs",
    expected_keys=("errors",),
    environments=(STAGING, PRODUCTION),
)
def emergency_logs(logs: LogSearch, environment: Environment):
    # Your implementation queries the correct scope and returns its verdict.
    return logs.check_emergency_errors(environment.id)
```

The query helper in this example belongs to the consumer project; it is not a framework-provided Elasticsearch API. Register `LogSearch` with that deployment's private connection settings and declare its access explicitly:

```python
from mondek_runner import Capability, RunnerContext

shared = RunnerContext(
    "shared-observer",
    capabilities=(
        Capability("log-search", environments=("staging", "production")),
    ),
)
```

No `App.environment` is needed for that two-scope check. The controller receives two independent scheduled instances. Each has its own injected `Environment`, parameters, result, freshness and incident history. Adding, reordering or renaming an environment does not rename an existing instance; the generated key depends on the base check ID and stable environment ID, using a bounded hash to avoid ambiguous concatenation.

Without an explicit `Output` or `Binding` subject, these scoped instances describe their respective environments, with target kind `environment`. Provide a more specific service/cluster subject when that is what the check actually measures. An explicitly scoped check never silently inherits the shared runner's host as its subject. An explicit `Binding(environment=...)` selects one of a check's declared environments; an override outside that declaration fails validation.

This implementation uses separate invocations per environment. A single invocation can still return several declared target results, but all of those results share its monitored environment. This matches the original Mondek's environment expansion; a cross-environment output protocol is not needed for the current consumer patterns. Shared helpers belong in consumer code, but isolated worker processes do not share an in-memory cache. See [multiple-environment checks](MULTI-ENVIRONMENT-CHECKS.md) for configuration, differing schedules, expensive acquisition and the reasons for retaining this boundary.

## Access scopes and source contracts

A capability grant answers which environments this particular deployment can access. Giving another runner `Capability("log-search", environments=("production",))` selects only the Production invocation of the same two-scope check. Staging remains in the source declaration, with an exclusion explanation on that runner. Every required capability must cover the invocation's monitored environment; a check needing both logs and Kubernetes data cannot combine Staging-only log access with Production-only Kubernetes access.

The existing string form, `capabilities=("log-search",)`, is equivalent to `Capability("log-search")`: it asserts access for every monitored environment. This preserves existing deployments, but scoped grants are preferable when access differs between environments. Identical duplicate grants collapse; different grants with the same name are rejected rather than silently widening access. Put all intended scopes in one grant. Capability names and environment IDs are public identifiers, not credentials or proof that authorization succeeds. Datasource settings and actual queries still determine which endpoint and credentials are used.

An inherent restriction of the source is different from deployment access:

```python
class ProductionLedger(Datasource):
    placement = Placement(
        requires=("ledger-read",),
        monitored_environments=("production",),
    )
```

This datasource declares that its data describes Production only. A check using it must not declare a Staging invocation. Such a contradiction rejects the proposed inventory; the SDK does not silently remove part of the check's declared coverage. All datasource, factory and check environment restrictions intersect. A deployment-specific Staging access limitation belongs on its capability grant instead.

## Locality: same environment or this node

A local datasource can enforce the relationship between where it executes and what it reports:

```python
class LocalFilesystem(Datasource):
    placement = Placement(
        requires=("local-files",),
        locality="runner-target",
    )
```

With the Node A app above, an unscoped check using `LocalFilesystem` inherits Production and the Node A host. `runner-target` requires both the monitored environment to equal `RunnerContext.local_environment` and every resolved output subject to match `RunnerContext.target` by stable key and kind. A result label can change without changing that identity. An explicit `Binding.target` or `Output.target` cannot make Node A's local measurement eligible as Node B's measurement.

For access tied to an environment but not to a particular host, use `locality="same-environment"`. For example, an in-cluster datasource might require execution within the monitored cluster's environment while reporting a service subject. This requires the environment match but does not restrict target identity. The default, `locality="any"`, imposes neither relationship and suits remote queries.

Missing `local_environment`, or a missing runner target when `runner-target` needs it, is a deployment error on an otherwise eligible runner. A declared but different environment or subject excludes that invocation with a reason. An unrelated runner without the required capability need not invent local declarations for checks it cannot run.

`runner-target` intentionally means an exact subject. A volume, file or service with its own target identity is not automatically a child of the host. Use an appropriate environment constraint and consumer-owned placement policy for a declared local resource relationship; do not treat shared name prefixes as proof of ownership. Moving a volume between observers also needs durable target configuration and controller handoff semantics, which this placement API does not supply.

**Ordinary local checks should inherit the deployment's monitored environment and subject.** Explicitly scoped checks retain their existing default environment subject, even when that environment equals the runner's local environment. They therefore need an explicit matching host subject to satisfy `runner-target`. Locality validates resolved identity; it does not rewrite targets or change existing result histories.

## Consumer-defined placement rules

For a relationship the built-in declarations cannot express, supply `Placement(policy=...)`. A policy receives a frozen `PlacementContext` containing `runner`, `environment`, `check_id` and the resolved `targets`. It returns `None` for eligibility or a nonblank exclusion reason of at most 200 UTF-8 bytes. For example, this consumer's static access map assigns observers to environment-specific network probes:

```python
from mondek_runner import Placement, PlacementContext

OBSERVERS = {
    "staging": frozenset({"shared-east", "shared-west"}),
    "production": frozenset({"shared-west"}),
}

def network_probe_placement(context: PlacementContext) -> str | None:
    allowed = OBSERVERS.get(context.environment.id, frozenset())
    if context.runner.id not in allowed:
        return "This observer is not assigned to this environment's network probes"
    return None

class NetworkProbe(Datasource):
    placement = Placement(
        requires=("network-probes",),
        policy=network_probe_placement,
    )
```

Policies compose with AND and only narrow built-in eligibility. They cannot grant a missing capability, widen a source environment contract or bypass locality. A raised exception or invalid return value rejects discovery instead of converting a broken policy into a successful empty inventory. Policies must be synchronous callables with an inspectable signature accepting one positional context argument. Each call receives separate copies of mutable environment metadata; frozen capability grants and targets can be shared. The framework can detect contradictions in built-in declarations; it cannot prove arbitrary Python policies satisfiable across all possible deployments.

Policy code must be deterministic over declared source and frozen inputs. Do not read live network status, the clock, credentials or undeclared environment variables to decide membership. This is an authoring contract, not a Python sandbox guarantee. A datasource outage belongs to collection and must remain visible. Keep domain abstractions and deployment maps in consumer code; a comprehensive monitoring standard library is not required.

## Placement and failure semantics

`Placement` can be declared on a check, datasource class or datasource factory class. `requires=("local-files",)` asks for named capabilities; `runner_contexts=("node-a",)` optionally restricts execution to named logical contexts. Requirements from all dependencies combine: every capability, context allowlist, supported environment, locality constraint and custom policy must permit the invocation. Contradictory allowlists or source environment contracts reject discovery, even when that check would not run on the current runner. Placement declarations are static source definitions, not mutable execution state.

Capabilities are explicit deployment assertions. Never put credentials in their names, and never derive them from a transient connection test. Eligible checks with an unregistered dependency are configuration errors. Datasource construction happens only during collection; a timeout, missing file or expired credential remains a collection failure rather than removing coverage. Ineligible dependencies need not be registered or constructed. The current limit remains 512 declared instances per consumer, including per-environment expansion; excluded declarations do not circumvent the source bound.

Accepted snapshots freeze the context, scoped capabilities, local environment, default subject, source and declared private settings. Changes to environment variables used to construct the app belong in `construction_environment`, as with other deployment inputs. Failed discovery preserves the previous accepted inventory and executable snapshot. A successful deliberate capability/placement change publishes a complete changed inventory: omitted checks retire with `source_removed`, preserving history without claiming recovery. Restoring coverage creates a new result incarnation. This is not an automatic handoff of an existing incident between two runners.

If two runner installations satisfy the same constraints, both can publish and execute their own instances. Neither a capability nor a shared logical context elects a leader, deduplicates notifications or merges incidents. Pin a check to one intended deployment when a single observer is required; making that deployment redundant needs separate ownership and failover behavior. Duplicate installations of the same logical context remain separate observers.

Local `mondek-runner validate --consumer module:app` shows the selected inventory plus a placement summary explaining exclusions. It cannot prove that some other runner covers the excluded scopes; the controller's [Coverage view](COVERAGE.md) compares accepted declarations and independent measurements across the installation. `run --all` executes that selected inventory; if no checks are eligible, it exits with a clear diagnostic referring back to validation. Existing consumers without a `RunnerContext` retain their previous targets, environment identities and metadata.

## Relationship to the original scheduling strategies

The original Mondek `SchedulingStrategy` protocol combined execution-location restrictions, monitored-environment restrictions, location equality and temporary suppression with cached results. The new declarations cover placement explicitly: context allowlists replace named execution restrictions, source contracts describe supported monitored scopes, scoped capability grants describe deployment access, locality relates execution to the subject, and a policy handles consumer-specific relationships. Cadence and evidence freshness remain separate; no placement outcome reuses an old verdict as a new measurement or skips a due execution temporarily.

The separation is informed by existing monitoring systems. [Sensu proxy checks](https://docs.sensu.io/sensu-go/latest/observability-pipeline/observe-schedule/checks/) distinguish executor subscriptions from reported entities, with a separate round-robin option for selecting one executor. [Icinga command endpoints](https://icinga.com/docs/icinga-2/latest/doc/06-distributed-monitoring/) separate the command's execution endpoint from the monitored host/service. [Checkmk piggyback](https://docs.checkmk.com/latest/en/piggyback.html) lets one collector report other subjects and distinguishes expected missing or stale input. These support the execution/subject distinction; they do not imply equivalent redundancy or dynamic discovery features here.

## Runnable example and verification

The [installed example](../examples/consumers/src/mondek_examples/placement.py) has no explicit Bindings: two node contexts measure their own root filesystems in Production, while one shared observer runs the same service-readiness check separately for Staging and Production.

```sh
devenv shell -- mondek placement
devenv shell -- mondek placement-acceptance
devenv shell -- mondek placement-down
```

The shared observer's access is a scoped grant; `MONDEK_PLACEMENT_HTTP_ENVIRONMENTS=staging` restricts a consumer deployment to Staging while keeping both check declarations in its source. This variable is captured in accepted private construction settings. The persistent demo defaults to both scopes; its node filesystem datasource uses `runner-target` locality.

The persistent demo uses [Checks on port 4013](http://localhost:4013/checks), separate databases and runner volumes, and local HTTP targets/notification delivery. Disk measurements describe the runner containers. Acceptance exercises collection, per-environment failures and recovery, notifications, failed deployment, offline restart/reconnect and deliberate coverage withdrawal/restoration. Normal development volumes are preserved.
