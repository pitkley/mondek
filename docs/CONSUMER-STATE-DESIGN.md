# Consumer state and sustained failures: proposed design

Status: state implementation follows [the consumer state contract](CONSUMER-STATE.md); sustain remains a separate design proposal. Original design and review rationale, 2026-11-16. This proposal responds to consumer needs for baselines, shared peer lists and grace timers. It separates durable consumer data from a controller-owned failure sustain policy.

## Recommendation

Add a small PostgreSQL-backed consumer state facility to the controller, accessed synchronously during check execution through a typed SDK context. Use source-wide state for deliberately shared data and an optional assignment-scoped view for assignment-local check bookkeeping. Add failure sustain separately in the controller's evidence reducer, so ordinary grace timers do not require consumer read/modify/write logic. Neither feature elects an executor, skips due checks or makes shared data into new measurement evidence.

Implement state first, then sustain in a separate change. Both fit the existing controller/runner architecture without Redis, another service or a generic workflow layer. Existing consumers remain unchanged unless they request the new context or declare sustain.

## Implementation baseline at design time

- [Protocol](../contracts/v1/protocol.md): runner source inventory, control/session admission, immutable observations, assignment generations and per-output result streams already have explicit identities. Different runner installations remain independent observers of the same source.
- [Worker](../runner/mondek_runner/worker.py) and [authoring](../runner/mondek_runner/authoring.py): each invocation reconstructs accepted code in an isolated process; typed injection already supplies datasources, environments and `RunnerContext`. There is no execution context or consumer state API today. `runner/mondek_runner/state.py` is the internal runner journal, not this proposed facility.
- [Transport](../runner/mondek_runner/transport.py): bounded subprocess HTTP exchanges support origin-bound gateway headers and refuse redirects. Credentials are read at request time rather than stored in snapshots.
- [Authentication](CONTROLLER-AUTH.md): gateway access is a trusted operator boundary, not installation- or source-specific authentication. Installation/session/boot IDs fence cooperative clients; they are not credentials.
- [Lifecycle](OBSERVER-LIFECYCLE.md): retiring one runner/source publication must not retire other publications. Assignment withdrawal and reintroduction create different incarnations. A disconnected runner continues its accepted schedule.
- [Monitoring](../controller/lib/mondek/monitoring.ex) and [conditions](../controller/lib/mondek/conditions.ex): raw observations, confirmed health, collection knowledge and incident contributions are distinct. UNKNOWN, missing and stale output evidence do not establish healthy recovery; valid siblings are reduced independently.

## State identity and lifecycle

Use `(source_id, scope, key)` as the logical address. Source IDs are installation-local namespaces; deployments that reuse a source ID intentionally share its source state. Source state does not implicitly partition by environment or target. Consumers must include those stable identities in their keys when needed; SDK documentation must show this explicitly to avoid Production/Staging collisions.

Two initial scopes:

| Scope | Intended use | Lifetime |
| --- | --- | --- |
| `source` | Baselines and peer lists read or written by any active runner publication of the source | Explicit delete or TTL; remains through temporary absence of all publishers, source revisions, replacement and retirement of one publisher |
| `assignment:<id>` | Bookkeeping local to this scheduled check incarnation | TTL, explicit delete, or retirement of that assignment; reintroduced assignments start empty |

The narrower scope is intentionally per assignment, including its runner and environment binding. It is not a logical check namespace shared across runners. Cross-runner sharing uses source keys, with explicit logical check/environment/target components where appropriate. A shared logical-check scope can be added later if a real consumer requires its more complex lifecycle.

Do not delete shared source data because its writer check retires: another check or publication may still need it. Recommend TTL for replaceable shared inputs; durable baselines may omit it. Source keys without TTL survive even when no publications remain, within the source quota, and stay inspectable. An explicit future source purge would need its own reviewed operator action. Assignment retirement immediately makes assignment-local state inaccessible; physical cleanup may follow in bounded batches. Restoration cannot resurrect it.

