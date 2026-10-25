# Scheduled notification maintenance

Use **Maintenance** to plan one window over selected checks or targets, or choose **Schedule maintenance** from a check or incident. Give the work a common name, reason, start and end, and review the affected results and exact times before saving. Checks continue collecting evidence throughout. Maintenance holds failure notifications; it does not declare a target healthy, close incidents or pause a runner.

## Choose the scope deliberately

- **This scheduled check.**

  Covers every result from that check instance on its existing runner, including future outputs declared for that instance. Another instance on a replacement runner is independent. The preview lists the results currently included.

- **This stable target.**

  Covers results with the exact target kind and stable ID, within the same monitoring source and monitored environment. It follows matching results across runners and includes later arrivals during the window. It does not include another environment, another monitoring project or another target with the same display name. A missing environment is an exact “no monitored environment” scope, not a wildcard. In a check producing several targets, unrelated results remain eligible for notifications.

A target window survives a period with no matching results. Zero matches mean there is currently no matching monitoring coverage; they do not establish health. This scope does not merge incidents, elect an observer or transfer an existing incident to another runner. Removing a source still retains its historical incidents with the existing source-removal closure reason.

A single target selection can cover several scheduled checks, provided their results declare that exact target within the same source and monitored environment. A host selection does not automatically include separately identified disks or services on that host. Add their exact targets or the relevant scheduled checks explicitly; names do not establish containment or a common incident.

## Select several checks or targets

The global scheduling page lets you search scheduled checks or monitored targets, with source, monitored-environment and runner filters. Select individual rows, select the current page, or add all matching choices. Changing filters or pages keeps the selection. **Review selected** shows the complete selection across those pages and allows removal. A single-check draft offers **Include more checks or targets** to keep its existing scope while extending the window.

**Add all** captures the identities matching at that moment. The search is not a continuing rule. Each captured check or target keeps the membership behavior described above. A runner filter narrows target discovery only: a selected target still includes matching results from other runners. Zero-match selections remain visible after disappearance. A target selection covers later exact matches from replacement observers; a retired check instance stays inspectable and does not automatically select its replacement.

One window can contain up to 512 checks and targets in any combination. The affected-result preview deduplicates overlapping selections: choosing a check and one of its targets does not count that result twice. Selection counts and current-result counts therefore need not match. One reviewed save, revision and cancellation apply to the whole window; there is no partial save or collection of independently drifting windows.

The preview and saved window show the selected count with an **Inspect selected checks and targets** disclosure. Open it to page through the complete scope in label order; it retains its open state through live updates and reconnect. The preview keeps resolved times, current affected counts, overlaps and the save action visible, with the individual affected results in a separate counted disclosure. Current results remain distinct from the fixed selection.

## Review the clock interpretation

Choose an explicit IANA timezone, such as `Europe/Berlin`, or `UTC`. The server interprets the local start and end using its pinned timezone database. Review the exact UTC instants as well as the local clock readings. Windows are active at their start and inactive at their end: `[start, end)`.

During the spring clock change, some local times do not exist. Mondek rejects them instead of silently changing the time. During the autumn clock change, some local times occur twice. Select the earlier or later occurrence for each ambiguous endpoint. The elapsed duration is calculated between resolved instants, so a clock reading that looks earlier can still be a later instant across that change.

Saved UTC instants define execution. Controller restarts and browser timezone changes do not move the window. One-off windows can be long, with no two-hour limit. [Repeating maintenance](RECURRING-MAINTENANCE.md) creates a finite weekly series with an explicit ending and a review of every resolved window.

## Edit, end and inspect

Active and upcoming windows appear in the maintenance list; completed and cancelled windows remain in history. A saved window's scope is fixed; cancel it and create another window to change its scope. Upcoming windows can be rescheduled. Once a window has started, its start and timezone are also fixed; adjust its end, name or reason, or end it early. Every change records the local operator, revision and reason.

Saving requires a reviewed preview. If the window or affected membership changed, review the current state again. Drafts survive live updates and reconnect, but a previous preview does not silently authorize a changed proposal. Cancellation also checks the reviewed revision.

