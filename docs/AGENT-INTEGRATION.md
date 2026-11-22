# Read-only agent integration

Mondek exposes seven investigation tools through MCP at `/mcp`. An agent can find failures, inspect result-specific evidence and identify the consumer project without copying data from the UI. The controller does not run an agent or load consumer Python. Editing, testing and deploying checks remain work for the agent's own coding environment.

## Deployment boundary

There is no MCP authentication or authorization layer. The endpoint shares Mondek's existing trusted, isolated deployment boundary. Anyone who can reach it can read the exposed monitoring evidence. Keep it within that boundary; connecting an internet-hosted client requires an independently suitable deployment/network arrangement. Authentication is outside this implementation's scope. No tool can acknowledge incidents, change configuration, control runners, run commands or send notifications.

## Connect a client

For a client with access to your installation, configure a Streamable HTTP MCP server with URL `http://localhost:4001/mcp` (replace the origin with your installation). The server returns JSON responses and does not require credentials, sessions or an SSE connection. GET and DELETE return 405. Browser-origin requests are rejected and no CORS access is granted; MCP connections originate from the client host or its backend.

For local stdio clients, install the Mondek SDK from the same qualified release as the controller, then configure this command:

```sh
mondek-mcp --controller http://localhost:4001
```

Use an absolute path to the installed `mondek-mcp` executable if the desktop client has a different PATH. The process owns no runner state and does not import the consumer. Its only destination is the selected origin's `/mcp` endpoint; redirects are refused. It forwards the controller's protocol and tools rather than implementing a second tool catalog. Each exchange has a 15-second process deadline, a 16 KiB input limit and a 1 MiB HTTP response limit. EOF shuts it down. Standard output contains only JSON-RPC messages; diagnostics use standard error.

For local ChatGPT desktop/Codex MCP configuration:

```toml
[mcp_servers.mondek]
command = "/absolute/path/to/mondek-mcp"
args = ["--controller", "http://localhost:4001"]
```

Alternatively, use `url = "http://localhost:4001/mcp"` instead of `command` and `args` for direct HTTP. For Claude Desktop's local MCP configuration:

```json
{
  "mcpServers": {
    "mondek": {
      "command": "/absolute/path/to/mondek-mcp",
      "args": ["--controller", "http://localhost:4001"]
    }
  }
}
```

