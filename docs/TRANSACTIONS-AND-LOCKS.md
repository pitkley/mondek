# Transactions and locks

This is the controller mutation contract, traced from the current implementation for TD-02. It documents existing behavior; it does not introduce a locking framework or prove the absence of every possible deadlock. PostgreSQL transactions, row locks, advisory locks and constraints together protect authority, replay and durable delivery. Read-only inspection snapshots are not permission to mutate those rows.

## Ownership and ordering

Transaction entry points below own `Repo.transaction/1`. Helpers participate in their caller's transaction; calling a transaction-scoped advisory-lock helper outside a transaction releases its lock at the end of that SQL statement and provides no protection for later work. `Monitoring.change/2` is only a write primitive, not an authorized mutation boundary. Nested `Repo.transaction/1` calls do not create independently committed work.

The order is a partial order, not a requirement to acquire every lock for every operation. Acquire an operation's complete set of assignments and condition identities before reducing any member. Re-entering an already held lock is different from discovering a new lock after reduction has started. Ingestion reduces reports in their original order after acquiring batch ownership; sorting locks must not sort evidence or merge measured recovery and subsequent failure.

| Lock/domain | Rule when used together | Implementation |
| --- | --- | --- |
| Configuration repository, advisory `774020` | Outermost for configuration writers, inventory reconciliation and policy planning. Before catalogue/source/runner/assignment locks. Never enter a journalled writer while already holding a lower lock. Unrelated measurement ingestion does not take it. | `ConfigurationRepository.transaction/2`, `accept_push/2`, `lock!/0` |
| Maintenance gate, advisory `774009` | First for maintenance edits, dispatch admission, monitoring sweeps and retention. Edits take exclusive; readers of a delivery gate take shared. Do not acquire it after assignment/condition/loss locks. | `Maintenance.lock!/1` |
| Configuration catalog, advisory `774008` | Rule/policy catalog mutations take it before source locks. Other mutations do not require the catalog lock. | `ConfigurationRules`, `ConfigurationPolicy` |
| Source namespace, hashed advisory bigint | Before runner/publication/assignment locks. Multi-source operations sort distinct source IDs before locking. | `ConfigurationRules.lock_source!/1` |
| Registration, advisory `774002` | Registration takes it before the runner row; inventory already holds its source namespace. | `Monitoring.register_runner/2` |
| Runner row | `FOR NO KEY UPDATE`, ordered by ID for batches, before publication and assignment rows. This fences competing sessions and shared runner capacity without blocking foreign-key key-share checks. | Control, ingestion, inventory, configuration, publisher lifecycle |
| Source publication row | `FOR UPDATE`, ordered by ID for publisher pairs; before its assignments. | `Inventory`, `PublisherLifecycle` |
| Assignment row | `FOR UPDATE`, ascending ID for batches. Before condition identities. | `Monitoring.lock_assignment/1` and batch queries |
| Measured-condition identity | Advisory `(931741, stripe)` with distinct stripes sorted ascending, at most 256. Lock the union of outgoing and incoming identities before changing contributions. Hash collisions serialize unrelated identities without merging them. | `Conditions.lock_keys!/1`, `Monitoring.lock_condition_streams!/2` |
| Monitoring-loss domain, advisory `774015` | After any required runner/assignment/condition locks. Never acquire a new lock in those domains afterward. Its readers inspect committed projections without subsequently locking their runner/assignment rows. | `MonitoringLoss.lock!/0` |
| Owned detail rows | Streams, incidents, facts, occurrences and attempts are written under their owning assignment, condition or loss domain. Explicit occurrence locking follows its delivery context. Updates, foreign keys and cascades also acquire locks even without a `lock:` query option. | Reducers, controls, delivery and retention |

There is no universal “all occurrences after loss” rule: maintenance updates health occurrence gate revisions before taking the loss lock, then updates monitoring occurrences; ingestion may hold loss serialization while processing a later report whose assignment and condition stripes are already held. These are separate ownership domains. Do not extend either path to acquire another domain's parent lock late.

Legacy setup/creation uses advisory `774001` to serialize sample installation and its active-count bound. That path does not replace the runner/source/condition ordering for source-owned checks.

