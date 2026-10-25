# Writing checks with the Python SDK

The `mondek_runner` SDK lets an ordinary Python package describe checks and run them on a runner. A monitoring project exports an `App` object, usually as `monitoring.app:app`. Install it using [the getting-started guide](GETTING-STARTED.md). The examples below use the installed SDK; there is no registry release to install yet.

## A first check

Save this as a module such as `monitoring/app.py`, with a small `queue.txt` input in the directory where you run it:

```python
from pathlib import Path

from mondek_runner import App, Environment, Result, check, crit, ok, unknown


@check(id="queue-depth", expected_keys=("depth",))
def queue_depth() -> Result:
    try:
        count = int(Path("queue.txt").read_text())
        if count < 0:
            raise ValueError("negative queue depth")
    except (OSError, UnicodeError, ValueError):
        return unknown("depth", "Cannot read a nonnegative queue depth")
    verdict = crit if count >= 10 else ok
    return verdict("depth", f"{count} pending items", value=count)


app = App(
    source_id="queue-monitoring",
    environment=Environment("local", "Local"),
    checks=[queue_depth],
)
```

The check is a normal callable: `queue_depth()` returns a `Result`, so you can test its policy directly. `@check` attaches declarations without wrapping the function. The runner uses those declarations for scheduling, expected membership and configuration. This example uses the decorator's defaults of a 30-second interval, 5-second timeout and 90-second freshness bound; choose values that suit the collection cost.

`expected_keys` declares what must be reported, not which results happened to succeed. An unreadable file produces Unknown evidence for `depth`; it does not remove that expectation. Result summaries explain the measurement, `value` optionally carries a number, and `details` can provide a longer bounded explanation. Never put credentials in either text field. Ordinary results use collection time by default; set `source_at` only when the measurement actually describes an upstream timestamp, and use `None` when no source measurement time is known.

Write summaries for scanning (for example, “7 containers need classification”) and details for investigation (the container names, observed state and useful policy context). Preserve structured `discovery` and `impacts` alongside human-readable findings; they support workflows and automation but do not replace details. Details are plain text, not HTML or Markdown, and are limited to 16 KiB of UTF-8. Bound long lists and explicitly state how many entries were omitted. Include relevant values, units and configured thresholds where these explain the verdict; avoid credentials and raw upstream response dumps. Test the emitted findings as well as health, including collection failure and recovery.


Run `mondek-runner validate --consumer monitoring.app:app`, then `mondek-runner run --consumer monitoring.app:app --all --results` from the installed project's directory. A complete collection can contain Critical results and still exit zero. Validation imports your trusted code; neither command creates server-side membership.

## Delegate an operational setting

This is a separate complete example. The function receives a full parameter set as the keyword argument `params`:

```python
from mondek_runner import App, Environment, Parameter, Result, check, crit, ok


@check(
    id="queue-depth",
    expected_keys=("depth",),
    params={"critical_items": 10},
    parameters={
        "critical_items": Parameter("integer", "Critical at", unit="items", minimum=1),
    },
)
def queue_depth(*, params: dict[str, int]) -> Result:
    count = 12  # Replace with a real observation in your project.
    verdict = crit if count >= params["critical_items"] else ok
    return verdict("depth", f"{count} pending items", value=count)


app = App(source_id="queue-monitoring", environment=Environment("local"), checks=[queue_depth])
```

`params` supplies complete defaults; `parameters` exposes only deliberately delegated fields in Configuration. UI validation covers declared types, bounds, choices and explicit cross-field comparisons, but your Python function implements their meaning. `params` is an ordinary dictionary, not a generated typed settings class. For a local override, select one check with `--check CHECK_KEY --params JSON`; batch `--all` runs always use source defaults. Validate defaults and test equality boundaries. Keep paths, queries, membership and credentials source-owned or in private datasource settings. See [parameter rules](CONFIGURATION-RULES.md) before declaring a reusable `parameter_contract`.

## Inject access to a datasource