State schemas belong to consumer code. Use versioned keys or a schema version in values for incompatible consumer changes. A new source or definition revision does not automatically discard a baseline. Simultaneously deployed revisions must cooperate on schema compatibility; no automatic data migration runs on the controller.

## SDK and execution behavior

Proposed public surface, illustrative rather than an implemented API:

```python
from mondek_runner import CheckContext, Result, StateError, check, unknown

@check(id="peer-health", expected_keys=("peers",))
def peer_health(ctx: CheckContext) -> Result:
    try:
        entry = ctx.state.get("production/peers/v1")
    except StateError:
        return unknown("peers", "Shared peer state is unavailable")
    # Validate entry.value and its acquisition time before evaluating peers.
    # A missing entry is distinct from a stored JSON null or an empty list.
```

`ctx.state` is bound to the executing source; `ctx.state.for_check()` returns the current assignment view. The context contains identity and a client, not a new mutable `RunnerContext`. Add type-based injection without reserving the parameter name `ctx`. Existing checks, datasource injection and direct function testing retain their behavior.

Operations:

- `get(key)` returns a tagged missing result or an entry with JSON `value`, opaque `version`, `updated_at` and nullable `expires_at`. Missing and JSON null are distinct.
- `put(key, value, ttl_seconds=None)` is explicitly unconditional last-commit-wins replacement. It returns the committed entry.
- `compare_and_set(key, expected_version, value, ttl_seconds=None)` and conditional `delete` implement optimistic updates. A distinct expected-missing token supports create-if-absent. Conflicts are typed outcomes, not transport failures.
- `delete(key)` is unconditional and idempotent. Successful replacement without TTL clears an old TTL; TTL is relative to database mutation time sampled after lock acquisition, never to a client timestamp; the response is returned after commit. This is not an exact commit-timestamp expiry guarantee. Merely reading never refreshes TTL.

Each read goes to the controller primary and observes a committed value at that statement's snapshot. There is no execution-wide snapshot, preloaded cache or read replica fallback. Concurrent commits after a read can make its version stale; CAS detects that. No multi-key atomic transaction or atomicity between state mutations and observation submission is promised. A successful state write survives even if the check later crashes, emits UNKNOWN or its observation is never delivered.

Use the existing worker boundary and transport helper directly; no bidirectional stdout RPC is needed. Runtime supplies transient execution identity and controller endpoint separately from accepted source snapshots. Every operation receives the lesser of a short request limit and the remaining monotonic execution budget. All transport descendants remain in the worker process group and die with the existing timeout/watchdog. Bound calls per execution as well as bytes; a synchronous client is sufficient initially, with an explicit async facade later if required. Async checks must not assume synchronous HTTP is nonblocking.

Discovery, signature validation and preparation never contact state. An execution-only context placeholder can validate injection. Local `mondek-runner run` has no controller registration, so requesting live state raises an explicit unavailable error; tests inject an in-memory fake implementing the same interface. Do not silently substitute local persistent state or connect local runs to a production controller.

On controller outage, scheduler behavior remains unchanged: checks execute, state operations fail promptly, and consumers can emit UNKNOWN. No offline write queue, journal replay of state mutations or stale-read fallback is included. A result based on cached raw input must retain its original acquisition time in `source_at`; reading shared state cannot refresh measurement age. TTL is storage lifetime, not proof of input freshness. Consumers validate payload schema, scope, age and completeness; an empty peer list cannot automatically mean healthy coverage.

## Concurrency, bounds and ambiguous writes

Use an ordinary `ConsumerState` domain context, state entries and one small source namespace/accounting row in PostgreSQL. Store JSONB, authoritative accounted bytes, expiry and provenance (installation, session, assignment and configuration generation). A unique constraint enforces the logical address. Allocate a fresh opaque version on every successful replacement, including equal values and TTL-only changes. Deleted or expired values cannot reappear with their old version; use nonreused random tokens so delete/expire/recreate cannot pass an old CAS. Expected-missing applies to logical absence at transaction time.