Configuration journal wrappers encompass setup/creation, inventory, individual/bulk saves, rule edits/deletion, exception reset and policy apply. The entry-point rows below describe their inner domain locks; the repository lock comes first. Policy planning takes it before its catalogue/source snapshot so its reviewed Git baseline is coherent. Snapshot serialization and pure Git hashing happen inside the atomic settings transaction; real Git processes, pack validation and HTTP transfers happen outside it. A push rechecks the accepted head after acquiring the repository lock, then imports under catalogue → sorted sources → affected runners/assignments. Its success response is sent only after commit.

## Transaction entry points

| Entry point | Locks and atomic work | Commit boundary / qualification |
| --- | --- | --- |
| `Monitoring.control/2` | Registration → runner → sorted assignments → loss. Changes contact/session and preparation/activation authority together. | The loss lock prevents contact/session changes committing during a loss sweep's protected snapshot. HTTP long polling waits after this transaction returns, then rereads durable state. |
| `Monitoring.ingest/2` | Runner → sorted owned assignments → complete existing condition stripe set. Admit/replay each report in original order; write observation, per-output projection, health transitions, condition facts and durable jobs; reduce monitoring loss under its lock. | The envelope is one transaction; invalid individual reports get dispositions. Existing source age/identity remains unchanged on replay. Historical observations do not acquire current-state authority. |
| `Inventory.reconcile/2` | Source → registration/runner → publication → sorted source and adoption assignments → outgoing/incoming condition stripe union. Reconcile membership, configurations, streams, coverage and grouped retirement; take loss before commit. | Complete source inventory is atomic. Rule rejection diagnostics are recorded in a separate transaction only after the rejected inventory transaction rolls back. |
| `PublisherLifecycle.preview/4`, `apply/3` | Both lock sorted sources → sorted runners → sorted publication rows → sorted assignments and their condition identities. Apply mutates contributions and takes loss before commit. | Review is a snapshot, not a held lock across user interaction. Apply validates reviewed state and records immutable lifecycle evidence; restoration requests a later authoritative publication. |
| `Monitoring.save_assignment/3` | Source → runner → assignment; recheck runner identity/revision, write configuration and generation, enforce the runner response bound. | Source-owned parameters cannot be overwritten. No-op values do not advance generation. |
| `BulkConfiguration.apply/2`, `ConfigurationRules.apply/2`, `reset_exception/1`, `ConfigurationPolicy.apply/2` | Bulk: sorted sources → sorted runners → sorted assignments. Rule/policy catalog mutations additionally take catalog first; reset uses source → runner → assignment. | Revalidate the review and bounds while locked. A batch fails atomically; previews never reserve a future right to mutate. |
| `Monitoring.retire_assignment/4` | Assignment → condition identities/contributions → loss before commit. | Legacy operator retirement only; source and publisher retirement use caller-owned helpers in their wider transactions. |
| `Monitoring.acknowledge/4` | Individual/contributor: assignment → optional condition stripe/group → incident. Shared condition: stripe → group. | Captured revision/attention scope, control audit and occurrence gate wake are atomic. Group acknowledgement does not lock every observer assignment. |
| `MonitoringLoss.acknowledge/4` | Loss domain → incident/control/occurrence writes. | Does not acquire runner, assignment or measured-condition locks. |
| `Maintenance.apply/3`, `cancel/4`; `MaintenanceSchedules.apply/3`, `cancel/4` | Exclusive maintenance gate → applicable sorted sources → applicable sorted assignments → condition stripes before grouped gate writes → loss before monitoring gate writes. | Review/reviewed scope, windows/series, audit and wake revisions commit together. Preview uses the shared gate. Specific cancellation paths need only a subset of these locks. |
| `NotificationWorker.begin_attempt/3` | Shared maintenance gate → delivery ownership context → occurrence `FOR UPDATE`; read the dispatch clock after waits. | Commit the started attempt before external delivery. An acknowledgement or maintenance edit afterward cannot retract I/O already begun. |
| `NotificationWorker` completion transaction | Delivery ownership context → occurrence → attempt/status/fact coverage and wake writes. | No maintenance gate: it records the result of an admitted attempt, not a fresh gate decision. HTTP/SMTP I/O happens between admission and completion transactions. |
| `Monitoring.retry_notification/3` | Delivery ownership context → occurrence; recheck exhaustion and active job, queue a bounded new budget and control audit. | Keeps original occurrence/payload/destination. No maintenance gate is needed to queue retry: actual dispatch applies current gates. |
| `MonitoringLoss.reconcile/1` | Shared maintenance gate → loss; load runner metadata once under loss serialization; reduce gaps and coverage. | Takes no later runner/assignment/condition locks. Control and inventory cannot commit changed authority without loss serialization. |
| `Sweeper.sweep/1` | Shared maintenance gate → sorted assignments owning discarded-job candidates → condition stripes for grouped candidates → loss. Recheck latest jobs before exhaustion and retain protected evidence during cleanup. | Each pass selects at most 1,000 roots per retention category, with one shared observation budget. Freeze terminal parent IDs before deleting children; commit and yield between full passes. Cascades and query scans are not row/time-bounded; see [retention](RETENTION.md). |
| `Sweeper.wake_held_notifications/1` | Transactionally rechecks/updates eligible Oban job rows whose recorded hold revision differs from the occurrence. | Does not lock occurrence parents or decide delivery eligibility. Wakes at most 1,000 candidates; later dispatch rechecks gates. Notify Oban after commit. |

