# Acknowledgements

An acknowledgement holds failure notifications for one incident while investigation or repair is underway. It does not pause checks, change health, or hide the incident. Open the incident and enter an operator note in **Acknowledgement**.

An individual acknowledgement covers one result's incident. Checks declaring the same condition can also form a [shared incident](GROUPED-INCIDENTS.md), whose acknowledgement covers qualifying contributors, including equivalent late arrivals within its reviewed severity and impact limits. Individual and shared controls remain separately inspectable; names or nearby failure times never create a relationship implicitly.

## Choose its lifetime

- **This incident ends**

  This is the default, with no clock expiry. Measured recovery, a configuration change that ends the incident, or withdrawal of monitoring ends the acknowledgement.

- **A duration has passed**

  Choose 15 minutes, one hour, one day, one week or custom days and additional hours. The duration starts when saved. There is no two-hour acknowledgement cap.

- **A specific date and time (UTC)**

  Enter a future UTC timestamp. The field explicitly uses UTC regardless of the browser's timezone.

Every option captures the incident's current severity as its ceiling. A Critical acknowledgement covers a downgrade to Warning and a return to Critical. A Warning acknowledgement ends if severity rises to Critical; returning to Warning does not revive it. Editing an acknowledgement captures the severity reviewed for that edit. Ending it manually leaves any independent notification maintenance active.

Live updates and reconnection preserve the proposed note and lifetime. If another action or severity change invalidates the reviewed state, the form asks you to review the current incident and acknowledgement before saving or ending it. History records who acted, the note, lifetime, ceiling and subsequent ending. Authentication remains deferred, so actions are attributed to **Local operator**.

## Notification behavior

Existing queued notifications remain durable during a hold. Ending or shortening a hold prompts their existing jobs to reconsider eligibility. It does not create new notifications, reset exhausted delivery budgets or resend accepted notifications. A previously exhausted notification still requires the separate retry action. An HTTP attempt already underway may finish.

If an incident ends before any failure notification was attempted, obsolete failure work is discarded without a misleading recovery notification. If an attempt already happened, its incident-ended notification remains eligible even while acknowledgement or maintenance applies. Each delivery retains its original occurrence identity and payload across retries.

An indefinite hold shows no scheduled delivery time. Internally it has a bounded daily recheck plus prompt reconsideration after control changes; this is not a promise that delivery will happen the next day. Timed expiry is inactive at the exact deadline, and dispatch follows ordinary queue processing. Held jobs do not consume HTTP delivery attempts.

[Scheduled maintenance](MAINTENANCE.md) has its own start, end, timezone and scope. Its windows remain independent of the incident acknowledgement.

## API

Read the incident's `acknowledgement_revision` and `attention_revision`, then send both in `POST /api/v1/incidents/:id/acknowledge`:

```json
{
  "mode": "until_incident_ends",
  "revision": 0,
  "attention_revision": 1,
  "note": "Investigating the upstream service"
}
```

Other modes are `duration` with positive integer `seconds`, `until` with an offset-bearing ISO8601 `expires_at`, and `end`. Send only the fields for the selected mode. A stale revision returns HTTP 409. Explicit expiry and duration must yield a future date representable through year 9999. Requests require an explicit mode and both reviewed revisions; seconds-only requests are rejected. Use the end mode to end an acknowledgement.

## Verification

```sh
devenv shell -- mondek demo
devenv shell -- mondek acknowledgement-acceptance
devenv shell -- python3 tests/browser/run.py --suite acknowledgements
```

Acceptance starts isolated PostgreSQL, controller, runner and local receiver services. It exercises indefinite restart, independent gates, long holds, stale cancellation, shortened expiry, severity changes, recovery and existing retries. The browser journey exercises actual forms, reconnect, conflicting review, custom duration, UTC expiry, history and real delivery. Both commands remove only their own projects and retain evidence under `.local/`.
