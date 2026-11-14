# Operator UI conventions

Use these conventions to keep navigation, interaction and compact evidence presentation consistent across the operator interface.

The [operator interface](UI-ARCHITECTURE.md) uses PatternFly HTML/CSS with LiveView and the Pearl palette. There is one root layout and one JavaScript/CSS entry; all operator routes use the same UI.

## Visual hierarchy

Treat exposed canvas text as a sign that content may be missing its parent section. Put filters in a list's toolbar, pagination in its footer, and headings, counts, empty states and explanations on the same surface as the content they describe. Use canvas space to separate coherent sections; avoid a separate card for every label. Summary and list columns should share a grid and content inset so comparable information lines up.

- Lead each page with its stable section heading, then its filter toolbar and named content sections. Filters belong in the shared chip search; show applied defaults as removable chips.
- Put the operator's current task first: evidence during investigation, fields during editing, scope and changes during review, and the exact saved versions during adoption.
- Keep source identity, raw configuration, timing provenance and other secondary details in clearly named disclosures. Keep check-authored measurement details expanded on result detail.
- Reuse existing components, spacing and color tokens before adding a page-specific variation. Avoid repeated summary panels that compete with the primary result or action.
- Use compact result tables and explicit Group/Target filters. Do not change layout automatically when live result counts cross a threshold.

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
- Register URL-owned presentation fields in the shared return-path allowlist, including historical event/evidence selection and copy/schema seeds. Test editor round trips through the rendered Back links, preserving exact identities and filters; direct navigation to the expected destination does not prove that return context survived.
- A target-wide action spans matching observers; an observer filter used to find the target does not redefine that target's scope.
- Preserve check-owned settings and multi-result execution boundaries. The UI configures delegated values; runner code defines monitoring membership.
- Include declared units when editing or comparing values, including confirmation and exception-removal previews.
- Exercise realistic LiveView change and recovery payloads in form tests, including empty `_unused_` markers for untouched inputs. Separate recognized framework metadata from declared values while retaining unknown-key, type, size and captured-revision validation.

## Narrow screens and accessibility

- Keep result identity, observing runner, monitored environment, health, freshness and evidence age visible at narrow widths without discovering horizontal scrolling. Reuse labeled mobile rows for result evidence; keep the compact desktop table. Horizontal scrolling may support secondary technical data, but must not be required to identify whose observation is stale.
- Make active editing, review and saved-progress steps easy to reach without scrolling through a long unrelated inventory first.
- Preserve visible keyboard focus, meaningful headings, table relationships, associated field labels and readable wrapping of long identifiers.
- Check overflow inside cards as well as the document: a clipping surface can conceal unreadable content. Keep inventory mobile-row rules from changing embedded fact-table cells, and allow long nested labels to wrap at narrow widths. Focus a revealed card’s heading rather than its entire tall section so the title stays visible.
- Verify representative desktop and 320/390px workflows with real browser evidence. Automated accessibility checks and agent review do not replace human comprehension testing.

## Code-first setup and agent help

- Start onboarding from an installable monitoring project, source-owned checks, runner placement and deployment context. Do not imply that checks must be created in the controller UI.
- Reuse the existing copyable agent-prompt component. Keep prompts task-specific, include relevant identities and evidence context, and identify placeholders the operator must supply.
- Preserve the distinction between authoring check behavior, configuring delegated values and applying deployment secrets. Never include secret values in prompts or examples.

Source-defined check groups organize browsing only; exact targets remain visible and retain their configuration, maintenance and investigation semantics. Use “group” for this navigation and “shared condition” for incident correlation. See [check groups](CHECK-GROUPS.md) for scoping and live-index behavior.

## Page ownership

LiveViews own list queries, URL state and explicit editing workflows. InvestigationStack owns the active typed entity and its retained controls. Do not forward another LiveView’s callbacks or create a second state owner for the same entity. Refresh bounded evidence on controlled ticks; explicit actions refresh immediately. Keep captured drafts and revisions independent of refreshed evidence.

## Detail surfaces

Use the same entity detail body in the fly-over and full page. Shells own headings, layout, focus and navigation. The entity body owns facts, relationships, errors and actions. Entity state and permissions determine which actions are available. A compact fly-over may start with fewer history rows if the rest are reachable in place. Preserve the owning LiveView’s draft and validated return context when switching presentation. Keep only the active body interactive.

Every new or changed detail pair must include a LiveView parity test against the same persisted entity in both routes. Scope assertions to the active detail body and assert the expected sections, evidence, relationship links and eligible actions in each. Include a representative actionable state when the entity supports actions. Assert intentional differences separately, including how to reach any rows collapsed initially. Compare capabilities rather than whole HTML, route strings that legitimately differ, or volatile timestamps. When adding a capability to a shared body, extend the corresponding parity test.

## Shared components

| Primitive | Use | Keep with the entity or workflow owner |
| --- | --- | --- |
| `PreviewDetail.heading` | Focusable entity headings with the appropriate page or panel level. | Captions, badges and surrounding evidence. |
| `PreviewDetail.surface` | Dialog attributes, card classes and the panel body wrapper. | Routes, toolbar actions, focus and stack navigation. |
| `PreviewDetail.card` / `PreviewDetail.facts` | Bordered sections and tables with row headers. | Column widths, disclosures and specialized tables. |
| Status labels | Consistent visual tone and label markup. | The mapping from domain state to operator wording and tone. |
| `PreviewResultDetail` | The canonical result body across Overview, Checks, Incidents and Coverage. | Bounded evidence from PreviewResult and explicit relationship destinations. |

Reuse PreviewFilters, PreviewPagination, PreviewDetail and PanelStack as the starting primitives. Keep incident acknowledgement, maintenance review and notification delivery workflows entity-specific.


## Component ownership

Canonical entity bodies render within InvestigationStack on pages and panels. InvestigationTrail handles typed links, root participation, bounds and identity deduplication. InvestigationEntity loads bounded evidence; PreviewIncidentControls performs named acknowledgement and retry operations. The stable stack component retains entity drafts and captured revisions and validates active identity before events; domain contexts remain the write authority. See [architecture](UI-ARCHITECTURE.md) for the full ownership and recovery contract.

MaintenanceLive composes PreviewMaintenanceChooser, PreviewMaintenanceEditor and PreviewMaintenanceDetails. It owns the proposal, captured revisions, review tokens, selection recovery and all mutations. MaintenancePresentation contains read-only formatting and local-link helpers shared by those templates. Chooser filter fields and chips come from the owner so the displayed defaults follow the same definitions as the accepted options.

Keep picker application local to each owner. Overview options have key-and-kind identity and database suggestions; incident and Maintenance options have their own matching, clearing defaults and draft-versus-URL application. Use ScalarFilterPicker for repeated scalar suggestions and chip labels. The shared filter component and keyboard hook define the interaction contract; option loading, defaults and application remain explicit in each owner.
