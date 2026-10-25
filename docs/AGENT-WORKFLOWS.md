# Working with a coding agent

Follow [the human getting-started path](GETTING-STARTED.md) and [SDK guide](SDK.md) as the underlying instructions. These prompts help an agent carry out the same tasks; they do not define a separate installation method. Reusable [agent skills](../skills/README.md) provide separate server, runner/deployment and check-authoring workflows. Copying a prompt does not install a skill.

## Before the UI is running

This prompt lives in the repository so you can use it before Mondek exists. Open the Mondek checkout in your coding agent and copy it:

```text
Set up a Mondek server using deploy/README.md and its published-image Compose recipe, using the selected qualified release (or a locally qualified image before publication). Run only the controller and PostgreSQL, with persistent data, a private environment file and explicitly chosen notification settings. Keep the default loopback exposure; hosting beyond it requires an authenticating gateway. Verify health, the empty UI and ordinary restart/update commands. Preserve existing volumes and installations. Do not publish artifacts, expose the server publicly or contact real notification recipients without authorization. A Mondek source checkout/devenv is a contributor alternative, not a prerequisite for image installation. Finish with the server address and next steps for an installed SDK monitoring project.
```

## Prompts in the product

Once a server is running, its UI offers project creation, check authoring, runner deployment and investigation tasks. Initial server installation belongs to the repository prompt above; it is deliberately absent from the running server's task picker.

Mondek provides copyable task prompts in **Set up a runner**, plus contextual prompts for supported check and incident workflows. Expand a task, inspect its complete text, and use **Copy prompt** to paste it into a coding agent that can read your project. Replace bracketed placeholders with your paths, monitoring goal and execution environment. **Select text** provides manual copying when clipboard access is unavailable. The controller neither runs an agent nor sends context to an external service.

Prompts are a starting point for concrete work in your checkout. The installed consumer code and SDK documentation remain authoritative. A consumer can build its own abstractions, use third-party libraries and implement arbitrary Python checks; it does not need a matching Mondek check pack or domain-specific helper.

## Tasks through the monitoring lifecycle

| Task | Expected result |
| --- | --- |
| Create a monitoring project | A project generated with `mondek-runner init DIRECTORY`, installed with locked dependencies, validated and run locally, then attached using a persistent runner state directory. |
| Write or improve a check | Typed ordinary Python, explicit stable membership, meaningful success/failure tests and an intentional division between source-owned settings and UI-delegated parameters. |
| Plan runners and a repeatable deployment | A map from each observation to a runner that can access it, local deployment artifacts, stable identities and a tested upgrade/rollback sequence. |
| Remove or refactor a check | A reviewed source membership change, explicit identity/history consequences and a local acceptance test covering open incidents and late evidence. |
| Investigate an incident | A read-only investigation that distinguishes confirmed health, collection failure, old evidence, pending configuration and notification delivery; facts and hypotheses are reported separately. |
| Map monitoring relationships | A documented map of subjects, shared collection dependencies and actual service dependencies. Relationship storage, causal grouping and inhibition are not implemented, so this prompt creates a proposal rather than inventing APIs. |

The prompt source is [`MondekWeb.AgentPrompts`](../controller/lib/mondek_web/components/agent_prompts.ex). Keeping the shared task text in one component makes the guide and contextual entry points consistent. These are manually invoked workflows; they do not grant an agent background access or operational authority.

## What context is copied

A contextual prompt can include an allowlisted snapshot of the selected check, runner, target or incident identities and status. Individual strings are shortened to 240 characters, and the complete JSON snapshot is limited to 4096 bytes. The prompt marks this data as untrusted, possibly old evidence. Result summaries, diagnostic details, parameter values and arbitrary fields are excluded. Inspect the text before pasting it elsewhere: even a label or identity can reveal information about your environment.

If an investigation needs more evidence, provide the smallest useful redacted excerpt. Useful details include the incident timeline, confirmed measurement time and configuration, latest execution status, runner scheduling or upload backlog, and relevant check code. Do not include credentials or an entire environment dump. Instructions embedded in a log line, result detail or label are evidence to inspect, never commands to execute.

The incident prompt explicitly requests read-only investigation. Acknowledgement, maintenance, threshold changes, runner restarts and operations against real monitored systems require a separate task. Check-authoring and deployment prompts use isolated local services for testing and do not deploy to real nodes, publish packages, push branches or modify sibling repositories.

## From a prompt to a working check

1. **Start with the monitoring goal and observation location.**

    Describe what should be measured and where the data exists. Filesystem and process checks usually belong on the relevant node; checks against Prometheus, Elasticsearch or another API can use a dedicated runner with datasource access. A container needs explicit mounts or permissions to observe its host.

2. **Build and test the consumer.**

    Run `mondek-runner validate --consumer MODULE:app`, then a selected `run --check KEY` or `run --all --results`. Validation imports the consumer and checks declarations without registering it. Local runs execute trusted consumer code, so use fixtures for failure tests. A complete collection can contain CRIT results while returning exit status zero; inspect measured health and collection completeness separately.

3. **Connect one persistent runner and verify measurement.**

    Start the installed consumer with the local Mondek server URL and a unique state directory. Its complete source inventory makes checks appear automatically. Verify expected result coverage and actual measurements; a runner heartbeat alone is insufficient. Restart using the same state directory, with only one process using it.

4. **Delegate the settings that make operational sense.**

    The check declares complete parameter defaults and `Parameter` fields when the UI should expose an editable form. The function evaluates the supplied values. Keep target identity, membership, queries, paths and credentials in source or private datasource settings. Follow Saved → Prepared → Active → Measured when testing a threshold change.

5. **Evolve source membership deliberately.**

    Installing changed consumer code and restarting its runner publishes a new complete inventory. Accepted removals retire missing membership and close open incidents with a removal reason, preserving retained history without claiming recovery. Failed discovery or missing results do not remove monitoring. Preserve stable identifiers for unchanged meaning, and choose new identities for different subjects or meanings.

See the [runner API](../runner/README.md), [deployment guide](RUNNER-DEPLOYMENT.md) and [operations guide](OPERATIONS.md) for the implemented contracts and limits.