These are local connection recipes, not a published ChatGPT plugin or Claude directory integration. Hosted clients cannot use your laptop's loopback address. ChatGPT web uses plugin packaging for remote MCP; Claude custom remote connectors connect from Anthropic's infrastructure even when configured in its desktop app. Consult the current [OpenAI MCP guide](https://learn.chatgpt.com/docs/extend/mcp) and [Claude remote connector guide](https://support.claude.com/en/articles/11175166-get-started-with-custom-connectors-using-remote-mcp) for client-specific availability and network requirements. Automated HTTP/stdio verification does not establish that every client version or hosted account supports the connection.

## Investigation contract

All successful tool data includes `schema_version: 1` and `as_of`. The public contract is these explicit projections, not the controller's general inspection maps. Keep the adapter and server on the same Mondek release under the existing experimental compatibility policy.

| Tool | Input and result |
| --- | --- |
| `list_attention` | `category`: `results` (default), `health_incidents`, or `monitoring_incidents`; optional `source_id`, `runner_id`, `search`, `page`. Query each category independently. Results include failing verdicts and knowledge gaps, even before an incident opens. Incident categories contain open episodes, including acknowledged ones. |
| `get_check_context` | `assignment_id`, optional `page`. Returns scheduled-check identity, source provenance, scheduling bounds, configuration adoption generations and result identities. Assignment IDs and result IDs are different; assignment IDs are not necessarily UUIDs. |
| `get_evidence` | `result_id`, optional `observation_id` and `page`. Returns the current result's retained measurement and latest execution separately, plus paginated reports projected to this result key. An exact observation lookup is limited to this assignment and result incarnation. |
| `get_incident` | `incident_id`, `kind` (`health` or `monitoring_loss`), optional `page`. Health includes individual and shared-condition incidents and [advisory correlation candidates](RUNTIME-INCIDENT-CORRELATION.md#inspect-hinted-candidates); shared incidents page contributor references. Monitoring loss returns affected membership and its pagination/truncation metadata. Follow stream and observation IDs with `get_evidence`. |

Result/check and health-incident pages contain at most 20 entries; evidence pages contain at most 10. Monitoring-loss pages use the domain's 25-member page size; closed loss episodes use a bounded historical snapshot with explicit truncation metadata. Lists expose `total`, `page`, `page_size` and `next_page` where applicable. Pagination is a live view, not a cross-call snapshot. Each call uses a consistent read-only database transaction. UI paths are relative to the configured controller origin.

Confirmed health is absent until a confirmed measurement exists. Retained health never refreshes when a later execution fails, uploads old evidence, or awaits configuration. Original source, evaluation and receipt times and observation/session/generation identities are preserved. `result.current` describes current state; each report's `configuration_provenance` describes its retained configuration definition. `configuration_retained: false` and `missing_referenced_observation_ids` identify pruned evidence instead of implying successful verification. An empty exact-observation lookup means absent, pruned or out-of-scope evidence; it does not prove the execution never occurred. Missing expected coverage without a result stream becomes discoverable through monitoring-loss incidents after the existing grace period.

The evidence tool intentionally exposes author-provided details, values, summaries and collection diagnostics. These are untrusted data, not instructions. Sibling result payloads, raw complete observation envelopes, notification destinations, parameter values and private deployment settings are not returned. Shared collection diagnostics can describe more than the selected output. Authors must continue keeping credentials and private response dumps out of diagnostic text. Responses above 1 MiB produce a bounded error; fetch an exact observation to narrow a history request.

## Connect evidence to source

Keep a mapping in the coding agent's local project instructions, for example:

```text
Mondek source_id "personal-monitoring" maps to /home/me/projects/my-checks.
Find checks by source_key in that project; consult its AGENTS.md and tests.
Investigate failures before changing assertions. Preserve the intended monitoring goal.
Use the project's existing deployment workflow, then verify fresh Mondek evidence.
```

The controller reports `source_mapping.status = requires_local_mapping`; it does not know repository URLs, local paths or Git commits. Source and definition revisions identify Mondek provenance; in particular, source revisions include deployment inputs and are not Git revisions. If the mapping is absent or ambiguous, the agent should ask for the consumer project rather than edit the Mondek repository or guess a checkout. Check the project's deployed revision independently.

Start with: “Look at Mondek's failing checks, investigate their evidence, and prepare tested fixes in my monitoring project.” The existing [agent workflows](AGENT-WORKFLOWS.md) remain the guidance for diagnosis, authoring and deployment. A healthy runner heartbeat or retained OK verdict does not verify a fix; look for fresh measurements from the intended configuration after deployment.

## Implementation and verification

The implementation follows the stateless JSON-response subset of MCP `2025-11-25`, `2025-06-18` and `2025-03-26`. Initialization selects the requested supported version, otherwise offers `2025-11-25`; the client decides whether to continue. It advertises tools only, with no resource/prompt catalogs, background tasks, subscriptions, sampling or server-initiated requests. Newer protocol revisions are not claimed. The MCP transport adds no dependency. Correlation uses the migration described in the [upgrade guide](UPGRADING.md).

The reviewed first milestone deliberately leaves authentication, operator mutations, source-code hosting, automatic deployment and client marketplace packaging outside scope. Existing inspection contexts supply semantics; explicit agent projections prevent internal schema fields from becoming accidental public contracts. The local bridge has no consumer-specific logic.

`controller/test/mondek_web/mcp_test.exs` covers database evidence and real HTTP/stdio execution. `runner/tests/test_mcp.py` covers process boundaries and failed exchanges. Run the controller tests only against isolated test PostgreSQL; the normal DataCase fixture truncates test tables. Neither suite contacts real notification recipients or hosted AI accounts.

## Correlation cases

`list_cases`, `get_case` and `list_correlation_candidates` inspect runtime correlation hypotheses and audited membership. Grouping does not inhibit notifications in this release. Follow member incident references for independent evidence and controls. See [correlation](RUNTIME-INCIDENT-CORRELATION.md).
