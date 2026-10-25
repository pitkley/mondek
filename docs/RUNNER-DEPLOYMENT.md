# Run a consumer outside the demo

The SDK runs ordinary installed Python code on the machine that has access to the data. A dedicated runner can query a monitoring database; a node runner can inspect local files and processes. The controller receives definitions and results and does not execute the consumer. These instructions use this repository checkout and its committed locks; no published package or installer is required.

For a new project, the [project generator](../runner/README.md#start-your-own-monitoring-project) creates a small consumer with editable limits and local tests. The instructions below cover the larger installed node and datasource examples.

## Prepare a locked environment

From the repository root:

```sh
devenv shell -- uv sync --project examples/consumers --locked --no-dev --no-editable \
  --reinstall-package mondek-local-examples --reinstall-package mondek
```

The installed executable is `examples/consumers/.venv/bin/mondek-runner`. Calling it directly below avoids an implicit dependency update. Keep the checkout and environment together as one deployment. The packaged consumer Dockerfile follows the same lock and installs non-editable packages using the pinned uv image. It preserves the repository's relative SDK dependency path.

The reinstall flags rebuild the two local packages when their Python source changes without a version change; they do not upgrade locked dependencies. An ordinary non-editable sync can reuse a cached wheel because uv does not track every Python source edit by default ([cache rules](https://docs.astral.sh/uv/concepts/cache/#dynamic-metadata)). Build a replacement in a separate checkout/environment for validation before cutover. If reusing an existing environment, stop its runner before rebuilding and retain a separate complete previous deployment for rollback.

## Start with a real node filesystem

Choose a stable node ID and a persistent state directory owned by the account running the checks. The node ID names the monitored subject; the runner's state directory holds its separate installation identity. Neither should be copied to create another node.

```sh
devenv shell -- env MONDEK_LOCAL_NODE_ID=node-a \
  MONDEK_LOCAL_NODE_LABEL="Application node A" \
  examples/consumers/.venv/bin/mondek-runner validate \
  --consumer mondek_examples.node_local:app

devenv shell -- env MONDEK_LOCAL_NODE_ID=node-a \
  MONDEK_LOCAL_NODE_LABEL="Application node A" \
  examples/consumers/.venv/bin/mondek-runner run \
  --consumer mondek_examples.node_local:app --all --results
```

This starter always measures the runner's root filesystem. A native execution measures that machine's filesystem; a container execution measures the filesystem visible inside the container. The optional checks below are absent until their source configuration is supplied.

`--results` includes the original results from each local execution, including summaries, values and source timestamps. Batch output is bounded to 8 MiB and reports any omitted result details explicitly; collection and health totals still cover every selected check. It does not rerun checks to obtain their evidence. Without the option, batch output remains a compact summary.

Start persistent collection in the foreground against a reachable local controller:

```sh
devenv shell -- env MONDEK_LOCAL_NODE_ID=node-a \
  MONDEK_LOCAL_NODE_LABEL="Application node A" \
  MONDEK_RUNNER_LABEL="Node A observer" \
  MONDEK_CONTROLLER_URL=http://127.0.0.1:4000 \
  examples/consumers/.venv/bin/mondek-runner \
  --consumer mondek_examples.node_local:app \
  --state-dir "$HOME/.local/state/mondek/node-a"
```

Leave that command running and inspect its journal from another terminal:

```sh
devenv shell -- examples/consumers/.venv/bin/mondek-runner \
  --status --state-dir "$HOME/.local/state/mondek/node-a"
```

The status command reads state without starting another session. In the UI, Runners shows the observer and last reported execution backlog; Checks shows actual measurements. Stop the foreground runner with Ctrl-C. Reusing its state directory on the next start preserves installation identity and buffered evidence, while advancing the session. A process supervisor may run the same executable with the same environment and state directory; a service installer is not included.

## Add an ordinary file or process

Include these settings after `devenv shell -- env` in the validation, local-run and persistent-start commands:

| Setting | Meaning |
| --- | --- |
| `MONDEK_LOCAL_FILE=/srv/application/export.csv` | Inspect an ordinary file's existence, readability, size and modification age |
| `MONDEK_LOCAL_FILE_ID=daily-export` | Stable logical file identity; defaults to `application` |
| `MONDEK_LOCAL_PID_FILE=/run/application.pid` | Read the application's ordinary decimal PID file |
| `MONDEK_LOCAL_EXPECTED_EXECUTABLE=/opt/application/bin/server` | Require the exact Linux executable for that PID; supply together with the PID file |
| `MONDEK_LOCAL_PROCESS_ID=application-server` | Stable logical process identity; defaults to `application` |
| `MONDEK_LOCAL_INTERVAL=30` | Source-owned interval in seconds, from 5 to 3600 |

The file check delegates minimum size and warning/critical age thresholds; content-specific validation belongs in consumer code. Its measurement time is the inspection time, so an old file can be a freshly measured failure. Access paths remain runner-side datasource settings. Relocating the same logical subject can retain its target ID. A different subject requires a new file or process ID and receives separate history.

The node starter declares `root-filesystem.used-percent.v1` and `regular-file.size-and-age.v1` parameter contracts. Configuration can review and save compatible disk checks together across nodes, or compatible file policies together, while each check adopts and measures its own saved version. Disk and file checks have different meanings and cannot share one bulk edit. Process identity and access settings remain source-owned.

The process check uses Linux `/proc`, checks identity consistently during inspection and compares the resolved `/proc/<pid>/exe` binary. Interpreted applications match their interpreter, not their script; arguments and service role are not checked. Missing or invalid PID files and unsupported systems produce Unknown; a readable valid PID whose process is absent or has the wrong executable produces Critical. An ordinary PID file cannot prove that a PID was not reused by the same executable before inspection; use an application-specific check with a stronger birth identity when that distinction matters. The starter never starts, stops or modifies the monitored process.

### Several applications on one node

Use `mondek_examples.node_multi:app` to declare several files, processes or filesystem paths without copying check functions. Set `MONDEK_NODE_RESOURCES_SETTINGS` to a private JSON document, for example:

```json
{
  "node_id": "node-a",
  "node_label": "Application node A",
  "interval_seconds": 30,
  "mounts": [{"id": "root", "path": "/"}],
  "files": [
    {"id": "orders-export", "label": "Orders export", "path": "/srv/orders/export.csv"},
    {"id": "billing-export", "label": "Billing export", "path": "/srv/billing/export.csv"}
  ],
  "processes": [
    {"id": "orders", "pid_file": "/run/orders.pid", "expected_executable": "/opt/orders/bin/server"}
  ]
}
```

Use this entrypoint with `validate` and `run --all` as above. Start it with its own persistent state directory, for example:

```sh
devenv shell -- env \
  MONDEK_NODE_RESOURCES_SETTINGS="$(cat /path/to/private-node-resources.json)" \
  MONDEK_CONTROLLER_URL=http://127.0.0.1:4000 \
  examples/consumers/.venv/bin/mondek-runner \
  --consumer mondek_examples.node_multi:app \
  --state-dir "$HOME/.local/state/mondek/node-a-resources"
```

The JSON accepts 1–512 explicitly named resources within 48 KiB. Each resource is independently scheduled and has its own result, health, freshness and incident. Files and filesystem checks delegate the same complete policies as the single-resource starter. Bulk compatibility is scoped to the source ID, so checks from `node-resources` and `node-local` require separate bulk edits. Process identity remains source-owned. The typed Python interface in `mondek_examples.node_resources` provides `NodeResources`, `FileResource`, `ProcessResource`, `MountResource` and `make_app` for applications that construct their configuration in code.

Resource IDs are unique within their kind; `file:orders` and `process:orders` identify different subjects. Relocating a path for the same subject can retain that identity; use a new ID for a different subject. The source ID is `node-resources`, distinct from `node-local`. A state directory cannot change source IDs: attempting that is rejected and retains its accepted monitoring. A new runner also does not withdraw the old source. For a different-source replacement, retire the old publication from Coverage or deploy an explicit empty inventory under its old source ID and retained state, then stop it and start the new consumer with its own state directory. Same-source replacement can additionally review the successor's exact coverage through the [publication lifecycle](OBSERVER-LIFECYCLE.md). Their result histories remain separate.

The node starters intentionally require monitored resources. For deliberate withdrawal, install a small replacement consumer module in the same locked deployment, for example `my_checks.retire_node`:

```python
from mondek_runner import App, Environment

app = App(
    source_id="node-local",  # Keep the exact source ID being withdrawn.
    environment=Environment("node-a", "Application node A"),
    checks=[],
)
```

Stop the old runner, validate that module, then run it with `--consumer my_checks.retire_node:app` and the old `--state-dir`. Verify in Checks with Membership set to Retired that its prior results are retired before stopping the withdrawal runner. Use `source_id="node-resources"` when withdrawing that starter instead. This is an explicit source deployment: deleting state or merely stopping a runner does not withdraw expected monitoring.

Filesystem checks measure the filesystem containing each configured path. They do not establish that an expected mount is attached, and several paths can refer to the same filesystem. Include an explicit root entry if you want it monitored; no resource is discovered automatically.

## Query an existing Prometheus

The reusable Prometheus starter uses an explicit source-owned query and series-to-target mapping. For the repository's parity Prometheus fixture, the equivalent mapping is:

```json
{
  "url": "http://prometheus:9090",
  "query": "up[30s]",
  "identity_label": "instance",
  "source_id": "scrape-health",
  "environment": "local-monitoring",
  "environment_label": "Local monitoring",
  "targets": {
    "target:8080": {
      "key": "monitoring-target",
      "label": "Local scrape target",
      "kind": "service"
    }
  }
}
```

Set `MONDEK_PROMETHEUS_SETTINGS` to that JSON in the runner's deployment environment, replacing the URL and exact label values with those reachable from that runner. Use `mondek_examples.prometheus_local:app` in the same validate, run and persistent-start commands. For example, with a private local settings file:

```sh
devenv shell -- env \
  MONDEK_PROMETHEUS_SETTINGS="$(cat /path/to/local-prometheus-settings.json)" \
  examples/consumers/.venv/bin/mondek-runner validate \
  --consumer mondek_examples.prometheus_local:app
```

Start the dedicated runner with a separate persistent installation directory:

```sh
devenv shell -- env \
  MONDEK_PROMETHEUS_SETTINGS="$(cat /path/to/local-prometheus-settings.json)" \
  MONDEK_RUNNER_LABEL="Prometheus observer" \
  MONDEK_CONTROLLER_URL=http://127.0.0.1:4000 \
  examples/consumers/.venv/bin/mondek-runner \
  --consumer mondek_examples.prometheus_local:app \
  --state-dir "$HOME/.local/state/mondek/prometheus-main"
```

This starter accepts raw `up` range selectors, such as `up[30s]` or `up{job="mondek"}[30s]`, and reports scrape success or failure. A failed scrape does not establish application failure. The default identifying label is `instance`. Each configured target remains expected when its series is missing; extra or missing response series cannot alter source membership. Results preserve the selected sample's original timestamp. Aggregation and subqueries that synthesize timestamps are rejected. One check supports at most sixteen explicitly mapped results.

### Several queries or hundreds of targets

Use `mondek_examples.prometheus_groups.CollectionGroup` and `make_grouped_app` to declare several separately scheduled queries in one consumer. Each group has its own stable check ID, query, series mapping and evaluation meaning. The SDK's datasource factory selects that group's private settings; registering the same datasource type repeatedly would replace its earlier registration.

The executable [two-query consumer](../examples/consumers/src/mondek_examples/prometheus_multi.py) checks scrape health separately from two application readiness results against the parity fixture:

```sh
devenv shell -- examples/consumers/.venv/bin/mondek-runner validate \
  --consumer mondek_examples.prometheus_multi:app
```

Run it on a runner that can reach the configured Prometheus with `run --consumer mondek_examples.prometheus_multi:app --all`. Its default `http://prometheus:9090` address is the Compose network address; set `MONDEK_PROMETHEUS_URL` to an accessible URL when running elsewhere. The declaration is ordinary Python: supply explicit `CollectionGroup` entries for real queries and targets. Keep each group at sixteen or fewer results, with at most 512 scheduled checks per runner and the documented inventory/output bounds. Give groups stable meaningful IDs rather than regrouping an automatically discovered series list on each import. Adding a new target must be a reviewed source change; a missing sample keeps its result expected.

### Numeric thresholds

Use `mondek_examples.prometheus_numeric.make_numeric_app` for an ordinary numeric gauge. For example, a consumer can declare:

```python
from mondek_runner import Environment, Target
from mondek_examples.prometheus_numeric import make_numeric_app

app = make_numeric_app(
    source_id="application-queues",
    environment=Environment("production", "Production"),
    url="http://prometheus.internal:9090",
    query="queue_depth[2m]",
    identity_label="queue",
    targets={"orders": Target("queue:orders", "Orders queue", "queue")},
    unit="items",
    direction="above",
    minimum=0,
    maximum=1_000_000,
    warning=100,
    critical=500,
    interval_seconds=30,
    freshness_seconds=120,
)
```

Only warning and critical values are delegated. The source fixes the query, target mapping, unit, direction, allowed threshold range and schedule. Choose meaningful minimum and maximum thresholds for the monitored quantity. `above` warns at or above warning and becomes critical at or above critical; `below` reverses the comparisons and requires critical to be lower than warning. Both comparisons include equality. Numeric results keep original raw sample timestamps. Missing series or invalid/nonfinite data do not become fresh healthy results. Readiness and scrape consumers still require zero or one; arbitrary PromQL aggregation remains outside these raw-sample helpers.

The executable `mondek_examples.prometheus_numeric_example:app` uses the parity fixture's queue-depth metric, with `MONDEK_PROMETHEUS_URL` selecting its reachable Prometheus. Its real acceptance scenario crosses both equality boundaries, corroborates source timestamps against Prometheus, recovers the same incident and preserves delegated thresholds through runner restart. For custom checks in an existing app, `make_numeric_check` and `NumericPrometheus` expose the same policy; match their units/direction and use datasource factories when registering several private queries of the same type. Bulk compatibility remains opt-in through an explicit `parameter_contract` describing shared meaning.

## Update or recover a deployment

Validate and locally execute a new locked deployment before starting it with the retained state directory. Stop the previous process first. Failed consumer discovery preserves the last accepted inventory and source snapshot and reports the failure. The UI continues to distinguish retained health from fresh measurements.

Source snapshots retain consumer code, declared private datasource settings and explicitly declared construction environment values. The starters declare the inputs needed to build their inventory, including absent optional settings, so malformed replacement settings do not prevent the saved consumer from constructing. Custom consumers can use `App(construction_environment=...)` for the same behavior. Only declared construction inputs are frozen; arbitrary environment reads inside running checks are not. Pass execution settings through declared datasources. Snapshots do not retain separately changed third-party environments or SDK versions. Keep the previous checkout and installed environment available; if an upgrade changes those dependencies and cannot run, stop it and restart the previous complete environment with the same state directory. Do not run two processes against one state directory or assume an in-place dependency upgrade can execute earlier snapshots.

Code and source configuration determine access paths, queries, targets, membership and schedules. UI edits can only change explicitly delegated values. Authentication, remote rollout, secret enrollment and remediation remain outside this local implementation.

Adding a field to a delegated schema initializes that field from the new source default while preserving explicit instance exceptions, check identity and history. The complete resulting set must satisfy the new constraints. Removing a saved field, changing its type or units, making saved values invalid, or reclaiming delegated parameters as source-owned under the same check ID rejects the entire source update and retains accepted monitoring. Checks without an exception or winning rule follow the latest accepted source defaults. Rules retain their reviewed values and captured complete schema, so even an otherwise compatible additive schema change can require an explicit rule refresh; follow the [durable rules upgrade flow](CONFIGURATION-RULES.md#schema-changes-and-shared-executions). Validate compatible transitions before deployment; incompatible changes need a compatible definition or a deliberate new check identity. Configuration's adoption filter helps find saved versions still waiting after an update, even after the original form is closed.

### Withdrawing monitoring

Remove checks or outputs from the consumer's registered inventory, validate the resulting App, install the changed code and restart the same runner with its existing state. Confirm that the controller accepted the complete inventory and shows removed results under Retired. Open incidents close as source removal, without a recovery measurement; retained incidents and evidence remain inspectable. Unchanged outputs keep their identities and history. A reintroduced retired output receives a new result incarnation.

Before uninstalling an entire consumer, publish the same App with `checks=[]` and confirm retirement, then stop the runner. Alternatively, review retirement of its installation/source publication from **Coverage → Publishing runners**, which also works when that runner is unavailable and fences automatic re-entry. Removing its package first causes discovery failure and preserves accepted monitoring. A disconnected runner cannot communicate an inventory change until it reconnects. Collection failure, an empty result list and heartbeat outage never remove expected coverage. Restoring an operator-retired publication requires an explicit restore and successful new discovery with the updated SDK; see [observer lifecycle](OBSERVER-LIFECYCLE.md).

### Snapshot verification at larger inventories

Discovery validates the complete consumer inventory before saving a snapshot. New snapshots authenticate the complete manifest with an installation-local keyed digest; workers reject a missing or invalid authentication record before importing consumer code. Each worker still verifies all saved source files, runtime dependencies, private settings and exact registered membership, then validates its selected check's complete metadata, including targets, parameter schema, ownership, schedule and revision. This avoids rebuilding every unrelated definition for each of hundreds of separately scheduled checks. A change to an unrelated check's undeclared import-time metadata does not block an unchanged selected check; complete rediscovery still validates that change, and changed selected metadata fails closed. Declare construction inputs so accepted revisions consistently rebuild their intended metadata. Older snapshots retain complete metadata verification. The optimization does not cache measurements, skip due executions or relax worker deadlines.
