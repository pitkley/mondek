# Related failures and shared incident controls

Consumer code can explicitly declare equivalent failures as one shared incident while each result keeps its own evidence and controls. This guide explains condition identity, acknowledgement scope and notification behavior; [the acceptance guide](../tests/e2e/README.md) describes the real-service scenarios.

## Declare equivalent evidence, not a dependency graph

An optional `Condition(key, label, namespace=None)` on an `Output` identifies the problem that the result measures. Its exact identity is namespace, key and the assignment's monitored environment. The namespace defaults to the consumer source; unrelated projects cannot group by a coincidentally matching key. Cross-source equivalence requires an explicitly shared namespace. A missing environment is exact, never a wildcard.

Condition identity is independent of the measured target: a Linux volume and an Elasticsearch service can describe the same storage-pressure condition while retaining different targets. Names, host grouping, runner location and similar timestamps establish no relationship. Authors must include the resource identity in their condition key when different resources should have separate incidents. Ordinary checks omit this declaration and keep their existing behavior.

Use stable, optional `Impact(key, label)` values on results to declare material consequences such as blocked writes. Identity drives attention; labels, summaries and details explain it without creating new attention when wording changes. The SDK does not infer impacts or offer a monitoring standard library. Consumers remain free to build their own abstractions. At most sixteen distinct impacts are accepted per result, independently of the existing bounded details and output limits.

The [installed two-observer example](../examples/consumers/src/mondek_examples/grouped.py) declares the relationship on each output, independently of its target:

```python
from mondek_runner import Condition, Impact, Output, Target, check

STORAGE = Condition(
    "search-volume-pressure", "Search storage capacity", namespace="grouped-example"
)
WRITES_BLOCKED = Impact("writes-blocked", "Search index writes are blocked")

@check(
    id="volume-capacity",
    outputs=(Output(
        "capacity",
        "Search volume used space",
        Target("volume:search-data", "Search data volume", "volume"),
        condition=STORAGE,
    ),),
)
def volume_capacity(source: FixtureData):
    return inspect_sample(source, "capacity", "Search data volume")
```

`FixtureData` and `inspect_sample` are ordinary consumer code in that example. The service-side check declares the same condition on its own service target. Both measurements group only when their monitored environment also matches. A failed result declares a material consequence with `crit("storage", "Search writes are blocked", impacts=(WRITES_BLOCKED,))`; no impact is inferred from its prose. `Result`, `warn`, `crit`, `unknown` and `ResultBuilder` support explicit impacts; healthy results cannot declare failure impacts. The controller receives metadata and evidence, never Python code.

## Try the independent observers locally

```sh
devenv shell -- mondek grouped
devenv shell -- mondek grouped-acceptance
devenv shell -- python3 tests/browser/run.py --suite grouped
```

