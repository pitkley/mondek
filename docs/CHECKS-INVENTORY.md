# Browsing check results

Checks lists the independently reported results supplied by your runner code. A scheduled check can produce more than one result; each row retains its own target, measurement age and health. Switching views does not change evidence or the check author's incident-grouping declarations.

## Choose a task and a view

All results starts **By target**. Needs attention, Critical and Measurement gaps start in **List** so you can scan matching problems together. The View switch changes presentation without changing which results match. Each task remembers your manual choice in the URL, including across reload, browser reconnect and a return from result details. Changing search or scope keeps the current presentation. Live measurements never trigger an automatic layout switch.

Needs attention includes measured Warning/Critical results and missing current evidence. Critical filters last measured health, including retained Critical evidence that is now stale. Measurement gaps includes stale, unavailable or awaiting evidence; it is not a list of unhealthy measurements. Retired membership is available under More filters and remains historical.

## Overview attention

Overview shows up to eight results with problems still needing attention, using the same compact result table as Checks. An active acknowledgement removes its covered problem from this list. It does not hide a separate unacknowledged problem on the same result: an acknowledged disk failure can still appear when monitoring becomes unavailable, and acknowledging that monitoring loss does not acknowledge the disk failure. Ending or expiring an acknowledgement makes an unresolved problem eligible again.

The complete Checks inventory and its filters retain acknowledged results. Measurements, incident history and overall inventory counts are unchanged. Follow an Overview result into its details and use **Back to overview** to return. The Incidents navigation counts use the same unacknowledged open totals throughout the application, with monitoring loss shown separately.

## Follow a target

A target is the subject being measured, not necessarily the machine hosting the runner. Its identity includes the monitoring source, monitored environment, kind and stable key. Same-named targets from different sources or environments remain separate. Each row names its observing runner; ambiguous labels retain distinguishing identities.

By target pages the target index twenty at a time, and pages the selected target's matching results independently. The selected target remains stable as new evidence changes the ordering. Changing target pages selects a target from that page. If the selected target no longer matches or is withdrawn, the view selects an available target and updates the URL.

A heading such as **2 of 120 results match** discloses that the current filters hide other observations for that target. The total follows the membership selection and exact target identity, including other observers. Per-group continuation text identifies when a result page contains only part of the matching group.

**Show all observations of this target** expands the investigation to that exact subject, removing search, runner, health and freshness filters while retaining the membership selection. Source, monitored environment, target kind and stable key remain part of its identity: the same name in another project or environment does not belong to this context. Each observing runner still has independent evidence; a healthy observation cannot replace another observer's stale or failing result.

The target context remains explicit while changing views, paging, inspecting a result or reconnecting. Further filters and task counts apply within this target. **Back to filtered results** restores the original investigation, including its filters, view and page. Leaving target context is a separate action. If no results remain in scope, the page stays empty rather than choosing another target.

## Inspect evidence

Open a result for the complete summary, original measurement details, incident history and configuration context. Long inventory summaries are compact previews. Retained verdicts say **Last:**; freshness and original measurement age remain separate. A recent runner contact, saved configuration or browser reconnect cannot make evidence fresh.

Search covers check/result names, source/target identities and observing runner labels. Monitored environment accepts a listed ID or an entered ID. **Clear** removes search, environment and runner scope while preserving the current task and view. **Clear all filters** in the empty state returns to All results. More filters exposes exact health, freshness and membership choices.

## Local verification

Start the real application with `devenv shell -- mondek start` and open [Checks](http://localhost:4001/checks). The existing monitoring project supplies its results; the UI does not create checks. Use `devenv shell -- mondek demo` for the three packaged local checks.

Run `devenv shell -- python3 tests/browser/run.py --suite inventory` for real two-observer failure/recovery/reconnect journeys, and `--suite parity` for hundreds of real results and targets. These suites create isolated Compose projects and preserve normal installation data. See [the acceptance guide](../tests/e2e/README.md) for scenario coverage and limits.
