# Configuration and runner inspection

## Follow a configuration change

Open a scheduled check from Configuration. The saved version's adoption status appears above its parameters: saved, prepared, active or measured. A measured version has produced complete fresh evidence at least once; inspect its results for current freshness and measured health. While adoption is pending, follow the result or runner links to investigate collection and connection problems.

Edit the fields declared by your check code, review the complete values and scope, then confirm the save. Editing or reviewing alone changes no saved settings. Saving an individual edit creates an instance exception when parameters are delegated to the operator. The page explains whether the values come from a rule, an exception or source defaults. Detailed adoption stages and source information are available in disclosures. A draft is not a saved version; validation and concurrent-edit errors remain next to the form.

The Configuration list's stage shortcuts cover the entire installation and clear other filters. Use the ordinary filters to narrow a stage to one runner or environment. To edit compatible checks together, select a check's checkbox; the bulk selection and review controls then appear. Clearing the selection and draft returns to the compact starting view.

## Investigate collection and delivery

Runners & delivery starts with installation-wide fresh-result coverage and outstanding notifications. Each runner shows its own active result coverage independently of its last controller contact. Follow Pending, Stale or Unavailable counts to the corresponding results. Fresh Critical measurements count as coverage: the runner is reporting a problem it observed.

Collection diagnostics contain the last reported queue and scheduler values. Missing values read Not reported. Buffered reports, reported loss and checks waiting to execute are surfaced above that disclosure when nonzero. A retained diagnostic may describe an earlier failure; compare it with current measurement coverage and controller contact.

Inspect notifications jumps directly to delivery work. Exhausted automatic retries have a direct filtered link. Delivery attempts, worker jobs and retention information remain inspectable without dominating the initial view. Notification delivery remains installation-wide even when the page shows one selected runner.

The ordinary runner list displays up to one hundred runners and states its scope. Links from a pending configuration open the owning runner directly, including owners beyond that list. Notification filters and detail/back navigation preserve that selected runner; Show all runners returns to the ordinary list.
