# Notifications when monitoring breaks

Mondek distinguishes target health from the ability to measure it. Fresh Critical evidence is working monitoring of a failing target. Unknown, failed collection, missing output, overdue evidence and a runner that has not established measurements represent missing monitoring. The last confirmed target health remains visible and its incident stays independent.

## What opens an incident

- **Monitoring on a runner.**

  Sustained unavailable, stale or awaiting results produce one monitoring-loss incident for that runner, with a paged list of affected results and links to their measurement investigations. Missing control contact also contributes the runner's active results; this includes the case where uploads work but configuration/control contact does not. The group collects operator work and does not assert that all results have the same underlying cause. Empty or completely retired runners do not alert.

- **Declared results with no selected runner.**

  Concrete missing coverage produces one incident per source project. Stable source/check/output/environment/target identities survive inventory republishing. Unresolved templates, undeclared targets and unsupported catalogues do not invent expectations. Installing a runner does not resolve this incident until fresh measurements establish the declared coverage. The original coverage episode owns those gaps during adoption, avoiding a duplicate runner alert.

The controller persists each gap's start and grace deadline. Repeated failures, reason changes, configuration edits, replay and controller restart do not restart the timer. Every accepted observation is reduced in order, so a measured restoration followed by another collection failure in one upload starts a new grace period. Only admitted current evidence affects the lifecycle.

## Delays as configuration

Set these ordinary controller environment variables in `controller.env`, or declare them in Compose. They are not secrets. Restart the controller after changing them.

| Setting | Default | Meaning |
| --- | --- | --- |
| `MONDEK_MONITORING_LOSS_GRACE_SECONDS` | `120` | Continuous measurement/coverage gap before an incident opens. |
| `MONDEK_MONITORING_CONTACT_SECONDS` | `60` | Time without control/inventory contact before active results become contact gaps; the normal grace follows. |

Both accept whole seconds from 1 through 604800. Startup and configuration-adoption gaps get at least two check intervals plus the execution timeout, or the configured grace, whichever is longer. Freshness comes from each check's existing declared freshness interval; grace follows the detected freshness gap. Existing persisted deadlines retain the policy under which they began. The sweeper detects transitions once per second; it does not make domain checks run more often.

On upgrade, previously visible gaps become eligible to notify. For example, declaring home-network checks before installing their home runner produces one source coverage incident. Acknowledge that monitoring episode while arranging the runner, or withdraw the expectation in source when it is no longer intended.

## Acknowledgement and maintenance

Acknowledging a monitoring-loss incident explicitly covers the named runner's or source's monitoring for that episode, including later affected results. It does not acknowledge any target-health incident. Use a long expiry or “until the incident ends”; ending or expiring the acknowledgement resumes eligible unsent delivery with the same notification and retry budget.

Existing check, selection and logical-target maintenance applies to matching affected results, including a concrete declared target without an installed assignment. Only complete maintenance coverage holds the group's failure notification. If even one affected result remains outside maintenance, the group can notify. Collection and gap tracking continue throughout maintenance; a new uncovered member wakes held delivery.

Each episode has one immutable problem notification. Its initial affected-result snapshot remains unchanged through retries; the live incident shows current membership. Late members update the investigation, without sending a notification for every missing check. A restored episode ends its acknowledgement. A later interruption is a new episode and can notify again.

## Restoration and withdrawal

An established gap requires fresh evidence from the currently authorized generation and runner session, with source time newer than the gap. A heartbeat, replay, retained OK, old buffered sample or merely selecting a runner cannot establish restoration. Valid cached data can establish initial monitoring within the provisional startup grace, subject to the check's freshness contract. Restored monitoring may report WARN or CRIT; it makes no claim that the target is healthy.

Removing an affected check, target or publisher ends its expectation administratively. If withdrawal contributed to ending an episode, its terminal notification says Closed, not Monitoring restored. A terminal notification is created only if the problem notification had a delivery attempt; a completely unattempted transient remains historical without an unsolicited restoration message.

The existing durable notification queue provides local webhook or SMTP delivery, frozen payloads/destinations, attempts, bounded automatic retries and reasoned manual retry. Monitoring incidents and measured-health incidents share delivery inspection but keep separate ownership. Current membership is paged; notifications retain their initial snapshot and ended episodes retain their last affected membership, each bounded to 100 identities rather than a lifetime membership log. Email displays the first 20 with the full affected count. Retained referenced observations and maintenance history remain protected; completed history follows the existing 30-day cleanup once delivery is terminal.

## Independent controller detection

This controller cannot notify while it or its database is completely unavailable. An external observer must detect that case and deliver through an independent path. `/health` establishes HTTP availability only; it is not proof that observations, freshness sweeps or notifications are advancing. The operator has explicitly deferred this external observer; it is outside the active work queue. Do not interpret the new in-controller alerts as coverage of controller failure.

## Verification

Run `devenv shell -- python3 tests/browser/run.py --suite monitoring-loss` for real runner collection failures, grouped outages, local delivery failure/retry, acknowledgement, maintenance and measured restoration. Native PostgreSQL regressions cover grace boundaries, report ordering/replay, concurrency, source coverage adoption, retirement, bounded pagination and retention. See [the acceptance guide](../tests/e2e/README.md).
