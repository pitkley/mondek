# Declared coverage and placement auditing

## Operator flow

Open **Coverage → Intended results** to compare what your code declares with actual measurements, including checks that every runner excludes. Each row represents one intended result for a target and monitored environment. Search or filter by source, monitored environment and coverage state. Open a result to see each declaring runner's placement decision, exclusion reason, measurement state and result/configuration links. A runner filter selects relevant declarations while retaining all observers in their counts. Fresh evidence and healthy results are different: a fresh Critical measurement establishes observation coverage while its incident still needs attention.

**Runner declarations** shows each runner's source publication, execution environment, coverage support, last contact and accepted code/runtime identities. One runner may have more than one source publication. **Unresolved declarations** explains templates whose environment or target cannot be established, including excluded checks whose custom metadata cannot provide an authoritative scope. Missing metadata from an older SDK means coverage cannot be assessed; a supported complete empty catalogue explicitly declares no checks. Downgraded publishers retain their last-known declarations with an unconfirmed status. Locality exclusions name both the required monitored environment and the runner's actual execution environment; shared-service checks may intentionally monitor other environments.

The page includes a copyable investigation prompt. Changes belong in consumer code or runner deployment settings. Mondek does not create checks from this view, execute the prompt or infer a preferred observer.

## Explicit node rosters

Ordinary inherited targets need no extra declarations. When the monitoring project knows an intended fleet, use the existing `Binding` API to publish it before placement filtering:

```python
checks = [
    Binding(
        root_disk,
        key=f"root-disk-{node}",
        target=target,
        environment=PRODUCTION,
    )
    for node, target in ROSTER.items()
]
```

The check's datasource uses `Placement(requires=("local-files",), locality="runner-target")`. Each runner selects only its own node and publishes exclusions for the others. Node A therefore declares Node B even before B has a runner. The complete runnable example is [coverage.py](../examples/consumers/src/mondek_examples/coverage.py); it also declares a shared service in Staging and Production, with separate access grants and independent observers. This demonstration reads owned HTTP fixture measurements representing node and service data, through real installed workers and the controller. For actual filesystem inspection, see the existing [placement example](../examples/consumers/src/mondek_examples/placement.py).

