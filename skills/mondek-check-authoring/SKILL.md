---
name: mondek-check-authoring
description: Write or modify Python checks in a Mondek monitoring project, including datasource injection, multiple results, declared coverage and delegated settings. Use for monitoring logic and check tests, rather than installing servers or deploying runners.
---

# Write Mondek checks

Locate the monitoring project and its selected installed SDK release. References below identify matching Mondek repository documentation, available online or in a source checkout; a checkout is not required to author checks. Read docs/SDK.md and the relevant parts of runner/README.md; inspect actual installed exports/signatures before adding an unfamiliar API. Use docs/CONCEPTS.md for server, runner, monitored environment and target vocabulary.

## Preserve meaning and identity

Establish what is measured, where its data can be collected, expected output keys, health boundaries, failure semantics and freshness needs. Inspect existing project helpers and tests first. Reuse ordinary Python functions/classes/libraries for domain policy; Mondek does not require a built-in check type for every use case.

Preserve source/check/output/target identities when the monitored subject and meaning stay the same. Labels are presentation. A scheduled invocation can emit multiple independently tracked results but remains in one monitored environment; use separate bindings for different environments. Read docs/MULTI-ENVIRONMENT-CHECKS.md or docs/RUNNER-CONTEXTS.md when those distinctions matter. Do not infer monitored identity from the machine executing a remote datasource check.

Use stable `expected_keys`/Output declarations and explicit coverage where needed. Missing data or failed discovery must not make expected monitoring disappear. Distinguish collection failure/UNKNOWN from a real negative measurement, and preserve valid sibling results on partial failure. Do not report recovery from retained old health or invent a fresh source timestamp for cached evidence. Datasource reads need their own bounds in addition to the runner's process deadline.

## Implement and test

Use `summary` for a concise verdict or count and `details` for human-readable findings: affected resources, observed values, units, thresholds and useful collection context. Preserve structured discovery/impact data for workflows and automation alongside these details; do not require an operator to inspect raw JSON. Details are UTF-8 plain text, limited to 16 KiB; bound lists and disclose omitted entries. Test useful findings on failure and recovery, without leaking credentials or dumping upstream responses.

Follow the SDK guide's check/Result helpers and datasource injection. Credentials, endpoints and access paths belong in private runner settings, not public parameters, summaries, details or controller metadata. Declare construction-environment inputs when accepted source must retain private settings after a broken replacement. Select checks by source-owned placement, not credential presence or network reachability.

Delegate only values the operator should control. Declare their schema, complete source defaults, boundaries and comparisons; the Python function still owns their meaning. Source controls membership, target and schedule. A parameter contract asserts shared semantics, not merely equal field shapes. Read docs/CONFIGURATION-AS-CODE.md and docs/CONFIGURATION-RULES.md before proposing project policy; executing a check or starting a runner does not authorize applying it.

Add meaningful tests for healthy/failing/boundary cases, unavailable or malformed data, and complete parameter overrides. Use synthetic/offline or bounded local-service fixtures unless actual data access is explicitly in scope. Run the project's locked tests and installed `validate`, then a local `run --results`. Select one check when using `--params`; batch `--all` runs use source defaults. Check emitted health and identity as well as exit status. Preserve upstream notices in reused code.

For explicitly authorized real datasource checks, follow the private-credential local-run recipe in docs/SDK.md. Use the project's locked uv command with a private env file and the appropriate editable/non-editable mode; do not display the file, dump environment values or put secrets in prompts/results. A local check run does not require starting a persistent runner or authorize deployment.

Hand off deployment to mondek-runner-setup. Changed non-editable project code must be reinstalled before restart. A complete accepted inventory can retire removed checks, so review membership changes deliberately and preserve historical continuity. Report test evidence and remaining real-datasource validation without claiming a fixture is a deployed observation.