Overlapping windows remain independent. Ending one does not end another window or an incident acknowledgement. Held delivery work is reconsidered after changes, using its existing occurrence, payload and retry budget. Exhausted or already delivered notifications are not automatically restarted. An HTTP attempt already underway can finish.

Recovery and other incident-closure notifications retain their existing eligibility. If no failure notification was attempted before the incident ended, Mondek discards the obsolete failure instead of sending a misleading recovery notification.

## Local commands

```sh
devenv shell -- mondek demo
devenv shell -- mondek maintenance-acceptance
devenv shell -- python3 tests/browser/run.py --suite maintenance
```

The acceptance command creates disposable Compose projects. It exercises real runner measurements, controller restarts, local webhook delivery, overlapping windows, acknowledgement, retries and a logical volume moving between observers. Normal development databases are preserved.

Use the reviewed maintenance endpoints to create and cancel immediate or scheduled windows. The old `/api/v1/assignments/:id/maintenance` duration endpoint is absent.

## Reviewed HTTP flow

All writes use JSON. New windows start from a source-declared check or result; the controller does not invent monitoring coverage.

| Request | Purpose |
|---|---|
| `GET /api/v1/maintenance` | Page active and upcoming entries, including grouped `kind: "series"` summaries; use `status=history` for completed/cancelled entries. |
| `GET /api/v1/maintenance/seed/:assignment_id` | Obtain a proposal and allowed scope options; optionally supply `stream_id`. |
| `POST /api/v1/maintenance/preview` | Submit `proposal` and optional `page`; receive resolved times, current matches, overlaps and a review token. |
| `POST /api/v1/maintenance/apply` | Submit the exact returned `proposal` and `review_token`. |
| `GET /api/v1/maintenance/:id` | Inspect saved intent, its current matches, editable proposal and revision history. |
| `POST /api/v1/maintenance/:id/cancel` | Submit the reviewed integer `revision` and an operator `reason`. |

The proposal includes `name`, `reason`, `scope`, its exact identity fields, `timezone`, `start_mode` (`now` or `scheduled`), `starts_local`, `ends_local`, `start_fold` and `end_fold`. Fold choices are `reject`, `earlier` or `later`; `reject` is the ordinary default and only blocks ambiguous clock readings. Use the scope fields returned by the seed together; changing only `scope` does not fill its target identity. The timezone database version and civil-time interpretation are retained with the saved window. Edits carry its `id` and `revision`.

For a composite window, set `scope` to `selection`, set the parent `assignment_id`, `source_id`, `environment`, `target_kind` and `target_key` to `null`, and provide `selections` with one to 512 ordinary check or target scopes. Each selector contains the six fields `scope`, `assignment_id`, `source_id`, `environment`, `target_kind` and `target_key`. Check selectors use only `assignment_id`; target selectors use source, environment, kind and key. Unused fields are `null`. Preview canonicalizes and deduplicates the array; submit its returned proposal unchanged when applying. `selection_summary` explains each selector's current match count, including zero matches. Existing single-check and single-target requests remain supported.

Reviews expire after fifteen minutes. Pagination of one review must retain its original `review_token`, so a “Start now” interval does not move while reading additional matches. Invalid proposals return 422; stale or changed reviews return 409. A duplicate apply does not silently overwrite a newer revision.

Window lists, selection lists and affected-result previews use pages of twenty-five. A transactional preview supports up to 4,096 current results; existing windows still cover later matching results, and cancellation remains available beyond that review bound. Check/result summaries show a bounded list with links to the maintenance inventory. Maintenance preview/apply requests allow up to 2 MiB to accommodate escaped identity strings in a full selection; ordinary API requests retain their smaller bound.

Completed one-off windows and their events are eligible for cleanup after thirty days, measured from cancellation or the scheduled end. Matching retained incidents protect the relevant window history beyond that period. A repeating series retains all its dates until the complete series meets its [retention conditions](RECURRING-MAINTENANCE.md#reviewed-http-flow).

Routine history inspection returns each revision's name, reason and times. Composite revisions carry `selection_count` and `scope_window_id` rather than repeating the full selection in every event; inspect that window's top-level `selections` for the exact scope, which cannot change between revisions. Full original event snapshots remain persisted for audit.