Serialize source accounting and mutations with a source-local row lock; recheck admission, CAS, expiry and quota in one short transaction. Update data and counters atomically. Do not reuse the configuration source advisory lock merely because the namespace is a source: high-frequency data writes should not serialize on the configuration repository journal. Document an explicit lock order with existing runner/publication/assignment locks before implementation; retirement and cleanup must use the same order and revalidate lifecycle while locked. Never hold a transaction over HTTP or Python execution.

Proposed initial limits, to validate against real consumer payloads before freezing the contract: 200 UTF-8 bytes per key, 64 KiB accounted JSON per value, 1 MiB accounted live JSON/key bytes and 1,024 physical entries per source across all scopes, depth 32, 64 state calls per execution, and TTL 1 second to 30 days when supplied. No NaN/infinity, control characters in keys or duplicate object keys. Adopt one precisely specified cross-language JSON byte-accounting rule, using the existing parameter normalization work as a starting point rather than measuring Python bytes and JSONB bytes differently. These are application quotas, not promises about PostgreSQL disk usage.

TTL uses controller/database time sampled after lock waits; `expires_at <= now` is absent immediately, regardless of sweep progress. A bounded independent cleanup pass removes expired and retired assignment-local entries. Keep physical entries bounded and charge unswept storage until reclaimed; an expired same-address entry can be reclaimed inside its mutation transaction. A full source can temporarily reject a new address until cleanup, rather than doing unbounded expiry work inside a request. Bound request/response bodies, JSON complexity, list pages and per-installation operation admission; expired keys and rejected requests must not create unlimited metadata.

A write timeout can mean committed-but-reply-lost. Raise a specific `StateWriteIndeterminate` carrying no value or credentials. Do not automatically retry unconditional writes or claim exactly once. CAS retry with the same concrete old version cannot overwrite a later value, but conflict after a lost reply still cannot prove which writer succeeded. Expected-missing is different: after an intervening create and expiry/delete, it can succeed again and cannot establish the original operation outcome. Consumers reread and reconcile domain intent, or report UNKNOWN. A bounded idempotency-receipt protocol is a possible later addition if a concrete operation needs definitive retry receipts; it is not required to pretend every timeout means rollback.

## Transport, admission and operator access

Propose a separate bounded `POST /api/v1/runner/state` exchange with `version`, operation, source identity and the existing installation/session/boot and assignment/generation identity. A read is a live execution operation, not observation ingestion. It cannot register a new session or revive a publication. Validate that the current session owns an active assignment of that source and matches the controller's `authorized_generation`; reject retired publications, removed assignments and superseded sessions/generations. Clients cannot select an arbitrary assignment for the narrower scope. Allow source-wide keys from any admitted assignment of that source, including readers different from the writer.

Use existing HTTPS headers, redirect refusal, safe diagnostics and transport lifetime limits. Update gateway route guidance and doctor probes for the added endpoint. Crucially, these admission checks are cooperative lifecycle fencing within the existing trusted installation. They do not authenticate a source against a malicious gateway-authorized caller who can invent identities. The initial release must state that limitation explicitly. If mutually untrusted sources/runners need isolation, first add authenticated principal-to-installation/source grants and operator permissions; source_id alone is never a security boundary.

Add paged read-only operator inspection under a dedicated consumer-state resource, with source/scope/key filters, quota usage, timestamps, expiry, version and writer attribution. UI renders escaped JSON, handles 64 KiB values deliberately and distinguishes missing/expired/current data. Operator credentials and gateway policy remain separate from runner route access. Do not expose state values by default in overview snapshots, logs, notifications, MCP, configuration exports/Git or worker diagnostics. No secrets belong in state, but values may still reveal internal topology. There is no promise of automatic secret detection or value history. Backups include live state; expiry is not secure erasure.

## Separate feature: per-output sustained failure

