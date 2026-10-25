# Reviewing discovered resources

A check can attach structured discovery evidence to a measured result. Its author declares the candidates, available choices and optional scalar parameters. Mondek displays these declarations without importing consumer code or knowing whether a resource is a container, filesystem, backup plan or something else.

## Operator workflow

1. Open the discovery check's result and choose **Review discovered resources**.
2. Select individual candidates and a proposed action for each. Complete any author-declared fields, such as failure severity or a capacity threshold.
3. Review the selected proposals, then generate and copy the agent prompt. The prompt includes candidate details, selected values and source/evidence identity; inspect it before sharing.
4. Ask a coding agent working in the consumer project to prepare the source change. Review its diff and tests.
5. Publish the reviewed consumer source through the usual runner deployment. Only that publication changes declared monitoring. The next measurement establishes actual health.

Selecting a choice does not accept a resource, create a check, acknowledge an incident or apply project policy. Unselected candidates remain unchanged. The controller provides no automatic “accept everything” operation. Existing scalar project policy can adjust parameters on declared checks; it cannot create their membership.

## Evidence and drafts

Review requires fresh confirmed evidence from the current desired configuration. A collection failure preserves the last discovery for inspection but disables proposals, as do stale evidence and retired results. A new measurement without discovery replaces the old evidence rather than retaining obsolete candidates.

Repeated identical scans preserve the draft even though their observation IDs and times change. Changes to discovery content, source revision, configuration generation or result identity require an explicit reload and a new review. LiveView reconnect recovers a bounded signed draft snapshot; signing prevents client alteration of that snapshot, not changes to the real resources. A generated prompt is a proposal based on a point-in-time observation. Its instructions require checking current source and identities before editing.

Discovery is stored in the ordinary immutable observation payload, with existing evidence retention and size limits. There is no separate controller inventory, candidate database or durable acceptance state. Very large discoveries report an omitted count rather than silently claiming completeness. Consumers should use stable logical resource keys, deterministic ordering and concise non-secret details. Avoid volatile timestamps or IDs in discovery metadata when they add no review value, since changed content deliberately invalidates the draft.

See [the typed authoring API](DISCOVERY-SDK.md) and [the discovery example](../examples/consumers/src/mondek_examples/discovery_demo.py). Consumer-defined choices are the extensibility boundary; the controller does not define Required, Ignored or Docker-specific behavior.
