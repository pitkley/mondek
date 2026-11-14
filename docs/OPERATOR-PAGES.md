# Configuration and runner inspection

## Follow a configuration change

Configuration lists scheduled checks, not individual result streams. Use the chip search to filter by inventory state, adoption stage, monitored environment or observing runner, or type ordinary text. The default Active checks chip can be removed to include retained checks. Filtering applies before pagination. Installation-wide adoption counts remain complete; choosing a stage from that summary clears other filters and fills the corresponding chip.

Open a check to inspect its scope, saved version, complete parameter set, provenance and results. Saved, prepared, active and measured are different milestones. A measured version produced complete fresh evidence at least once; inspect its results for current freshness and health.

Edit delegated fields, review the complete proposed values and confirm the save. Individual edits create or replace an instance exception. The values are not merged field by field with rules or defaults. Removing an exception has its own review showing which complete values will replace it. Source-owned and retired checks remain inspectable without editable fields.

Related results and runners open in the shared investigation stack while the configuration owner retains its draft and captured revision. Expanding evidence to a page and returning to the editor preserves that state. Reconnect recovers bounded draft values and the original revision, but requires a new review; a concurrent save still rejects stale authority.

For a fixed bulk edit, select a check and add compatible instances. Clicking the row toggles its checkbox. Checks hidden by a new filter or inventory page remain selected and appear below the matches with their original captured revisions and removable checkboxes. Long retained selections have their own numbered pages. Editing all compatible matches captures today's membership; it does not add future checks. Review each complete parameter set and the exact effects before saving. Saved progress follows those exact versions through adoption, including superseded or retired checks. Use a shared configuration rule for settings that should also apply to future compatible checks.

## Investigate collection and delivery

Runners & delivery starts with installation-wide fresh-result coverage and outstanding notifications. Each runner shows its own active result coverage independently of its last controller contact. Follow Pending, Stale or Unavailable counts to the corresponding results. Fresh Critical measurements count as coverage: the runner is reporting a problem it observed.

Collection diagnostics contain the last reported queue and scheduler values. Missing values read Not reported. Buffered reports, reported loss and checks waiting to execute are surfaced above that disclosure when nonzero. A retained diagnostic may describe an earlier failure; compare it with current measurement coverage and controller contact.

Inspect notifications jumps directly to delivery work. Exhausted automatic retries have a direct filtered link. Delivery attempts, worker jobs and retention information remain inspectable without dominating the initial view. Notification delivery remains installation-wide even when the page shows one selected runner.

The ordinary runner list displays up to one hundred runners and states its scope. Links from a pending configuration open the owning runner directly, including owners beyond that list. Notification filters and detail/back navigation preserve that selected runner; Show all runners returns to the ordinary list.
