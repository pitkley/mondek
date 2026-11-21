# Controller-backed consumer state

Checks can share small JSON values through the Mondek server. Use this for baselines, peer lists or consumer-specific bookkeeping between executions. This is runtime data, separate from configuration, result evidence and the runner's SQLite journal. It does not elect an executor, coordinate external side effects or skip scheduled checks. Failure sustain is not implemented by this feature.

## Access from a check

The runner injects a typed `CheckContext` by annotation; the argument name is arbitrary. `ctx.state` addresses the executing source's shared namespace. Include environment, target and value-schema identity in keys when they must remain distinct. Two deployments using the same `source_id` intentionally share the source namespace, even when they monitor different environments.

```python
from mondek_runner import CheckContext, Result, StateError, check, ok, unknown

@check(id="peer-health", expected_keys=("peers",))
def peer_health(ctx: CheckContext) -> Result:
    try:
        entry = ctx.state.get("production/peers/v1")
    except StateError:
        return unknown("peers", "Shared peer state is unavailable")
    if entry is None:
        return unknown("peers", "Peer list has not been published")
    # Validate your JSON schema, completeness, scope and acquisition age here.
    return ok("peers", "Peer list loaded", source_at=entry.value["acquired_at"])
```

The example demonstrates transport and original-age handling, not a complete peer-health policy. An empty or malformed list must not silently establish healthy coverage. The writer should store its original acquisition timestamp alongside the raw data. TTL limits storage lifetime; it does not establish measurement freshness. Reading a stored value must not refresh its acquisition age.

| Operation | Meaning |
| --- | --- |
| `get(key)` | Return `StateEntry(value, version, updated_at, expires_at)` or `None` when absent/expired. A stored JSON null is an entry whose `value` is `None`. |
| `put(key, value, ttl_seconds=None)` | Unconditional last-commit-wins replacement; return the committed entry. Omitting TTL clears any old TTL. |
| `compare_and_set(key, expected_version, value, ttl_seconds=None)` | Replace only if the current version matches. The string `"missing"` means create only when logically absent. Raise `StateConflict` otherwise. |
| `delete(key, expected_version=None)` | Unconditional idempotent deletion, or conditional deletion using a concrete version or `"missing"`. |
| `for_check()` | Return the same operations scoped to the current assignment incarnation, including its runner and environment binding. It is assignment-local, not a cross-runner logical-check scope. |

For optimistic baseline initialization, use `ctx.state.compare_and_set(key, "missing", baseline)`. On `StateConflict`, reread and decide using your domain policy; do not blindly overwrite another writer's baseline. Every replacement gets a fresh version, including equal values and TTL changes. Versions are opaque, never numeric counters. Delete/expiry/recreation cannot reuse an old version.

All reads go to the primary database and observe a committed value at the read statement's snapshot. There is no per-execution snapshot or implicit cache. A later read can see another writer's update; CAS detects a stale version. There are no multi-key transactions and no transaction combining a state change with an observation. A successful write persists even if the worker subsequently crashes or its result never arrives.

## Failure and local execution

`StateError` covers unavailability, exhausted execution/call budgets and rejected requests. `StateConflict` and `StateWriteIndeterminate` are subclasses. Consumers may turn these into UNKNOWN, preserving a useful safe summary. Errors contain no stored values or raw private gateway responses.

`StateWriteIndeterminate` means a dispatched mutation may have committed but its response was lost, malformed or otherwise unverified. It is never retried automatically. HTTP failure alone does not prove rollback: only bounded, allowlisted controller rejection codes are treated as definite domain failures. Reread and reconcile intent, or report UNKNOWN. Retrying a concrete old CAS version cannot overwrite a later value, but a conflict cannot prove who wrote it. Expected-missing can succeed again after an intervening creation and deletion/expiry, so it cannot prove the original outcome either.

Controller outages do not stop the scheduler. Checks still execute, state calls fail promptly, and stateless checks continue normally. No state mutations are placed into the observation spool or replayed later.

Discovery, signature validation and preparation perform no state I/O. Standalone `mondek-runner run` has no admitted controller session: injected state is explicitly unavailable even if controller environment variables exist. Tests can directly call checks with a `CheckContext` wrapping a fake that implements the public `StateStore` protocol. There is no silent local persistent substitute. The initial client is synchronous; calls in async checks block that worker's event loop within its execution deadline.

