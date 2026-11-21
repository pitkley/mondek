# Measurement lineage across Condition changes

Changing an output's Condition identity opens a new result stream. The previous stream still owns its observation generations, incidents, controls, and delivery history. Operators can follow both streams as one measurement timeline when they observed the same output.

## Continuous identity

Record a predecessor edge when the same inventory reconciliation retires and replaces an output because the Condition namespace or key changed, including addition and removal. Require the same assignment and output key, target kind/key, and monitored environment. The outgoing stream's retirement generation must equal the successor's admission generation. Label changes preserve the existing stream. A target or environment rebind, output withdrawal and later reintroduction, or assignment replacement starts a separate timeline.

Persist the edge with the new stream in the inventory transaction. The relationship has at most one predecessor and successor. Only strictly earlier admission generations can be predecessors. For existing rows, start with boundaries having exactly one outgoing and one incoming row for an assignment/output. Require the outgoing stream's recorded Condition-change control and then apply all scope and Condition checks. This leaves administrative retirements and older boundaries with pruned audit evidence unlinked.

## Inspection and retention

Show recent measurements from the selected stream and its predecessors in the shared result detail. Walk only backward, preserving the meaning of a historical stream's URL. Select observations by the owning stream's half-open generation interval and filter for the actual output key before applying the limit. Order by controller receipt time and observation ID. Each row identifies its original stream and generation. An older generation received after cutover retains its historical disposition and original owner.

Expose the predecessor and timeline through result inspection. The direct predecessor link stays visible when recent measurements fill the timeline. Exact observation and general execution evidence endpoints stay scoped to the requested incarnation. The timeline gives the exact evidence path on each row's owning stream. Existing incident, control, delivery, current-state, qualification and retention queries keep their respective stream boundaries. An edge does not protect ordinary receipts beyond existing retention.

## Verification

Cover Condition addition, key change, removal and reintroduction, label-only changes, and a simultaneous Condition and target or environment rebind. Verify historical backfill and the absence of links across removed membership. Ingest a late old-generation report and recent sibling-only reports, then verify measurement ordering, original ownership, exact evidence scope, and shared fly-over/full-page rendering.
