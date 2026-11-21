# Repeating maintenance

A repeating schedule creates a **series** of ordinary maintenance **windows**. Each window holds failure notifications for its saved interval. Checks keep running, measured health remains visible, and recovery notifications keep their existing eligibility. The [maintenance scope model](MAINTENANCE.md) applies to scheduled checks, stable checks and stable targets.

## Plan the first window and the ending

Choose the first window's local start and end dates, an explicit IANA timezone, and a repeat interval from one through twelve weeks. Both local endpoints repeat by calendar weeks. For example, Sunday 23:00 to Monday 03:00 stays an overnight Sunday-to-Monday window after the clocks change.

End the schedule **after a number of windows**, **through a date**, or **when canceled**. The number includes the first window. A through date includes windows whose local start falls on that date. An overnight end may fall on the next date. Finite series contain between two and fifty-two windows. A date range producing more windows is rejected.

The review shows the number of windows, final date and each exact interval. Current matching results are shown separately: they explain today's membership, not a prediction that the same observers will still exist on every future date. Check scopes stay with their scheduled instances; stable target scopes include later matching results in the same source and monitored environment.

## Daylight-saving behavior is explicit

Local clocks determine each proposed date. The controller resolves every endpoint through its pinned timezone database before saving. Elapsed durations can therefore change across a clock transition even when the displayed start and end clocks stay the same. Inspect the local and UTC values in the review.

If any endpoint occurs twice, choose the earlier or later occurrence explicitly. The choice applies whenever that endpoint is ambiguous in the series; it has no effect on ordinary dates. If a local time does not exist, the proposal is rejected with the affected window and date. Choose clocks outside the missing interval or schedule separate windows around that date. Mondek does not silently move or skip it.

Repeated windows cannot overlap one another. Touching intervals are permitted, but there is no notification gap between them. Independent windows and other series can still overlap; ending one hold leaves all others in effect.

Saving a finite series authorizes the complete reviewed set of UTC intervals in one transaction. Those instants remain fixed after a restart or timezone database update. If the first start passes before saving, review a future schedule again.

## Run a schedule until canceled

The review shows the first eight exact windows and the rule that authorizes future dates. Mondek keeps a bounded reserve of upcoming windows. Saved UTC intervals stay fixed. Each later date uses the saved local clocks and fold choices with the timezone database available when it is saved. If an upcoming date cannot be resolved or would overlap the previous rule interval, generation stops at that date. The series detail shows the affected date and reason. Cancel the rule and review a replacement to resume scheduling.

After prolonged downtime, Mondek reconstructs the window currently in effect and the upcoming reserve before notification workers start. Fully elapsed dates outside the catch-up range do not become maintenance windows.

## Inspect and change individual windows

The maintenance inventory shows one entry for the series. Open it to inspect all dates and any current or next window. Between windows, the series does not hold notifications merely because it has future dates.

Open an individual window to adjust or cancel only that date. The ordinary edit rules still apply: a started window keeps its original start and timezone; its end, name and reason can be changed. An individual exception does not rewrite the weekly rule or its sibling windows, and remains visible in the series history.

**Cancel upcoming windows** reviews the exact future windows it will cancel. Active and completed windows remain unchanged. To end active maintenance too, open that active window and use its explicit end action. If a reviewed future window starts or any relevant window changes before the cancellation is saved, the review is invalidated so the operator can inspect the current state.

For a different future pattern, create a new reviewed series and explicitly cancel the old one. For an open-ended rule, **Cancel future scheduling** stops generation and cancels upcoming windows in one step. The action is available even when there are no upcoming windows. The original series and its exceptions remain part of the audit trail.

## Notification and history boundaries

Maintenance affects eligibility of existing notification work. It neither creates new incident evidence nor restarts an exhausted retry budget. When a window ends, failure delivery becomes eligible only if no other maintenance or acknowledgement still holds it. An HTTP attempt already in flight can finish.

Removing or moving monitoring does not rewrite the selected identities or claim recovery. A target series can temporarily match no results and later cover an exact replacement observer. A check series remains attached to its original check instance. Shared incidents continue to evaluate the independently maintained contributions.

## Reviewed HTTP flow

Use the existing maintenance seed and exact scope fields, then add a `recurrence` object to a new-window proposal. Set `start_mode` to `scheduled`. The recurrence fields are `frequency` (`weekly`), integer `interval` (1–12), `end_mode` (`count`, `date`, or `open`), `count` (2–52 for count mode) and `until_date` (`YYYY-MM-DD` for date mode). Unused ending fields are null. Submit the canonical proposal returned by preview unchanged at apply.

| Request | Purpose |
| --- | --- |
| `POST /api/v1/maintenance-series/preview` | Resolve `proposal`; return compact dates, current matches and a review token. Optional `occurrence_page` and `result_page` are independent. |
| `POST /api/v1/maintenance-series/apply` | Save the exact `proposal` and `review_token` atomically. |
| `GET /api/v1/maintenance-series/:id` | Inspect current and original dates, exceptions, scope and series history. |
| `POST /api/v1/maintenance-series/:id/cancel-preview` | Review cancellation using the saved integer `revision` and an operator `reason`. |
| `POST /api/v1/maintenance-series/:id/cancel` | Apply the reviewed upcoming cancellation using `review_token` and the same `reason`. |

Creation and cancellation reviews expire after fifteen minutes. Reuse the original `review_token` when paging a preview. Invalid input returns 422; expired, stale or changed review authority returns 409. An exact duplicate creation request cannot create a second series. Each child remains inspectable and editable through the ordinary `/api/v1/maintenance/:id` routes.

Series responses include the series `timezone` and occurrence endpoints as local civil times (`starts_local`, `ends_local`) and UTC timestamps (`starts_at`, `ends_at`). Planned occurrences include the IDs that apply will save. Saved occurrences include their status and the original local and UTC endpoints, even after an individual window is changed. Cancellation preview returns the upcoming saved occurrences in `rows`, paged with `page`.

Dates and current results are paged independently in groups of twenty-five. Creation retains the existing 512-selector and 4,096-current-result limits. Combined generated window intent and original event snapshots are bounded to 8 MiB, and a review supports at most 1,024 distinct overlapping windows. An oversized proposal is rejected before any series is saved; shortening the series or splitting its selected scope makes the intended bounds explicit.

The maintenance inventory's `windows` collection can contain `kind: "series"` summary entries alongside ordinary windows. A series entry links to the series inspection route; only its child windows have actual notification intervals. Result and incident inspection keep the exact active window identities. Detail summaries show active children, or the next upcoming child per series, with a link to the complete dates.

Finite series retain their window and event history until every child is terminal and at least thirty days old. While an open-ended rule remains in effect, ordinary expired windows can be removed after thirty days. Individually edited or canceled dates and dates protected by matching retained incident evidence remain inspectable. After the rule is canceled, the remaining series history follows the normal completed-series retention policy. Use `history_page` to page series decisions independently of dates and current results.

## Local commands

```sh
devenv shell -- mondek demo
devenv shell -- mondek maintenance-acceptance
devenv shell -- python3 tests/browser/run.py --suite maintenance
```

The acceptance commands use isolated disposable services and a local notification receiver. Weekly date and daylight-saving boundaries are covered by controlled native tests; the real-service run exercises an actual first-window boundary, persisted dates across controller restart, continued runner execution, notification holds and resumption.