Use a `Datasource` subclass to separate local access/configuration from check policy. Registration supplies JSON-compatible constructor settings; a typed function argument selects the registered provider. This complete example still reads the same local `queue.txt`:

```python
from pathlib import Path

from mondek_runner import App, Datasource, Environment, Result, check, ok, unknown


class QueueFile(Datasource):
    def __init__(self, path: str) -> None:
        self.path = Path(path)

    def depth(self) -> int:
        count = int(self.path.read_text())
        if count < 0:
            raise ValueError("negative queue depth")
        return count


@check(id="queue-depth", expected_keys=("depth",))
def queue_depth(queue: QueueFile) -> Result:
    try:
        count = queue.depth()
    except (OSError, UnicodeError, ValueError):
        return unknown("depth", "Cannot collect queue depth")
    return ok("depth", f"{count} pending items", value=count)


app = App(source_id="queue-monitoring", environment=Environment("local"), checks=[queue_depth])
app.register_datasource(QueueFile, path="queue.txt")
```

For more than one configured instance, use `DatasourceFactory`, `App.register_datasource_factory` and an `Annotated` argument with a `FromFactory` selector; see the existing [authoring reference](../runner/README.md). Datasources are constructed on the runner, not on the server. Do not rely on one long-lived instance or a process-global cache across isolated executions. Declare deployment input names through `App(construction_environment=...)` when reconstruction of accepted code must retain those private settings after a broken replacement.

## Several results and asynchronous checks

This complete example uses named outputs and a generator. Each output can have its own target; return one result per declared key:

```python
from collections.abc import Iterator

from mondek_runner import App, Environment, Output, Result, Target, check, ok


@check(
    id="queues",
    outputs=(
        Output("orders", "Orders backlog", Target("queue:orders", "Orders", "queue")),
        Output("billing", "Billing backlog", Target("queue:billing", "Billing", "queue")),
    ),
)
def queue_depths() -> Iterator[Result]:
    yield ok("orders", "No pending orders", value=0)
    yield ok("billing", "No pending invoices", value=0)


app = App(source_id="queue-monitoring", environment=Environment("local"), checks=[queue_depths])
```

A check can be synchronous, a coroutine, a generator or an async generator. Annotate these as `Result`, `Result`, `Iterator[Result]` and `AsyncIterator[Result]` respectively; call or await them normally in policy tests. The runner awaits/iterates them under the same per-assignment execution boundary. One multi-result check has one schedule and shared parameter set, while each result retains independent health/history. Declare `outputs` or `expected_keys`, not both; a missing declared result is missing evidence, not automatic removal.

## Public API map

Prefer these root imports. These are the current experimental authoring surface, not a stable version promise; keep controller and SDK on the same reviewed revision initially. The [detailed runner reference](../runner/README.md) covers advanced behavior and bounds.

| Area | Imports or methods | When to use them |
| --- | --- | --- |
| Project and checks | `App`, `Environment`, `check` | Start here: source identity, default monitored scope and scheduled Python functions |
| Results | `Result`, `ok`, `warn`, `crit`, `unknown` | Report measured health, explanation, optional value and source time |
| Delegated settings | `Parameter` | Typed/bounded fields and complete defaults for UI configuration |
| Collection access | `Datasource`, `App.register_datasource` | Inject a locally configured access provider by annotated type |
| Multiple providers | `DatasourceFactory`, `FromFactory`, `App.register_datasource_factory` | Select a factory-backed access instance with `Annotated` |
| Reuse and output identity | `Binding`, `Output`, `Target` | Reuse a function for distinct instances or assign explicit monitored subjects |
| Location and access | `RunnerContext`, `Capability`, `Placement`, `PlacementContext` | Separate runner location/access from monitored environments; advanced placement rules |
| Browsing groups | `CheckGroup` | Organize source-defined browsing; this does not merge incidents |
| Aggregated findings | `ResultBuilder`, `build_result` | Accumulate bounded findings about one declared result |
| Shared failure meaning | `Condition`, `Impact` | Declare shared incident identity and explicit failed impacts; see [shared incidents](GROUPED-INCIDENTS.md) |
| Discovery review | `Discovery`, `DiscoveryCandidate`, `DiscoveryChoice` | Publish bounded source-owned review hints; see [discovery](DISCOVERY-SDK.md) |
| Module discovery | `discover_checks` | Collect decorated functions; `App(checks=[module])` already handles the usual case |
| Compatibility spelling | `Consumer` | Current alias for `App`; use `App` in new examples |

