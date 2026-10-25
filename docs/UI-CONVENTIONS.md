# Operator UI conventions

Use these conventions when extending Mondek's existing interfaces. They preserve the approved light navigation, blue accents and compact evidence presentation; they do not introduce a new UI framework.

## Visual hierarchy

- Lead each page with its stable section heading, then view tabs, then the selected view's content. Changing a tab must not unexpectedly replace a heading above it.
- Put the operator's current task first: evidence during investigation, fields during editing, scope and changes during review, and the exact saved versions during adoption.
- Keep source identity, raw configuration, timing provenance and other secondary details in clearly named disclosures. Keep check-authored measurement details expanded on result detail.
- Reuse existing components, spacing and color tokens before adding a page-specific variation. Avoid repeated summary panels that compete with the primary result or action.
- Retain the explicit List / By group switch. Do not automatically change layout when live result counts cross a threshold.

## Vocabulary

| Primary wording | Meaning |
| --- | --- |
| Mondek server | The central web application, result/configuration storage and notification delivery; implementation references also call it the controller. |
| Monitoring project | The user-owned Python package defining monitoring; SDK/CLI references also call it a consumer package. |
| Mondek installation | A server and its attached runners; separate from monitored environments and runner execution contexts. |
| Result | One independently identified measurement stream. |
| Scheduled check | One scheduled execution and shared parameter set; it may produce several results. |
| Target | The monitored subject, identified by source, monitored environment, kind and stable key. |
| Monitored environment | The environment the result describes. It need not be where its runner executes. |
| Observing runner | The runner installation producing this evidence. Keep “Runners” as the navigation label. |
| Execution context | The runner's source-owned deployment context and capabilities. |
| Shared rule | Reusable settings for an explicit scope, including future compatible checks. “Configuration rules” remains the page name. |
| Instance exception | A complete parameter set attached to selected scheduled-check instances, taking precedence over rules. |
| Defaults from code | The latest accepted defaults declared by the check's source. |
| Declared compatibility | Source and explicit parameter contract, with schema compatibility checked during review. Similar labels or field names do not prove compatibility. |

Use technical protocol names where they help an author inspect a declaration, rather than as the only explanation of an operator action. Be precise about counts: checks, results, targets, runners and incidents are different units.

## Evidence and operational state

- Present measured health and freshness independently. Retained Healthy evidence can be stale, and recent runner contact does not prove successful collection.
- Keep the original evidence age visible. Retry, reconnect and receipt of buffered evidence must not imply a new measurement.
- Keep observations from different runners independent, even when they describe one target. One healthy observer does not replace another observer's failure or stale result.
- Acknowledgement and maintenance hold failure notifications within their scope; neither means recovery, and recovery notifications can still be delivered. Preserve visible scope, expiry or until-resolution semantics, and whether later incident contributors are included.
- “Saved”, “prepared”, “active” and “measured” describe different adoption stages. Measured evidence can subsequently become stale. A superseded saved version is not proof that it executed.

## Color and emphasis

- Use the shared blue accent for navigation, links, primary actions, selected controls and keyboard focus.
- Use neutral or informational styling for instructions, restored drafts, examples and scope explanations; these are not evidence of health or success.
- Reserve success, warning and error colors for their semantic states. Keep Healthy, Warning, Critical and unavailable/stale distinctions consistent with existing badges and explanatory text.
- Pair color with readable labels. An acknowledged incident must remain visibly acknowledged without removing its open or measured-severity indication.

## Scope and configuration

- State which existing checks/results match, which leave a previous scope, which are excluded, and which exceptions or conflicts prevent the proposed values from taking effect.
- Distinguish a fixed bulk selection from a shared rule. Bulk exceptions cover those instances; rules can include future compatible checks.
- Keep exact target identity through investigation and return navigation. An absent or unknown selected target must not silently select another one.
- A target-wide action spans matching observers; an observer filter used to find the target does not redefine that target's scope.
- Preserve check-owned settings and multi-result execution boundaries. The UI configures delegated values; runner code defines monitoring membership.
- Include declared units when editing or comparing values, including confirmation and exception-removal previews.

## Narrow screens and accessibility

- Keep result identity, observing runner, monitored environment, health, freshness and evidence age visible at narrow widths without discovering horizontal scrolling. Reuse labeled mobile rows for result evidence; keep the compact desktop table. Horizontal scrolling may support secondary technical data, but must not be required to identify whose observation is stale.
- Make active editing, review and saved-progress steps easy to reach without scrolling through a long unrelated inventory first.
- Preserve visible keyboard focus, meaningful headings, table relationships, associated field labels and readable wrapping of long identifiers.
- Verify representative desktop and 320/390px workflows with real browser evidence. Automated accessibility checks and agent review do not replace human comprehension testing.

## Code-first setup and agent help

- Start onboarding from an installable monitoring project, source-owned checks, runner placement and deployment context. Do not imply that checks must be created in the controller UI.
- Reuse the existing copyable agent-prompt component. Keep prompts task-specific, include relevant identities and evidence context, and identify placeholders the operator must supply.
- Preserve the distinction between authoring check behavior, configuring delegated values and applying deployment secrets. Never include secret values in prompts or examples.

Source-defined check groups organize browsing only; exact targets remain visible and retain their configuration, maintenance and investigation semantics. Use “group” for this navigation and “shared condition” for incident correlation. See [check groups](CHECK-GROUPS.md) for scoping and live-index behavior.

## Page ownership

OverviewLive, ChecksLive, ResultLive, IncidentsLive, IncidentLive, ConfigurationLive and GuideLive own their respective route state, event handlers and bounded refresh queries. Shared evidence/presentation functions live in MonitoringUI and the existing domain components. Keep page-specific drafts and controls in their owning LiveView rather than growing another multipage dispatcher. Pages intentionally refresh on a one-second timer; they do not subscribe to the high-volume monitoring broadcast only to discard it. Explicit actions still refresh immediately, and clock/freshness updates remain independent of source traffic.
