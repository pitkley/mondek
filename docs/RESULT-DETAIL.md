# Reading a result

Result detail starts with the monitored target, its environment and the runner that observes it. The main panel presents the last confirmed measurement: its verdict, the check author's summary, the original measurement age and any diagnostic details. Details are expanded and rendered as plain text, preserving line breaks without executing HTML or interpreting Markdown. Long explanations wrap and have a keyboard-accessible scrolling area.

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

The measurement's exact source/evaluation times, latest accepted execution and receipt times, configuration versions and freshness limit are under **Measurement timing & configuration**. These timestamps describe different events. Receipt of an old report never makes its source measurement new.

Open incidents remain directly accessible below the measurement. Past incidents, operator controls and execution evidence are secondary disclosures. Execution evidence is shown in receipt order and can begin with a delayed historical report; it is not labeled as the latest accepted execution. Original reports and historical check details remain inspectable without replacing the primary confirmed explanation.

An incident leads with **Latest measurement**, using the same expanded human-readable findings and independent health/freshness presentation. New measurements can change the explanation while an incident remains open, and a closed incident can show a later check state. **Incident measurement history** is a collapsed secondary section with explicitly labeled opening, later and recovery measurements; it preserves the incident evidence without presenting it as current. Where the latest confirmed result carries structured discoveries, **Review discovered resources** is available directly from the measurement and returns to the incident after review. Open incident pages provide a header shortcut to the acknowledgement form, including on narrow screens; following it does not submit a control. An acknowledgement or maintenance window changes notification handling, not measured health.

Schedules use ordinary durations such as “6 hours” or “1 minute 1.25 seconds.” Stored precision remains intact. Configuration, acknowledgement, maintenance and notification semantics are unchanged by this presentation.

Use **View check** in the incident header to open the exact result, then **Review configuration** to inspect its scheduled check's settings. Back links return through the result to the incident and its original browsing context. Shared incidents provide a **View result now** action for each independent contribution.
