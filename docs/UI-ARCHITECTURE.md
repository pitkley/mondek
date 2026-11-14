# Operator interface

Mondek has one operator interface at `/`, built with Phoenix LiveView, PatternFly HTML/CSS components, Lucide icons and the Pearl palette. It does not use React. Components with `Preview` or `Next` in their internal names are the production implementation; there is no parallel preview route or legacy asset bundle.

## Pages and investigations

Overview presents installation health, open incidents and independent results. Checks provides the complete filtered result inventory. Incidents combines health failures and monitoring loss, with removable default Grouping and Status chips. Maintenance owns scheduling and review. Configuration, Runners, Notifications and Coverage are secondary management destinations. Setup is available through Help & setup.

An investigation opens over its originating list or editor. Related result, execution, incident, runner, notification, declaration and diagnostic links add typed entries to the same stack. Returning to an identity already in the stack reactivates it instead of duplicating it. The cards underneath retain their rendered content; only the active entity is interactive. Hover intent, focus, dismissal and reduced-motion handling belong to PanelStack, not individual pages.

Direct entity pages and panels render the same canonical body. Open as page patches the existing owner, retaining its investigation and safe drafts. A panel may initially show fewer history entries; older retained entries remain reachable in place. Dedicated result pages use `/results/:id/full`, execution pages `/executions/:id`, and incident pages `/incidents/health/:id/full` or `/incidents/loss/:id/full`. IDs are typed: result/execution/incident/runner/notification UUIDs, declaration scope hashes and diagnostic integer IDs cannot be interchanged.

## Components and state

`PreviewFilters` and `filter_picker.mjs` implement the common text-and-chip search interaction, including keyboard editing and navigation. Each owner defines its domain fields, suggestions, normalization and URL or draft application. `ScalarFilterPicker` handles repeated scalar suggestion presentation; it does not dispatch arbitrary events or own workflow authority. Suggestions are bounded after backend search, so values outside the initial menu remain discoverable.

`PreviewDetail` provides headings, cards, fact tables and detail surfaces. `PreviewPagination` provides stable numbered pagination with URL and explicit event modes. `SelectableRows` handles row clicks without stealing checkbox, link or keyboard behavior. Specialized comparisons, selection, acknowledgement, delivery and maintenance controls remain ordinary domain components.

`InvestigationStack` is a stable LiveComponent owning typed entity state within a host. `InvestigationTrail` validates navigation and deduplicates identities; `InvestigationEntity` loads bounded current evidence and initializes entity controls. Canonical bodies are `PreviewResultDetail`, `PreviewIncidentDetail`, `ExecutionDetail`, `RunnerDetail`, `NotificationDetail` and the Coverage bodies. Host links pass explicit typed callbacks. Deliberate editing destinations remain separate LiveViews; returning to an already owning editor patches that owner rather than remounting it. BrowserNavigation validates each local return destination against the router and retains up to four nested returns within an 8192-byte encoded bound, so editing rules can return through configuration and the original result to its filtered list.

The visible trail is limited to six entries and retained state to sixteen identities. Signed, bounded, context-specific recovery preserves safe draft values and captured revisions through reconnect. Recovery is not new authorization: mutation contexts still reject stale reviews, changed membership or ineligible actions. Rear-card DOM snapshots are presentation only. Full reload starts a fresh owner unless a supported recovery handoff explicitly supplies retained controls.

Maintenance has one canonical editing owner, composing its chooser, editor and saved details for both surfaces. Configuration, rules, discovery settings and publisher lifecycle similarly keep proposals, captured revisions, review tokens and receipts in their explicit LiveViews. They preserve existing reconnect contracts and make the need for another review visible.

## Evidence and verification

Result health, collection freshness and runner contact remain independent. A result's frozen measured configuration belongs to its confirmed generation, which may differ from the last fully measured shared execution after partial collection. Saving settings, retrying transport or receiving old evidence does not create a new measurement. Webhook secrets are excluded from UI and prompt output.

Follow [UI conventions](UI-CONVENTIONS.md) for shared-body parity, density, vocabulary and accessibility. The native route manifest verifies page ownership, the single session and intentionally separate API/Git/download endpoints. Entity parity tests use the same persisted identity in both surfaces; navigation tests exercise deduplication, captured revisions, recovery and inactive-owner rejection. Frontend tests cover the chip picker, row selection and stack behavior. [Acceptance coverage](ACCEPTANCE-COVERAGE.md) lists packaged real-runner and browser journeys. Build success alone does not establish an operator workflow.

## Layout follow-up

Maintenance scheduling can make better use of horizontal space in its schedule fields. Keep date/time values readable and retain the shared layout between panels and full pages when refining those controls.
