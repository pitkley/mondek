# Check results

**Checks** is the complete inventory of independently identified results. Each row keeps its own target, monitored environment, observing runner, last measured health, collection freshness and original measurement age. Results reporting one target from different runners remain independent. A shared execution or browsing group does not create a combined target verdict.

Use the shared search box for free text and chips: Group, Target, Environment, Runner, Source, Health, Measurement and Inventory. Applied defaults appear as chips. Suggestions search stored identities before their menu limit, so an item outside the first menu remains discoverable. Exact target filters use kind and key; environment and source remain distinct filters. Group suggestions identify their source and environment to distinguish equal names.

Filters apply before ordering and pagination. Results needing attention come first, with measured severity and collection gaps visible together; healthy current results follow and retired evidence remains available through Inventory. A retained Critical result can be unavailable or overdue. **Not measured** means there is no confirmed health, independently of contact or a failed execution. Unknown execution output does not establish measured target health.

The compact list uses numbered pagination with stable control positions and 30 results per page. Filters and page are recorded in the URL. New evidence can naturally change priority and page membership. Opening a row adds its evidence over the current list; browser Back, reload and reconnect retain validated URL context. The same body is available as a dedicated result page. Following a related incident, runner or shared execution uses the investigation stack, and returning to an existing identity reactivates its earlier card.

Scheduled-check configuration affects its shared execution and all produced results. Maintenance can cover a single result, one scheduled check or an explicitly selected target; the review states the actual scope. See [result details](RESULT-DETAIL.md), [UI architecture](UI-ARCHITECTURE.md) and [maintenance](MAINTENANCE.md).
