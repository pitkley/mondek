# Monitoring project instructions

Read README.md and src/monitoring/app.py first. Use Python 3.13+ and uv for this project. The installed SDK does not require a Mondek source checkout. Use the documented image Compose recipe for a local server if needed. Keep changes in this project unless explicitly authorized otherwise. Commit uv.lock after the first explicit dependency sync; later installs and commands use --locked. Do not deploy or contact production systems without authorization.

Monitoring logic belongs in ordinary Python. Keep private access paths, credentials and datasource construction outside UI parameters. Delegate only settings intended for operators through Parameter declarations; code defines their meaning. Preserve stable identities for unchanged subjects, and assign new identities when meaning changes. Missing data must not silently remove expected outputs or refresh old evidence. Document equality boundaries, units and failure behavior.

Run the policy tests, local validate and local run commands from README.md after changes. Cover health boundaries, missing/malformed input and recovery. Local run uses source defaults, not saved controller configuration. Review a complete inventory before restarting a persistent runner after deleting or splitting checks: source removal closes open incidents without claiming recovery. Never erase durable runner state to fix a routine code change.

For explicitly authorized real datasource verification, follow the Mondek SDK guide's private env-file local-run recipe, selecting the intended check and retaining this project's installation mode. Do not display credential files, dump environment variables or enable shell tracing around secret loading. Trusted check output is not automatically secret-redacted.

Keep sensitive targets, tokens and incident details out of copied prompts and source control. Do not implement a domain standard library when a small project-owned abstraction suffices. Authentication, remote commands, automated remediation and production deployment are not provided by this starter.

Give each result a concise summary and human-readable details containing the affected resources, observed values, units and relevant thresholds. Keep structured discovery/impact data alongside those details for workflows and automation. Operators should not need raw JSON to understand a finding. Details are plain text with a 16 KiB UTF-8 limit; bound lists, disclose omissions, exclude secrets and verify findings in failure/recovery tests.