## Opt in to a stale read

Set `MONDEK_CONSUMER_STATE_CACHE=true` on the runner to allow a private local read cache. Call `read_state(ctx.state, key, max_age_seconds=60)` in a check that explicitly accepts cached data. It calls the controller first. `FreshState.entry` is the confirmed entry or `None` for a confirmed miss. `StaleState` exposes the earlier value, its original update and expiry timestamps, and the cache age in seconds. It carries no version for a compare-and-set. `StateUnavailable` means a qualifying transport failure occurred and no eligible copy was available. Use the original acquisition time stored in your value when evaluating its freshness as evidence.

Fallback is available for a refused connection, DNS or socket timeout reported by the wire request, or a remote disconnect. Authentication failures, HTTP rejection, malformed replies and exhausted execution budgets still raise `StateError`. The age limit must be positive and at most one day. Expiring entries also use the controller's database-clock sample from their read receipt. An older controller that omits the sample can still serve fresh reads.

The cache holds up to 48 entries in the runner's state directory during one runner session. It is shared by disposable workers and starts empty on restart. An assignment or generation change cannot reuse a previous execution identity's cached entry. A confirmed miss or local mutation invalidates the cached address. An indeterminate mutation or a worker that dies during a write disables fallback for the rest of that runner session. Successful controller requests remain available. Treat the cache directory as persisted consumer data with the same access expectations as the state being read.

## Bounds and expiry

| Limit | Value |
| --- | --- |
| Source ID and key | 1–200 UTF-8 bytes, without control characters |
| Accounted JSON per value | 64 KiB |
| Accounted key/value bytes per source, across both scopes | 1 MiB |
| Physical entries per source, including unswept data | 1,024 |
| JSON nesting depth | 32, with the root at depth zero |
| Optional TTL | Integer seconds, 1–2,592,000 (30 days) |
| Calls per execution | 64, shared across source and assignment-local views |
| Request lifetime | At most five seconds and never beyond the remaining worker deadline |
| Server admission | At most 256 committed state operations per installation in a one-second fixed window |

Server admission counts committed operations, including missing reads and CAS conflicts. Transactions rolled back for domain failures do not consume that counter. This is cooperative load admission, not protection against malicious rejected-request floods; a fixed window also permits bursts across a boundary. Requests use two-second database lock and three-second statement timeouts. Existing HTTP body and worker process/output limits still apply.

Accounting is identical in Python and Elixir: ASCII-escaped JSON string literals, normalized integral numbers, ordinary compact object/array punctuation and a fixed 24-byte reservation for each remaining fractional float. Object order has no effect. The source quota adds the UTF-8 key bytes; fixed metadata is bounded by the entry count. This is not a PostgreSQL disk-size limit. The SDK sends integral floats as their exact Python integer values before encoding, avoiding a changed decimal value in the wire spelling. Integers have at most 4096 decimal digits; nonfinite numbers, duplicate object keys, invalid Unicode and NUL in JSON strings/keys are rejected. Any JSON root is supported, including arrays, scalars and null.

Expiry is computed from database time sampled after acquiring locks. Runtime reads, operator expiry inspection and cleanup use that same database clock, including when the host clock differs. `expires_at <= now` is logically absent, even before physical cleanup. Reads do not renew TTL. Cleanup independently removes at most 1,000 eligible entries per pass and commits source-sized groups without taking monitoring-parent locks. Unswept expired data remains charged until removed; replacing the same expired address can reclaim that address inside its mutation. A new address may temporarily fail quota admission until cleanup catches up. Sweeper ticks run a cleanup pass independently of ordinary history retention.

## Lifetime, inspection and access boundary

Source keys survive source/definition revisions, runner restart, replacement and retirement of one or all source publications. They expire only by TTL or explicit consumer deletion. Use TTL for replaceable inputs and versioned keys for schema changes. Durable baselines without TTL remain within quota and can be inspected when no publisher is active. There is no operator purge or edit action in this version.

Assignment-local keys become inaccessible as soon as their assignment retires. Physical cleanup follows later; a restored or reintroduced check has a new assignment identity and starts empty. The executing runner can access only its own assignment-local view. Source-wide sharing between logical checks uses explicit source keys.