Add a source-owned `sustain_seconds` to output metadata, default zero, with a concrete finite bound (propose 0–86,400 seconds). Existing shorthand outputs default to zero. Do not put duration into each result or require checks to preserve timers. A future delegated operator policy needs explicit configuration ownership and journalling; this proposal keeps v1 source-owned.

Keep immutable reported health and collection evidence exactly as received. Introduce a separate durable per-stream qualification projection and effective incident state. During a pending failure, the UI says e.g. `CRIT reported; pending 30 s sustain`, with raw evidence accessible. Never manufacture an OK observation while a timer runs. If no previously qualified health exists, the qualification state is pending, not healthy. Existing qualified failure incidents stay open until measured recovery or their normal administrative closure; a pending severity escalation cannot silently downgrade them.

For a single duration N, track continuity independently at the WARN-or-worse and CRIT thresholds. WARN→CRIT retains elapsed WARN qualification but begins a CRIT timer; CRIT→WARN resets CRIT qualification, while WARN continuity survives. An already qualified CRIT downgrades immediately on a fresh WARN measurement to qualified WARN. A fresh OK for this output resets candidates and establishes immediate recovery. Zero preserves current behavior.

Only fresh, currently admitted, newly advancing measured evidence for that output can start or advance candidates. Completeness is per output: a valid sibling result advances normally even if the overall execution is incomplete. A missing or UNKNOWN result for this output, stale evidence, a freshness gap, session change, configuration generation change, retirement or changed stream identity breaks unqualified continuity. UNKNOWN and gaps retain previously qualified health/incidents under today's uncertainty rules; they do not recover them or advance escalation timers. Scope timers to the stream incarnation and active generation; runner replacement never transfers them. Pending timers survive controller restart in PostgreSQL. Persist the candidate start and latest observation identities, source and receipt times, threshold, policy/generation/session identity and bounded continuity metadata; protect referenced evidence during retention while needed for current qualification. Do not imply a full historical proof if intermediate receipts have expired.

Define duration conservatively as observed continuity, not proof about the unmeasured interval. Require each selected result's non-null `source_at` to strictly advance; evaluation time alone cannot substitute. Before advancing a candidate, the new receipt must precede the prior sample's `source_at + freshness_seconds`, with equality breaking continuity, and the new sample must satisfy the existing freshness validator. Repeated/regressed source time or regressed controller receipt time resets the candidate. After a reset, a fresh failure may start a new candidate. Require both controller receipt span and original `source_at` span from candidate start to reach N, so a fast backlog replay cannot qualify an alarm and repeatedly reused cached input cannot advance a timer. Duplicates, historical/fenced observations and sweeper ticks never advance qualification. A fresh qualifying measurement at or beyond N is required; merely waiting after one failure cannot create an incident. Carry these exact boundaries into protocol vectors before coding; a controller clock discontinuity cannot prove elapsed continuity.

Apply the qualification projection consistently to individual incidents, shared-condition contributions, acknowledgement escalation and notification eligibility. Raw measurement remains visible for debugging and the Measured configuration milestone; qualified health must retain its own supporting observation identity. Pending outputs do not contribute a qualified failure to shared incidents. Existing qualified failures persist through unavailable evidence. Sustain qualifies output severity, not individual impact duration. Once that severity qualifies, fresh evidence can update impact membership immediately under the existing new-impact acknowledgement and notification rules. A newly appearing impact on an already qualified output may therefore notify immediately; no claim is made that it persisted for N. During pending escalation or unavailable evidence, preserve the last qualified contribution and its provenance. Per-impact dwell is a separate feature; use separate outputs or consumer logic when it is required.

This touches more than notification delay. Using only a notification gate would leave incidents and UI immediately critical, which is a different feature. Consumer-specific grace rules (particular error categories, per-item timers, business calendars) may still need shared state; a generic sustain period does not replace those semantics.

## Implementation sequence and acceptance