The persistent demo is at [localhost:4015](http://localhost:4015/incidents), with two installed consumer runners and an owned HTTP measurement fixture. It demonstrates independent Linux-volume and Elasticsearch observations; it does not contact a real Elasticsearch cluster or inspect a host disk. POST JSON to `http://localhost:58095/mode` to set `grouped_samples`: `node-a/volume` and `service-a/elasticsearch` each accept `used_percent`, `writes_blocked`, `available` and `sample_age_seconds`. Set `used_percent` to 96 for Critical or 92 for Warning; restore 40 and `writes_blocked: false` for recovery. Reads retain their supplied measurement age. `devenv shell -- mondek grouped-down` retains all demo volumes.

For example, use devenv's curl to make only the volume report a failure:

```sh
devenv shell -- curl -fsS -H 'Content-Type: application/json' \
  --data '{"grouped_samples":{"node-a/volume":{"used_percent":96}}}' \
  http://localhost:58095/mode
```

## Keep one incident with independent contributions

Retain the existing per-result incident episodes as contributions, with their original IDs, observations, configuration generations, measured times, receipt times, severity, explanation and controls. An explicitly shared condition gets a separate operator incident episode; no first contributor becomes its permanent owner. One contribution belongs to at most one such episode. Existing standalone history is not retrospectively reparented.

The shared incident stays open while any contribution retains an unresolved measured failure. An OK from one observer cannot override another observer's failure, and stale or unavailable collection cannot establish recovery. The page must distinguish current measured severity from freshness and notification eligibility. Healthy observations of the same declared condition remain useful contradictory evidence without voting away failures.

When all failure contributions end, close the shared episode. Call it measured recovery only when the relevant failures actually recovered under their recovery contracts; source removal, changed configuration and relationship reclassification have explicit terminal reasons. A later failure starts a new episode with no inherited acknowledgement. Record contribution recovery, return and withdrawal in history even when they do not change aggregate attention.

Changing a condition namespace/key or removing its declaration reclassifies that output into a new result stream under the accepted source generation. Preserve the old stream, contribution, controls, notifications and association; link the replacement through the same assignment/output identity. Labels alone do not reclassify. Never transfer acknowledgement through a matching label, and never let a late report adopt a newer relationship than the configuration that authorized it.

## Acknowledge the condition episode

One shared acknowledgement records the reviewed episode/revision, severity ceiling, material-impact keys, operator, note and lifetime. Contributor rows derive coverage from this record; there are no copied controls to drift apart. Existing individual acknowledgements remain scoped to their original contribution episodes. Ending the shared acknowledgement leaves those controls and every maintenance window intact.

| Timeline | Behavior |
| --- | --- |
| Linux CRIT, then equivalent ES CRIT | One shared incident with two independent contributions. |
| Acknowledge Linux evidence, then delayed ES corroboration | Covered when severity and impacts remain within the acknowledged scope. Arrival order does not establish onset. |
| First ES sample is measured after acknowledgement | Still corroboration of the explicitly declared ongoing condition; its sample time does not prove a new physical failure. |
| One contributor recovers and returns while another remains failing | Record the return within the same shared episode; acknowledgement remains covered within its ceiling/impacts. |
| Acknowledge WARN, then observe CRIT | End acknowledgement irreversibly and request renewed attention. |
| Acknowledge CRIT, then declare `writes-blocked` | New material impact ends acknowledgement even though severity is unchanged. Removing that impact does not revive the ended control. |
| All contributions recover, then one fails again | New shared episode, with no inherited acknowledgement or delivery budget. |

A known contributor's OK-to-failure transition does not prove the shared condition ended while another contributor remained failing. Treating that return as a new acknowledged episode would contradict the existing downgrade/rebound-within-ceiling policy. If two failures need independent lifetimes, the author should not declare them equivalent. Timestamps are labelled as measured evidence and detection/receipt; the controller does not invent physical onset.

## Investigate the shared incident

The incident list shows one row per shared episode. A runner or target filter finds matching contributors while retaining the whole incident's severity and membership count. Open the incident to see its current condition, material impacts and notification holds, followed by each contribution's own measurement and evidence state. The acknowledgement shortcut reaches the control directly; at narrow widths the evidence comes before the controls. A closed contribution labels its previous severity as Last failure and shows its closing evidence separately.

Use Without active holds to locate failures outside both acknowledgements and maintenance. Recovered & withdrawn preserves earlier contribution episodes, including repeated returns while a peer stayed failed. Contribution pages are bounded at twenty-five rows and do not discard an unsaved acknowledgement draft. A result's individual acknowledgement remains available through its evidence link; that page links back to the shared incident. It shows the contribution's retained opening, latest and closing measurements separately from recent executions, so later failures do not replace its history. Notifications and delivery attempts belong to the shared incident and are reached through an explicit history link.

Last confirmed healthy evidence includes peers whose last measurement was healthy even when collection has since become stale or unavailable. It cannot establish recovery for a failing peer. Notification history identifies the exact severity or named impact each occurrence requests; a receiver's accepted response is delivery evidence, not a claim that a person read it. The coding-agent prompt includes shared condition identity and asks the agent to inspect independent contributions without choosing a first result as the owner.

## Maintenance and notification facts

Maintenance is evaluated per contribution with the existing check and exact-target scopes. A shared incident can be partly maintained. Show which failures remain uncovered; never infer that a hold on one member covers its peers. A maintained member's new material impact still ends the shared acknowledgement, which can expose an unchanged unmaintained contribution. Explain both facts rather than showing a blanket maintained badge.

Notification eligibility must match the severity and impact facts in its immutable payload. An uncovered WARN cannot authorize a CRIT or blocked-writes notification supported only by a maintained contributor. Nor may that maintained CRIT automatically supersede still-relevant unheld WARN work. Equivalent corroboration must add evidence without allocating a fresh delivery budget. Hold changes wake existing work, preserving identity, payload, destination and attempts; they do not manufacture a new occurrence.

Persist separate lifetimes for warning/critical severity thresholds and each stable impact key. Each lifetime can allocate one immutable occurrence. An impact occurrence requests only its named impact; the group's severity at creation is context, not authority to send an unrelated critical alert. A warning occurrence waits while an eligible critical occurrence has a live retry budget, but keeps its own identity and budget. Accepted critical delivery covers only the exact warning lifetime captured when that critical occurrence was created. A newly opened episode is never covered by an older receipt.

Changing holds or adding equivalent evidence wakes existing work without creating another occurrence. Ending acknowledgement can expose pending unmaintained work; it does not resend an already delivered fact or replenish an exhausted budget. A maintained new impact remains held even when it ends the shared acknowledgement. A completely held episode ends without a misleading recovery notification; prior attempted failure delivery keeps its existing terminal eligibility.

Reduce all outputs from one observation together, then preserve the order of separate reports even when transported in one envelope. For example, a single observation moving failure between two equivalent outputs keeps the condition open; a complete recovery report followed by a failure report starts a new episode. Pass the actual closing observation through reduction rather than guessing it from receipt timestamps, which can be identical across buffered reports. Complete inventory retirement is one separate atomic membership change.

Condition mutations acquire one of 256 deterministic advisory-lock stripes after assignment locks and before contribution/occurrence rows. Sort the actual stripe IDs before acquiring multiple locks. This bounds database lock use for large inventories; unrelated identities sharing a stripe may wait for each other but never share state. Notification completion and maintenance gate edits use the same condition-before-occurrence order. External delivery runs outside these transactions.

## Verification gates

The implementation must cover concurrent first arrivals, both arrival orders, late corroboration, above-ceiling severity, new impacts at unchanged severity, partial/conflicting recovery, stale collection, recurrence, source withdrawal and relationship changes. Control cases include individual plus shared acknowledgements, overlapping target/check/bulk maintenance, maintained CRIT with uncovered WARN, and a maintained new impact invalidating a shared acknowledgement.

Real installed runners and local webhook receipts must verify grouped delivery and its original identity/budget through controller restart and reconnect. Migration checks preserve existing incidents, controls and jobs. Browser acceptance must show one operator incident, independent contributor evidence, acknowledgement coverage and partial maintenance without hiding uncovered failures. Existing standalone acceptance remains required; no authentication, remediation, observer election or causal inhibition is introduced by this increment.
