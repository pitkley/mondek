# Reading a result

Result detail starts with the monitored target, its environment and the runner that observes it. The main panel presents the last confirmed measurement: its verdict, the check author's summary, the original measurement age and any diagnostic details. Details are expanded by default. Check details support Markdown formatting. Links and images appear as text, and raw HTML stays inert. The fly-over initially shows four previous measurements and can expand older measurements in place. The full result page shows the recent history together.

For a sustaining output, **Qualified health** identifies the severity and observation used for incident handling. **Pending sustain** shows each threshold that is still accumulating fresh evidence. **Latest measurement** shows the reported result, including a failure that is still pending.

## Health and collection are separate

| Situation | What result detail shows |
| --- | --- |
| A fresh complete result | Its confirmed health, explanation and source age. |
| A later execution fails or omits this result | A separate collection notice and diagnostic above the retained measurement. The failed attempt does not refresh the earlier evidence. |
| The first execution fails | Not measured, with the collection failure explained separately. A fallback Unknown state is not presented as a confirmed measurement. |
| Evidence becomes overdue | A freshness notice; any confirmed health remains historical evidence about the target. |
| A new runner session or configuration is awaiting evidence | Pending coverage, with any earlier confirmed measurement retained under its own version and age. |
| Monitoring is intentionally retired | Retired membership and historical evidence. Retirement does not imply recovery. |

A check can produce independent results. One valid output can remain fresh while a sibling output is missing; each result's main panel follows its own accepted state. Shared execution diagnostics remain available in execution evidence.

The inventory and overview use the same confirmed-measurement distinction. **Not measured** in the health filter finds results with no confirmed observation, including both first-run pending results and unsuccessful collection. A later failed attempt does not move an already confirmed Critical result into this filter. Individual execution evidence still shows the consumer's reported Unknown outcome when applicable.

## Inspecting further

Expand **Measurement timing & configuration** for the result's confirmed version, observation/session identity and original source/evaluation/receipt times. Historical parameter values and units come from that version's frozen definition. After partial collection, this result can confirm a newer version than the last fully measured shared execution; each surface names that distinction.

Related incidents and the observing runner open in the same investigation stack. **Shared execution and history** shows sibling results, collection diagnostics, saved settings versus the last fully measured execution, source provenance, incident history and scoped operator controls. Original reports remain secondary evidence with their ingestion disposition and individual source timestamps. Opening related evidence from a full page uses the same stack behavior as a list panel.

Maintenance links preserve single-result scope. A selected scheduled check instead covers all its produced results; review states the precise scope before saving. Current/upcoming windows and their series remain inspectable, and history remains reachable after they end. Acknowledgement and maintenance change notifications while checks continue.

Incident details lead with recorded failure evidence and shared-incident contributors where relevant. Measurement history preserves opening and closing evidence without presenting it as a new current result. Operator controls, maintenance and notification delivery remain distinct sections; webhook destinations are represented by configured receiver identifiers rather than secret URLs. Safe, manually copied investigation prompts include identities and status, excluding raw result details and parameters.

Schedules use ordinary durations such as “6 hours” or “1 minute 1.25 seconds.” Stored precision remains intact. See [UI architecture](UI-ARCHITECTURE.md) for canonical body ownership and [missing measurements](MEASUREMENT-INVESTIGATION.md) for collection diagnosis.
