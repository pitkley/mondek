# Mondek 0.0.7

Controller and SDK versions are both `0.0.7`, with Git tag `v0.0.7` and controller image tag `0.0.7`. Mondek remains experimental. Run matching controller and SDK versions.

## Monitoring and investigation

- Outputs can specify `sustain_seconds` to require advancing fresh measurements across a duration before WARN or CRIT qualifies for incident handling. The controller retains reported health and shows qualification separately. See [per-output failure sustain](OUTPUT-SUSTAIN-DESIGN.md).
- Result inspection links measurements across Condition changes when the output keeps its identity. Each measurement identifies its original stream and generation. Incidents and exact evidence remain scoped to their original stream. See [result detail](RESULT-DETAIL.md).

## Runner

- The worker budgets optional details within the encoded capture limit, preserving required facts and the verdicts of sibling outputs. The SDK's `bounded_details` helper marks omissions in large lists and diffs. See [worker evidence budgeting](WORKER-EVIDENCE-BUDGET.md).
- An opt-in Linux warm-worker prototype preloads verified consumer code and runs each check in a disposable process. The local ARM64 benchmark met both CPU targets with per-execution verification enabled. Qualify the actual consumer and deployment before adopting it. See [warm workers](WARM-WORKER-PROTOTYPE.md).

## Upgrading

Back up PostgreSQL and complete runner state directories, then upgrade the controller and SDK together. Packaged startup adds two migrations for sustain state and measurement lineage. The lineage backfill uses retained Condition-change audit records and preserves original evidence and stream identities. See [upgrade guidance](UPGRADING.md#007-output-sustain-and-measurement-lineage).