Keep source, check/binding, result and target IDs stable while their meaning remains unchanged. Labels can change. Use a new ID when a different subject or meaning needs independent history. An `App` can accept ordinary functions, `Binding` instances or modules of decorated checks; no custom check base class is required. You can build project-owned functions/classes and use third-party Python packages without adding a matching Mondek check type.

The root exports above and the CLI below are the starting author interface. Standard checks in `mondek_runner.packs.linux` are an optional documented extension. Module paths for scheduling, SQLite journals, transport, snapshots, workers and wire dictionaries are implementation details, not additional authoring APIs. Advanced `App.metadata`/`coverage_metadata` overrides are version-sensitive extension hooks described in [coverage](COVERAGE.md), not a prerequisite for declaring checks. Installed-package typing checks test the exported surface and its supported function shapes; they do not infer a parameter dictionary type or prove runtime JSON/identity validity.

## CLI map

| Command | Effect |
| --- | --- |
| `mondek-runner init DIRECTORY --sdk-path PATH` | Generate a project without installing it, starting services or registering checks |
| `mondek-runner validate --consumer MODULE:app` | Import trusted code and inspect complete declarations without registration |
| `mondek-runner run --consumer MODULE:app --all --results` | Collect once locally using source defaults; `--check KEY` selects checks and `--check KEY --params JSON` supplies a complete override for that one check (not an `--all` batch) |
| `mondek-runner --consumer MODULE:app --state-dir PATH` | Run persistent scheduling/reporting using one durable runner installation |
| `mondek-runner --status --state-dir PATH` | Read that installation's operational journal without starting another session |
| `mondek-runner doctor --help` | Inspect transport diagnostic options; select probes appropriate to the installation |
| `mondek-policy --help` | Review the separate declarative configuration-policy workflow; see [policy](CONFIGURATION-AS-CODE.md) |

The executable can also run as `python -m mondek_runner`. Checks execute trusted Python under process/resource bounds; this is not a hostile-code sandbox. Validate and test your code with controlled local inputs before connecting it to real datasources.

## Run a check with private credentials

An agent can execute an explicitly authorized datasource check using environment variables without displaying their values. Keep a local env file outside version control (and add its path to the consumer project's ignore rules if it is inside that project). Give it owner-only permissions, normally `chmod 0600 /absolute/path/private.env`; do not put credential values in command arguments, copied prompts or source. Mondek does not load env files itself: uv loads the file and the discovery/check processes inherit its environment.

From a locked consumer project using the [portable non-editable installation](DISTRIBUTION.md), run:

```sh
uv run --locked --no-dev --no-editable --env-file /absolute/path/private.env \
  mondek-runner run --consumer monitoring.app:app --check my-check --results
```

Use your project's actual check key, visible in `mondek-runner validate --consumer monitoring.app:app`. For an editable authoring project, retain its normal editable install mode instead of adding `--no-editable`; for changed non-editable code, reinstall the changed local package before testing as described in [the walkthrough](GETTING-STARTED.md). No controller or persistent state directory is needed for local execution, and it does not register checks or publish observations. Use source defaults, or one complete `--params` override for a selected check; settings saved in the server UI are not fetched. Exit zero means collection completed, not that every result is healthy: inspect the JSON health and evidence.

Authorization must cover the actual datasource and any effects of trusted check code. Use synthetic inputs for failure tests unless real access is explicitly requested. Do not display the env file, dump the process environment or enable shell tracing around secret loading. Owner-only permissions protect against other OS users; they do not isolate secrets from trusted consumer code or an agent running under the same account. Result summaries, details and diagnostics can contain whatever the check emits, so keep credentials out of them rather than relying on automatic redaction.
