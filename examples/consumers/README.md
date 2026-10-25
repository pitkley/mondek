# Installed consumer examples

This is a separate Python project that depends on the installable Mondek runner SDK. Its checks are ordinary consumer code. The controller neither imports this package nor needs a new check type for its integrations.

For one unchanged project deployed to several kinds of runner, start with [runner contexts and monitored environments](../../docs/RUNNER-CONTEXTS.md). `devenv shell -- mondek placement` runs two node observers and one shared observer measuring Staging and Production independently; `mondek placement-acceptance` verifies selection, failures, retirement and reconnects.

For configuration that follows a target between observers, `mondek_examples.durable:app` reads an ordinary pending-item file and declares a stable logical volume ID plus a shared parameter contract. `devenv shell -- mondek rules` runs the same package on two nodes; `mondek rules-acceptance` moves the target through an absent period and verifies policy, incident history and reconnect behavior. See [durable configuration rules](../../docs/CONFIGURATION-RULES.md).

## Declared coverage example

`mondek_examples.coverage:app` publishes an explicit node roster and shared service checks for Staging and Production before runner placement selects executable checks. `devenv shell -- mondek coverage` starts Node A and two service observers, leaving Node B and Production visibly uncovered. The example uses owned HTTP fixture measurements; the placement example remains the reference for inspecting real local files. See [coverage auditing](../../docs/COVERAGE.md) for the declaration model and `mondek coverage-acceptance` for restoration, independent evidence and reconnect scenarios.

## Shared condition example

`mondek_examples.grouped:app` demonstrates independent Linux-volume and Elasticsearch-like observations using an owned HTTP fixture. It does not inspect the host filesystem or connect to Elasticsearch. Deploy it with `MONDEK_GROUPED_KIND=volume` or `elasticsearch`, a stable `MONDEK_GROUPED_OBSERVER` (default `node-a`), `MONDEK_GROUPED_FIXTURE_URL` (default `http://target:8080`) and `MONDEK_GROUPED_ENVIRONMENT` (default `production`). Each deployment registers one independent check; multiple observers may run the same kind. The two kinds have distinct source IDs and targets, and explicitly share `Condition("search-volume-pressure", "Search storage capacity", namespace="grouped-example")`. Environments remain separate.

The consumer sends `GET /grouped/{URL-encoded observer}/{kind}` to that fixture URL. HTTP 200 must contain exactly these four JSON fields, within 4096 bytes:

```json
{"used_percent":95,"writes_blocked":false,"available":true,"source_at":"2009-01-02T03:04:05.123456Z"}
```

`used_percent` is a finite number from 0 through 100; the two flags are booleans. `source_at` is the original UTC measurement time, with six fractional digits and either `Z` or `+00:00`, between year 2000 and collection time. The fixture should generate current timestamps for fresh evidence and preserve an earlier timestamp when exercising delayed evidence. Warning starts at 90% used, critical at 95%. Explicit `writes_blocked=true` makes an available result critical and adds `Impact("writes-blocked", "Search index writes are blocked")`; capacity alone never invents this impact. `available=false` yields UNKNOWN with the supplied source time and no impact. Invalid or unreachable responses yield UNKNOWN without a made-up source time. Collection runs every three seconds, with a five-second worker deadline and twelve-second freshness; the HTTP read has a two-second timeout, rejects redirects and bounds the body. Fixture modes, runner transport outages and delayed replies belong to the acceptance harness.

## Try the complete system

```sh
devenv shell -- mondek parity
devenv shell -- mondek parity-down
devenv shell -- mondek parity-acceptance
```