1. Specify state contract and bounds, missing/null representation, error types, expiry/CAS semantics, admission and trusted-boundary limitations. Add shared Python/Elixir vectors and generated HTTP declarations. Verify actual peer-list/baseline payload sizes before settling quotas.
2. Add migration and `ConsumerState` context with atomic accounting, unique addresses, nonreused versions, lifecycle fences and bounded cleanup. Update lock and startup-migration/upgrade guidance. Consumer state is runtime data, excluded from configuration Git and observation replay.
3. Add typed SDK client/context, execution-only injection, bounded worker transport and explicit local unavailability. Preserve snapshot hashes and journals unless an intentional documented extension requires a coordinated change. Add read-only API/UI inspection and gateway/doctor documentation.
4. Qualify state using controlled concurrent PostgreSQL writers: one winning CAS/create, quota races, delete/expiry/recreate, null versus missing, retirement/session/activation races, and source sharing across two real installed runners. Use isolated HTTP/service tests for timeout, commit/reply loss, controller restart, offline execution, worker cancellation and original cached-input age. Walk the actual inspection UI at desktop/narrow widths and use shared-body parity tests if both fly-over and full detail routes are added.
5. Separately specify and implement sustain projection, metadata/generation integration and incident/condition reduction. Test exact duration/freshness boundaries, WARN↔CRIT, UNKNOWN/partial/stale/clock regression, replay bursts, duplicate IDs, generation change, restart and independently observed shared conditions. Exercise real notification delivery only against isolated test receivers.
6. Update SDK, protocol, API boundaries, retention, operator, authentication, multi-environment acquisition and upgrade guides with the implementation. Run focused native/installed-package checks and the relevant acceptance suites from [the coverage map](ACCEPTANCE-COVERAGE.md); avoid unrelated full CI runs.

## Review and remaining decisions

Reviewed with a separate GPT-6 Astra agent on 2026-11-16 against the current authentication, lifecycle, worker, per-output reducer and condition code. Its assessment was that the overall design is sound. All four requested corrections are incorporated: per-output completeness, mutation-time TTL, strictly advancing original source timestamps with explicit freshness boundaries, and output-severity-only sustain with explicit immediate new-impact behavior. Additional clarifications cover controller-authorized generations, session resets, expected-missing retry ambiguity, assignment-local naming and retained qualification evidence. The review was a design review, not implementation or runtime validation.

Implementation must settle JSON accounting, quota defaults from real payloads, exact lock/foreign-key ordering, concrete HTTP/error DTOs, and protocol encoding of the specified sustain timestamp/impact rules before code is merged. These are bounded implementation design decisions, not authorization to add leadership, cross-key transactions, offline mutation replay, arbitrary operator editing or a general state database.

## State implementation review and local verification

The state-only implementation was reviewed throughout and at completion by a separate GPT-6 Astra agent. Final assessment: no remaining correctness blockers. Review corrections included first-namespace/delete linearization, exact integral-float wire normalization, DEL/non-BMP JSON accounting, ambiguous HTTP timeout handling, cross-installation contention coverage and database-clock consistency across expiry inspection/cleanup. Sustain remains unimplemented.

Local verification on 2026-11-16: the full native controller suite passed 985 tests before final localized review corrections; the affected state/API/real-worker suite then passed all 17 tests, with 16 domain/UI tests passing again after the final pagination cleanup. The full runner suite passed 335 tests, followed by the final six state tests and ten HTTPS/auth tests. The 78 harness and 101 installed-example tests passed. `mondek check`, generated API freshness, native formatters, Ruff and installed SDK typing passed. Two separate runners using a built/installed SDK wheel passed real HTTP sharing, assignment isolation, committed lost-response, state outage/recovery and worker-crash scenarios. Restarting the task's complete local controller preserved all five synthetic state entry IDs and versions. A real browser walkthrough verified key filtering, selected JSON/provenance and desktop/390px/320px layouts without horizontal document overflow.

These are local native/service and installed-wheel results, not a packaged controller-image, hosted gateway or production deployment qualification. All fixtures used task-owned synthetic data and an isolated PostgreSQL Compose project. No branch, image, SDK artifact or release was pushed or published.
