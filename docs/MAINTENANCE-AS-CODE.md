# Maintenance schedules as code

Keep a complete maintenance project manifest in your own reviewed Git repository. The controller reviews and applies the manifest explicitly through the maintenance project API. The maintenance project has its own revision, independent of check configuration Git. Automatic runner registration and Git fetches leave saved maintenance unchanged.

Use durable project and schedule keys. A schedule declares stable check selectors and either finite or open-ended weekly recurrence. A replacement starts at a newly reviewed future date. Started windows and individually edited or canceled dates keep their original series and history. Choose a replacement start after the end of any future exception and its original interval, so a replacement cannot undo it by recreating the old date.

Export the current project before making changes. Compare the current series revisions and preserved exceptions, and pass the exported project revision when planning a change. A changed selector membership, resolved time, overlapping window, upcoming child or generation cursor requires a new review. Routine generation does not change the exported project revision. The project preview and apply are separate requests.

An unchanged manifest leaves an existing schedule alone even after its first date starts. To remove a schedule, omit its key from the complete manifest. The reviewed removal stops generation and cancels untouched upcoming dates. Started windows and individual exceptions keep their recorded settings.

## Author a manifest

Keep local civil dates in the schedule timezone. This example uses an open-ended weekly schedule. For a finite schedule, use `end_mode: "count"` with `count` or `end_mode: "date"` with `until_date`. Choose a future first date when creating or replacing a schedule.

```json
{
  "version": 1,
  "project": "watchpost",
  "schedules": [
    {
      "key": "weekly-release",
      "proposal": {
        "name": "Weekly release",
        "reason": "Scheduled service rollout",
        "timezone": "Europe/Berlin",
        "starts_local": "2026-11-29T22:00:00",
        "ends_local": "2026-11-29T23:00:00",
        "start_fold": "reject",
        "end_fold": "reject",
        "recurrence": {"frequency": "weekly", "interval": 1, "end_mode": "open"},
        "selections": [
          {"scope": "stable_check", "source_id": "watchpost", "source_key": "service", "environment": "production"}
        ]
      }
    }
  ]
}
```

## Review and apply

Fetch `GET /api/v1/maintenance-projects/watchpost`. Its `data` contains the current `revision`, declared `manifest`, active schedule IDs, and archived keys. Inspect changed series through the existing maintenance series API before reconciling an older manifest. Send that revision as `base_revision` with the new `manifest` to `POST /api/v1/maintenance-projects/plan`. An initial project can omit the revision.

Review the returned dates, count and sample of matching results, existing overlaps, cross-schedule overlaps, and windows affected by retirement. Submit the original manifest and returned `review_token` to `POST /api/v1/maintenance-projects/apply`. Apply is atomic, and a review expires after 15 minutes. Retrying the last applied token within that interval returns its saved receipt. Plans should stay outside the source repository.

One manifest can contain eight schedules, with up to 32 stable selectors per schedule and 128 created or canceled windows per apply. A project remembers up to 64 distinct keys. Retained series from earlier generations protect their active windows and future exceptions during subsequent replacements. Historical series follow ordinary maintenance retention.