## Caller-held helper contracts

These exported helpers are not standalone transactions. Their public visibility supports context cooperation, not unrestricted external use. A `!` suffix alone does not specify ownership.

| Helper | Required caller ownership / behavior |
| --- | --- |
| `Monitoring.register_runner/2` | Transaction already open; source lock already held when publishing inventory. Acquires registration and runner locks itself. Caller takes loss before committing contact/session changes. |
| `Monitoring.lock_assignment/1` | Transaction already open; acquire earlier source/runner locks if the enclosing operation needs them. A later `change/2` cannot repair missing ownership. |
| `Monitoring.lock_condition_streams!/2`, `Conditions.lock_keys!/1`, `lock_ids!/1`, `lock!/1` | Open transaction; assignment set already locked when changing members. Collect the full identity union before mutation. `lock_ids!` locks stripes, not group rows; `lock!` also locks the selected group row. |
| `Conditions.observe!/6`, `retire_contributions!/3`, `reduce!/3` | Owning assignments and relevant stripes already held. Reduce after the complete output/retirement batch to avoid artificial group closure. |
| `Monitoring.retire_source_assignment!/4`, `retire_publisher_assignment!/4`, `retire_source_stream!/6` | Owning assignment already locked; caller prelocks the full batch's condition identities. Internal repeated stripe acquisition does not authorize late acquisition of a new stripe. With `reduce: false`, caller must reduce affected groups after the batch. |
| `Monitoring.update_configuration!/3`, `set_effective_configuration!/5`, `ensure_control_bound!/2` | Relevant source/runner/assignment ownership established by the configuration/inventory entry point. Capacity checks must be serialized with other mutations of the same runner. |
| `Coverage.reconcile!/2` | Inventory transaction holds source, runner, publication and affected assignments. Replaces that publication's declaration projection atomically with accepted membership. |
| `MonitoringLoss.reconcile_runner!/3`, `lock_incident!/1`, `lock_delivery_incident!/2` | Open transaction, any earlier domains already held; these acquire loss themselves. Delivery may reconcile committed retirement/recovery before deciding eligibility. |
| `MonitoringLoss.reconcile_coverage!/1`, `observe_coverage!/2`, `wake!/1`, `prune!/2` | Caller holds loss serialization. They do not establish it independently. `prune!` selects a limited, fixed parent set for atomic terminal cleanup and preserves unfinished delivery. |
| `Monitoring.lock_delivery_context!/2` | Open transaction. Individual ownership locks assignment then reads incident; grouped ownership locks condition stripe/group; monitoring ownership locks loss and reconciles. Do not lock occurrence first or add another observer's assignment after taking grouped ownership. |
| `Conditions.delivery_accepted!/2`, `request_gate_wake!/1` | Caller owns the relevant condition stripe. Completion has already locked its occurrence; updates to sibling occurrences stay within the same parent domain. |
| `Maintenance.series_*` mutation helpers, `cancel_series_window!/3`, `MaintenanceSchedules.child_changed!/4` | Enclosing maintenance transaction owns gate and relevant source/assignment scope. They preserve one atomic series/window/audit mutation rather than starting separate transactions. |
| `Monitoring.enqueue_notification!/2`, `change/2`, `end_acknowledgement_attrs!/3` | Caller owns the affected state. Job insertion and acknowledgement-ending audit belong in the same transaction as the transition that requires them. |