Open **Manage → Consumer state** at `/consumer-state` to filter by source/scope or exact key and inspect escaped current JSON, version, expiry and writer installation/session/assignment/generation. Source-filtered quota usage includes unswept storage. There is no value history. The list omits values; selecting a key fetches its current value. Expired/deleted/retired selected entries show unavailable.

Operator reads are `GET /api/v1/consumer-state` (`source_id`, `scope`, `key`, `page`; 20 metadata rows per page) and `GET /api/v1/consumer-state/:id` for one current value. Runtime calls use `POST /api/v1/runner/state`. Update gateway policies for this additional runner route; operator read routes require their own access policy. `mondek-runner doctor` probes all four runner routes with read-only GET requests and does not establish successful POST admission.

State requests must match an already registered installation, exact session/boot, active source publication, nonretired owned assignment and controller `authorized_generation`. They never register a session, refresh contact or reactivate monitoring. Source names and lifecycle identities provide cooperative admission, not authentication against a malicious client. The existing gateway model does not provide source-specific credentials or isolation between mutually untrusted runners. Such deployments need a separate authenticated principal/grant design first.

Do not store secrets. Values are operator-visible persisted data and appear in database backups. Routine state route parameter logging and state payload SQL logging are disabled. Values are not added to configuration Git, snapshots, MCP, notification payloads or default error diagnostics. Expiry/deletion is not secure erasure of backups or database pages. Consumer code remains trusted code and can explicitly emit whatever it reads.

## Publish a baseline larger than one value

For a large degraded-queue baseline, store immutable shards under a fresh generation ID and publish one manifest through CAS. Freeze the original acquisition time, row count and digest of the canonical contents as part of the baseline. Each shard has a distinct versioned key and uses create-if-absent. After every shard is confirmed, CAS the manifest using the version read before staging, or `"missing"` for initialization. The manifest names the exact shard keys in order. Readers fetch it once and verify the complete generation against its count and digest before using the data. If a shard is absent or corrupt, reread the manifest and retry within the execution budget or report UNKNOWN. Preserve the original acquisition age.

A competing writer stages under a different generation ID. Only one writer can publish against a given manifest version. After `StateWriteIndeterminate` on publication, reread the manifest and compare it with the intended generation. A match proves that generation is currently published. A later generation may already have superseded an earlier successful publication. If the original expected version is still current, leave the shards in place while that request might still commit. Keep durable shards and manifests without TTL.

Budget the aggregate namespace for the active baseline, any retained predecessor, concurrent stages and interrupted writes. An isolated PostgreSQL and HTTP trial uses 600 synthetic degraded queues with original timestamps and prior/current measurements. The unsharded value accounts for 159,911 bytes. Four 150-row shards are about 40 KB each. The test checks actual namespace charges with four full generations plus one interrupted shard, two competing CAS writers, a dropped reply after manifest commit, and exact deletion of abandoned entries. Run the fixture with `PGPORT=55433 mix test test/mondek/consumer_state_http_test.exs` from `controller/` in the development shell with the isolated test database and runner dependencies ready. A successful read uses five state calls, one manifest and four shards. A publication uses six, one manifest read, four shard writes and one manifest CAS. Allow headroom for verification, retries or cleanup inside the 64-call and execution-time budgets.

A writer can conditionally delete its own staged versions after a definite conflict on its first publication attempt. A conflict following an indeterminate attempt can mean that attempt already published the same shards. Leave cleanup of such stages to a quiescent inventory pass. Keep old published generations for the possible reader lifetime, or allow readers of retired generations to restart from the current manifest. For crash leftovers, quiesce writers and wait for their dispatched writes to resolve, then use the source-filtered operator inventory to identify abandoned keys. Pass the exact keys and versions to an authorized maintenance consumer and retain the current generation and any still needed by readers. Operators can inspect usage and identify keys through the inventory. Mutations use the admitted consumer API.

## Packaged verification

See [packaged state qualification](CONSUMER-STATE-PACKAGED-QUALIFICATION.md) for the focused upgrade/restart/HTTPS-gateway harness, exact tested artifacts, retained evidence and remaining deployment limits.
