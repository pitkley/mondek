# Inspect runners and notification delivery

Runners collect measurements. The controller delivers incident notifications. Use **Runners** to investigate collection and controller contact, and **Notifications** to investigate receiver acceptance, holds and retries.

## Find a runner

The fleet inventory starts with runners that have measurement gaps or overdue contact. Search by name, installation ID, source project or reported execution context. Filter contact and collection independently, or sort by name or latest contact. Filtering and sorting cover the complete fleet before pagination; overall counts and matching counts name their different scopes. Duplicate names include the stable installation identity.

Recent contact means the runner contacted the controller within `MONDEK_MONITORING_CONTACT_SECONDS` (60 seconds by default). It does not prove that checks executed or produced usable evidence. A runner can have recent contact and unavailable measurements, or overdue contact with measurements that remain fresh under the check's declared interval. Fresh Warning or Critical results still represent working collection. An empty runner has no active published results; that is distinct from healthy collection.

Open a runner to inspect its fresh/expected results and links to unavailable, overdue or awaiting measurements. The detail also links to configuration, intended coverage and monitoring-loss incidents. Following a result list or investigation preserves a route back to the runner. Source publication and execution context remain distinct from monitored targets and environments.

Execution and upload information is the last reported snapshot. It can predate the latest controller contact; it does not advance between reports. A buffered queue can be transient. Cumulative dropped reports and recorded diagnostics can survive recovery, so they are not used to declare a current outage. Identity, session and raw bounded status remain available in secondary disclosures. Copyable agent prompts include bounded context for investigation and deployment planning.

## Inspect a notification

The dedicated notification inventory defaults to outstanding delivery. Exhausted automatic retries appear first, followed by retrying, queued and in-progress work, with oldest first within each state. Accepted and superseded history is available through the status filter. Installation-wide counters remain complete across pages. A held failure notification states whether acknowledgement or maintenance applies; holding delivery does not resolve an incident.

Open a notification to inspect its original receiver, incident or result, controls, latest response and bounded attempt history. The exact detail remains available when the notification changes status and no longer matches the originating list filter. Returning to the list restores that filter and page, clamped if its last page disappeared. Reconnecting preserves the selected list page and unsent retry reason without submitting it.

Manual retry requires a reason and reuses the original immutable notification and destination through the existing delivery policy. Failure delivery still respects acknowledgement and maintenance. Receiver acceptance is transport evidence: SMTP acceptance does not prove inbox delivery or that a person read the message. Lost replies can cause duplicate delivery. These views change inspection, not notification ownership, retry budgets or execution semantics.

## URLs and verification

The canonical pages are `/runners`, `/runners/:id`, `/notifications` and `/notifications/:id`. Older `/runners?runner_id=…` links redirect to the exact runner. Old notification status/page query links redirect to Notifications. An old fragment-only `/runners#notifications` bookmark opens Runners; use the Notifications navigation link.

Read-only API endpoints mirror these inventories and exact details at `/api/v1/runners`, `/api/v1/runners/:id`, `/api/v1/notifications` and `/api/v1/notifications/:id`. Runner lists now return pages (25 by default, maximum 50) with complete counts, rather than an unpaged first-100 subset. Follow `page` and `page_size`; collection and contact have separate fields. Runner telemetry is an allowlisted, bounded projection. Missing details return HTTP 404.

Start the local installation with `devenv shell -- mondek start`. Run `devenv shell -- python3 tests/browser/run.py --suite fleet` for twelve live Python runners, collection and transport failure/recovery, process restart, reconnect, paginated navigation and actual local notification failure/retry. Additional runners publish and measure in bounded batches before stopping, creating fifty runners with real measurement history: twelve live observers and thirty-eight overdue observers. Every runner has an independent state journal in one supervised test container. This verifies operator flows with fifty runners and operation with twelve live runners. Recovery with fifty concurrent runners and production capacity are not established. See [the acceptance guide](../tests/e2e/README.md).