## Implicit locks and external work

Foreign-key checks can acquire `KEY SHARE` on referenced rows; changing a primary/unique key or taking `FOR UPDATE` conflicts with that protection. In particular, inserting a monitoring incident after acquiring loss serialization checks its runner foreign key. A runner writer waiting for loss must therefore use `FOR NO KEY UPDATE`, not `FOR UPDATE`, because runner identity is immutable. This is an exercised deadlock regression, not an optional query optimization.

Other references matter too: observations/configurations/streams refer to assignments; contributions and occurrence evidence refer to observations and incidents; attempts refer to occurrences; publisher lifecycle evidence protects observations. Group facts and occurrences have deferred ownership/cyclic references, so checks can run at transaction end. Deletion cascades lock their children. Review migrations and all writes in the call chain, not just explicit `FOR UPDATE` queries. Retention must preserve current authority, unresolved work and referenced evidence even when receipt age has expired.

Never put receiver HTTP/SMTP, Python preparation/execution, or long-poll waiting inside these database transactions. Durable notification work is inserted transactionally; delivery is at least once, with a visible ambiguous started attempt if the process stops after external acceptance but before recording success. Post-commit broadcasts and wakeups prompt rereads and do not supply persistence or authority.

## Regression evidence and review limits

The following existing tests exercise important edges; their presence is not a fresh execution claim. See [the acceptance guide](../tests/e2e/README.md) for real-service scenarios; record run results with their source revision.

| Boundary | Regression files under `controller/test/mondek/` |
| --- | --- |
| Assignment-before-condition adoption and opposite source ordering | `inventory_condition_lock_test.exs`, `maintenance_selection_test.exs` |
| Runner FK/loss deadlock, session fencing and protected sweep snapshot | `monitoring_loss_lock_test.exs` |
| Batch order, concurrent replay/activation, retry versus discarded jobs | `lifecycle_test.exs`, `monitoring_test.exs` |
| Group first arrivals, bounded sorted stripes, acknowledgement races and in-flight withdrawal | `conditions_test.exs`, `condition_concurrency_test.exs` |
| Maintenance cancellation versus group completion; clock after lock wait | `condition_delivery_test.exs`, `maintenance_test.exs` |
| Inventory/source capacity, namespace rules and atomic reviewed configuration | `inventory_test.exs`, `configuration_rules_test.exs`, `bulk_configuration_test.exs`, `configuration_policy_test.exs` |
| UI/Git races, killed transaction, lost response, import scope and atomic rejection | `configuration_repository_test.exs`, `configuration_import_test.exs` |
| Publication/retirement races, retained lifecycle evidence | `publisher_lifecycle_test.exs`, `coverage_test.exs` |
| Monitoring ticks, durable holds and protected cleanup | `monitoring_loss_test.exs`, `monitoring_loss_delivery_test.exs` |
| Commit-before-external-I/O and terminal/protected retention | `notification_test.exs`, `maintenance_schedules_test.exs` |
| Real concurrent long polls release database locks | `control_polling_test.exs` |

This source trace does not prove arbitrary combinations of every mutation, cascade and retention query are deadlock-free. Existing tests cover selected controlled interleavings, not exhaustive PostgreSQL scheduling. No new lock behavior is introduced by this document. TD-07's [retention measurements](RETENTION.md) exercise concurrent ingestion and motivate bounded, independently committed passes; root limits must not be described as a bound on cascade size, query scans or elapsed time.

When changing a mutation, identify its entry transaction, all explicit and implicit locks, any caller-held helper assumptions and the full batch ownership set. Compare with this table, preserve immutable evidence and job ownership, and add a controlled interleaving regression when introducing a new lock edge. Do not solve a missing contract by dropping serialization or by wrapping external work in a larger transaction.