The persistent demo opens at [localhost:4011](http://localhost:4011). `mondek parity-down` stops that demo and retains its data. The acceptance command builds its own randomly named Compose project, exercises failures and recovery, writes evidence under `.local/acceptance/`, and removes only its own containers and volumes.

| Runner | Consumer | What it measures |
| --- | --- | --- |
| Demo runner | `demo_checks.app:app` | The original filesystem, HTTP readiness and backlog samples, with their existing identities |
| Dedicated monitoring | `mondek_examples.monitoring:app` | Two independent service results from one real Prometheus collection |
| Node A | `mondek_examples.node:app` | Runner filesystem capacity, an exact local process, and export-file content and age |
| Node B | `mondek_examples.node:app` | The same consumer with its own node identity and local files/process |

The Docker node examples share a PID namespace with their own fixture and mount only that node's files read-only. They do not inspect the macOS host. The capacity check measures `/` inside the runner container; the UI calls it the runner filesystem. A runner installed directly on a compute node could inspect that node's `/`, processes and accessible application files using the same Python APIs and its actual OS permissions.

The export check inspects content and `generated_at`, distinguishing missing, malformed or old exports from an inability to read them. Its source timestamp is the time of filesystem inspection: an old file can be a freshly measured failure. The Prometheus check queries recent range samples and preserves their actual scrape timestamps. It does not substitute the time of an API response for the age of the input. See the [Prometheus query API](https://prometheus.io/docs/prometheus/latest/querying/api/).

## Validate and run locally

```sh
devenv shell -- uv run --project examples/consumers --locked mondek-runner validate --consumer mondek_examples.node:app
devenv shell -- uv run --project examples/consumers --locked mondek-runner run --consumer mondek_examples.node:app --check root-disk
devenv shell -- uv run --project examples/consumers --locked mondek-runner run --consumer mondek_examples.node:app --all --concurrency 3
devenv shell -- uv run --project examples/consumers --locked python -m unittest discover -s examples/consumers/tests -v
```

These commands use the installed project and the pinned devenv Python. Validation checks the complete catalog in an isolated process; a local run invokes the actual worker without registering a runner or uploading anything. A direct macOS local run of the process example cannot inspect Linux `/proc`; use the packaged demo for that check. To inspect an existing export locally, set `MONDEK_NODE_DIRECTORY` after `devenv shell -- env`, pointing at the directory containing `export.json`.

## Adapt a consumer

Porting an existing Checkmk-oriented Mondek consumer? Start with the [consumer migration guide](../../docs/MIGRATING-CONSUMERS.md) for the API and behavior differences, explicit identity/membership decisions, and a local file example.

The [deployment walkthrough](../../docs/RUNNER-DEPLOYMENT.md) gives complete locked install, validate, local-run, start, status and recovery commands. Its `node_local:app` starter measures a real node filesystem without fixture files and can add ordinary file/PID-file checks; `prometheus_local:app` maps existing Prometheus scrape series to explicit targets. Each node must receive its own stable `MONDEK_LOCAL_NODE_ID` and persistent runner state directory. The `prometheus_multi:app` example uses two explicit query groups with distinct private bindings; use `prometheus_groups.make_grouped_app` to compose several queries or bounded groups covering hundreds of targets.

`prometheus_numeric.make_numeric_app` measures ordinary numeric gauges with explicit units, above/below thresholds and original scrape timestamps. `prometheus_numeric_example:app` exercises the local queue-depth metric. Only its complete warning/critical policy is editable; query, targets, units and direction remain in the source. Use `run --all --results` when local batch diagnosis needs the original summaries, values and source times; omitted details are counted explicitly under the output budget.

Use the [runner authoring interface](../../runner/README.md) to define decorated functions, explicit output keys, typed parameters and datasource injection. `node.py` demonstrates one reusable check suite with deployment-specific targets; `monitoring.py` demonstrates one collection producing separately tracked results. A consumer may also discover decorated functions in modules or bind the same function to several explicit targets.

Install the SDK and consumer into a locked deployment environment, set `MONDEK_CONSUMER=your_package.module:app`, give `MONDEK_STATE_DIR` a persistent private directory, and configure `MONDEK_CONTROLLER_URL`. A runner's installation identity belongs to that state directory. Each node needs its own directory; do not clone it to create another runner. Set `MONDEK_RUNNER_LABEL` to a useful observer name.

Code, targets, datasource access, expected membership and schedules stay in the consumer deployment. Parameters remain source-owned unless the check explicitly supplies a complete UI-editable schema. Changing a parameter in the UI does not add a check or grant filesystem/database access. Restart the runner after installing a changed consumer; failed discovery retains the previous accepted inventory and makes the failure visible.

## Capacity exercise

`mondek_examples.load:app` reads independently evaluated files. The parity acceptance uses 500 result streams grouped into 50 scheduled Python functions, with ten results per execution. `MONDEK_LOAD_GROUP_SIZE=1` selects 500 separately scheduled functions; `MONDEK_LOAD_INTERVAL` sets the interval in seconds. The two cases have different process and preparation costs and should be measured separately. A count of rendered fixture rows is not execution-capacity evidence.

`devenv shell -- mondek capacity` tests 500 results across 50 scheduled functions in an isolated four-service setup; `devenv shell -- mondek capacity-checks` uses 500 separately scheduled functions. Run heavy builds, browser suites and capacity tests sequentially to measure the application without competing validation workloads. The optional `capacity` Compose profile starts an owned file fixture and this runner. All file mutations in acceptance are confined to that project's fixture volume. Scheduling, output, concurrency and spool limits still apply; choose intervals according to measured collection cost.

The initial isolated runs with three workers measured 500 results in 8.79 seconds when grouped into 50 functions, and 91.4 seconds with 500 separate functions. Both passed a real independent file failure and recovery. Initial coverage includes serial preparation; it does not by itself establish sustainable collection cadence. Inspect the runner's reported due backlog and oldest wait over repeated cycles, then size intervals and concurrency for the actual deployment. These measurements are local evidence, not a fleet capacity guarantee.

## Configure compatible checks together

`mondek_examples.bulk_exports:app` provides 500 separately scheduled file checks with a shared `export.minimum-bytes.v1` parameter contract. Each file still has its own target, execution, health and incident history. Its complete delegated parameter set contains a critical minimum size and a warning minimum size in bytes, with critical ≤ warning. The source retains file paths, expected membership, content validation and scheduling. The default 1/13-byte thresholds accept the owned fixture's real 13-byte export.

In Configuration, select a check, add compatible matches across pages, and review one complete parameter set. Differing current values require an explicit choice. The preview names exact selected checks and targets, current/proposed values and unchanged checks. Saving validates every selected revision and commits all changes together; the progress view then follows each saved version independently. A concurrent edit rejects the whole save, and identical values do not manufacture new versions. A transport reconnect restores the draft but requires another preview; a full page reload discards an unsaved draft.

After leaving that form, filter Configuration by adoption stage to find desired versions still waiting for preparation, activation or measurement. The stage filter survives reloads in the URL. Measured records that version's achieved milestone; consult Checks for current evidence freshness.

`devenv shell -- mondek bulk` starts this consumer and its owned file fixture at [localhost:4012/configuration](http://localhost:4012/configuration), in a separate persistent project. `mondek bulk-down` stops it and retains its data. Initial collection of all 500 separately scheduled checks takes time; the runner view reports preparation and scheduling progress. Run the complete real browser journey with `devenv shell -- python3 tests/browser/run.py --suite bulk`; that test's project and volumes are disposable. This exercises an actual consumer package with ordinary Python thresholds, not a controller-defined check kind.

## Source-defined discovery review

`mondek_examples.discovery_demo:app` scans a bounded local directory and emits typed candidates with Monitor capacity and Ignore proposals. It demonstrates the generic review API, not a filesystem standard library. Candidate identities and choices are data; a copied prompt asks an agent to prepare reviewed source changes without deploying. The complete isolated runner/controller/browser journey is `devenv shell -- python3 tests/browser/run.py --suite discovery`. It creates real directories in a disposable named volume and mounts them read-only into the runner. See [discovery review](../../docs/DISCOVERY-REVIEW.md).
