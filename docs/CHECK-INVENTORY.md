# Browsing check results

The Checks page groups independently measured results by their declared monitored target. A host group can contain disk, process and application checks when those results explicitly name the same host target. Websites, services, files, calendars and volumes keep their own meaningful target identities. The runner is the observer, which can be somewhere else entirely.

## Identity and scope

A group uses the source ID, monitored environment ID, target kind and target key. Display-name changes preserve its identity; identical display names alone do not combine targets. Two runners reporting that exact identity appear in one group with separate result rows. Their measurements, configuration, incidents, acknowledgements and notification lifetimes remain independent.

Source namespaces prevent unrelated monitoring projects from accidentally sharing consumer-chosen target keys. An unspecified environment is distinct from every named environment. Retired results retain the environment and target they actually monitored. Historical results without complete identity remain separate.

The current SDK target declaration has `key`, `label` and `kind`. It has no parent-host field: a disk, file or service modeled as a separate target therefore remains a separate group. Mondek does not infer containment from the runner, a target-key prefix or a similar display name. Explicit host-child navigation and its relationship to whole-host maintenance remain in the work queue. A movable volume keeps its own target identity as its observers change.

## Reading health and coverage

Groups with active Critical results appear first, followed by Warning, visibility gaps and fresh Healthy results. Within each group, results follow the same priority; retired results come last. Ties use deterministic labels and identities. Live measurements can change ordering as the situation changes.

For groups with several matching results, the heading summarizes **last measured health** separately from **freshness**. A retained Critical measurement can also be stale; it contributes to both summaries. A result without confirmed evidence says Not measured, whether it is awaiting its first run or its executions have failed or returned stale input. An Unknown execution outcome remains available in execution evidence; it does not establish measured health. A disconnected runner or missing output does not remove expected results or establish recovery. Retired is a membership state, not a healthy measurement.

Each result identifies its observing runner and links to the result's evidence and the scheduled check's configuration. Same-named runners are distinguished by installation ID. Compact singleton groups show their health and freshness directly in their one result row.

## Filters and pages

Search, runner, monitored environment, health, freshness and membership filters apply to the full stored inventory before sorting and pagination. Group summaries count **all matching results**, including matching rows on another page. A filtered summary describes that selection, not the health of every result for the target.

Use the **Not measured** health filter to find results that have never established confirmed health, independently of their freshness. Pending freshness also includes results awaiting a new session or configuration after an earlier confirmed measurement. Failed collection after a confirmed Critical measurement still matches Critical health and Unavailable freshness. The existing API value `health=UNKNOWN` remains accepted and requires confirmed provenance; ordinary Unknown execution outcomes do not match it.

Choose 10, 25, 50 or 100 results per page above the list; the default is 50. A short page is useful on a phone or when browsing many separately targeted results. Changing size starts at page one and retains your filters. Clearing filters retains the chosen size. Previous and Next are available above and below the results; using either moves keyboard focus to the beginning of the list. Changing a filter or page size keeps focus on that control, and a slow pager response does not interrupt a newer interaction.

A large group can span pages; each continuation repeats its complete matching summary and explicitly shows its range, such as results 11–20 of 120 on a ten-result page. Group counts still include every matching result. Unchanged data has stable page membership, while arriving measurements or inventory changes can naturally move results between pages. Filtering further is useful when following a changing fleet. Opening a result or its configuration preserves the filtered return location; reload and reconnect retain the URL's filters, page and size. This preference is part of the Checks URL, not an installation-wide setting; Configuration and Incidents retain their own paging.

This is a navigation feature. Combining related failures into one incident is separate work; a visual group does not create shared acknowledgement, recovery or maintenance semantics.