Run `devenv shell -- mondek coverage` for the isolated persistent demonstration, then open [Coverage](http://localhost:4016/coverage). Its initial gaps are deliberate: Node B is not installed, and both service observers initially have access only to Staging. `mondek coverage-down` retains the demo's volumes. `devenv shell -- mondek coverage-acceptance` restores those gaps and exercises failure, recovery, source changes and reconnect in a separate disposable project. The browser journey runs with `devenv shell -- python3 tests/browser/run.py --suite coverage`.

To restore both gaps in the persistent demo, start Node B and give service observer A the demo's Production capability:

```sh
devenv shell -- env MONDEK_PORT=4016 MONDEK_FIXTURE_PORT=58096 PGPORT=55446 \
  MONDEK_COVERAGE_ACCESS_A=staging,production \
  docker compose -p mondek-coverage -f compose.yaml -f examples/compose/coverage.yaml \
  --profile restore-node-b up --build --detach --wait --wait-timeout 180 \
  coverage-node-a coverage-node-b coverage-service-a coverage-service-b
```

Keep the same deployment overrides on subsequent Compose updates. This declares what the observer can access; capabilities do not grant operating-system or database permissions. Coverage changes only after the installed runners publish their declarations and collect fresh desired-version evidence. The new node also contributes its inherited node-local collection scope, bringing the demo from five concrete scopes to six.

## Product contract

Coverage compares published source declarations with placement decisions and fresh measurements. It does not infer a complete fleet from the runners currently online. A concrete declaration remains visible when every observer excludes it. A fresh Critical measurement establishes observation coverage while retaining Critical health; a heartbeat, acknowledgement, maintenance window or retained verdict cannot establish coverage.

The exact scope is source ID, scheduled check key, result key, monitored environment and target kind/key. Existing custom metadata may explicitly use a null environment with concrete targets; this is the distinct Unscoped namespace, not a wildcard or an unresolved inherited template. Labels, runner location, logical context, a shared condition or target identity alone do not make two scopes equivalent. Every selected observer keeps its own assignment, result incarnation, configuration and evidence. Aggregate placement and measurement counts only after matching each declaration to that publisher's exact accepted assignment/result.

One source can run on many deployments with different private connection settings. Its current executable `source_revision` includes installation-private settings identity and selected metadata, so it is not a comparable package revision. Publish a separate package-code fingerprint from the entrypoint and snapshotted package files, and a separate runtime fingerprint. Neither includes private provider settings. Public declaration fingerprints expose different source defaults/contracts without inventing a globally authoritative release or ordering opaque hashes.

## Intent and completeness

Each complete accepted inventory replaces only its publisher's declarations. Failed discovery, rejected inventories, transport loss and elapsed time retain the previous accepted catalogue. One deployment removing a check cannot silently withdraw another deployment's declaration. Show who still declares a scope, their last contact and their package/declaration differences. Declaring no candidates in a supported catalogue is an explicit empty publication; an older runner omitting catalogue support is unknown, not empty. After downgrade, preserve previous declarations as last known and unconfirmed until a supported publication replaces them.

Checks inheriting the executing node's subject describe known deployments. A project that must detect a never-installed node can provide a common explicit roster using existing `Binding` targets and environments with `runner-target` locality. Node A then publishes Node B's concrete declaration even though A excludes it. No separate SDK expectation list is needed. A subject-less shared runner may legitimately exclude a local check before resolving its environment/target; retain that template as unbound diagnostic context, without inventing a monitored scope. Projects or targets never declared by any publisher remain unknown.

## Versioned inventory extension

Add optional `coverage` to the complete inventory. Version 1 contains `version`, `code_revision`, `runtime_revision`, `runner_context` and `candidates`. The context contains public `id`, `label`, `local_environment`, `target` and capability declarations. A candidate contains `key`, `label`, `selected`, `exclusion_reason`, `environment`, `environment_label`, `scope_resolved`, `scope_reason`, public `definition_revision` and `outputs`; each output contains `key`, `label` and an exact target or null when unbound. Candidate keys include existing stable environment expansion and must never be parsed to reconstruct identity.

Selected candidates correspond exactly to executable inventory checks, including their environment and output identities/targets. Excluded candidates do not require provider registration or datasource construction. A selected candidate cannot be unbound or carry an exclusion reason. All candidates remain within the existing 512-check and sixteen-output limits and the complete request remains bounded at 4 MiB. Reject malformed or incomplete declarations atomically; never silently truncate a complete catalogue. Unknown required catalogue versions reject publication without changing accepted monitoring.

Include catalogue semantics in inventory replay/conflict checks, the durable runner inventory revision and authenticated snapshot manifest. Ordinary selected workers with authenticated registration metadata reuse the complete catalogue generated during discovery rather than re-evaluating every excluded candidate. Custom `App.metadata` overrides retain full validation, including catalogue recomputation; older manifests retain their existing validation path. Keep private construction settings and credentials out of public catalogues and fingerprints.

## Persistence and inspection

Retain accepted catalogue metadata on `SourceInventory`, including the inventory/source revision that confirmed it, and materialize one current declaration per candidate output. Scope identity and a uniqueness constraint support bounded SQL grouping and pagination. Reconcile the declaration rows inside the same transaction as executable membership, after validating the whole proposal. Declaration persistence must not become a second scheduling or incident owner.

The installation view starts with resolved declarations, including excluded ones, then counts declaring reporters, selected observers, admitted results and measurement states. An observer only establishes fresh desired coverage when its current admitted result comes from the exact desired configuration/source revision and current session, with fresh source evidence. Fresh old-authority evidence during a pending deployment is shown separately. An unavailable or stale execution cannot borrow the retained verdict's health to claim current coverage. Selected-but-skipped legacy adoption remains explicitly unadmitted. Controller contact is shown independently: a recent heartbeat cannot create a measurement, and a contact gap cannot prematurely expire evidence that remains within its declared freshness interval. Reconnection still requires evidence from the current session.

Present one scope row with complete counts, then bounded observer detail showing current selection/exclusion, contact, adoption and evidence links. Multiple selected observers are legitimate; disclose partial visibility without electing a preferred observer. Filters identify relevant scopes while preserving their installation-wide observer counts. Package/declaration differences and unsupported or unconfirmed catalogues remain visible rather than being collapsed into a green completeness claim. Existing Checks and incident pages retain their independent evidence semantics.

The Coverage page offers inspection and source/deployment guidance. Missing placement leads to code and runner deployment actions, not a form for creating checks. Existing measurement summaries describe published results, while Coverage describes declared scopes. From Publishing runners, review [retirement or replacement](OBSERVER-LIFECYCLE.md) for a permanently lost publication. Retired catalogues remain inspectable but no longer declare active coverage; restoration waits for a newly discovered inventory and fresh evidence. Declarations never expire automatically.

## Acceptance requirements

- Publish a concrete Staging/Production declaration from multiple deployments while none selects Production; display the missing scope and exact exclusion reasons, then restore a suitable observer and require its current desired measurement.
- Publish an explicit node roster from Node A only; Node B must be visible before it ever registers. Preserve inherited local-template diagnostics without fabricating unknown node targets.
- Show independent duplicate observers and partial visibility. A fresh Critical observation is measured coverage; stale, unavailable, old-session, unadmitted or pending-generation observations are not. Display contact gaps independently of measurement age. One observer's recovery cannot rewrite another's incident.
- Preserve the complete catalogue through failed discovery, rejected updates, replay, controller/runner restart and actual reconnect. Complete source withdrawal removes only its reporter's claims; another reporter's declaration keeps the scope visible. Unsupported/downgraded reporters remain explicitly unknown or unconfirmed.
- Separate package code, runtime and public declaration differences from expected private deployment differences. Paginate hundreds of scopes and observer declarations with complete filtered counts and bounded queries.
- Complete independent source/concept/UX reviews, native temporal/concurrency/validation regressions, real installed-runner/local-service acceptance and a browser walkthrough. Upgrade existing local installations without changing identities, parameters, incident/control history or sibling repositories.
