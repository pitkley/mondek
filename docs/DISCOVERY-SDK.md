# Discovery evidence in consumer checks

A discovery is optional structured evidence attached to an ordinary check result. It describes observed candidates and consumer-defined review choices. It does not add checks, change inventory, acknowledge incidents or execute controller-side code. The consumer still declares its fixed check outputs and decides what health to report.

```python
from mondek_runner import (
    Discovery, DiscoveryCandidate, DiscoveryChoice, Parameter, warn,
)

review = Discovery(
    title="Review discovered filesystems",
    instructions=(
        "Update filesystems.toml in this monitoring project using the selected "
        "decisions. Review the diff; do not deploy automatically."
    ),
    choices=(
        DiscoveryChoice(
            "monitor", "Monitor capacity",
            description="Add an expected filesystem and its critical threshold.",
            parameters={
                "critical_percent": Parameter(
                    "integer", "Critical percent", minimum=1, maximum=100,
                ),
            },
            params={"critical_percent": 90},
        ),
        DiscoveryChoice("ignore", "Ignore", description="Exclude this filesystem."),
    ),
    candidates=(
        DiscoveryCandidate("data", "Data volume", "Mounted at /data on node-a."),
    ),
)
result = warn("inventory", "One filesystem needs review", discovery=review)
```

The same extension works with `Result`, `ok`, `crit`, `unknown`, and `build_result(..., discovery=review)`. Existing results omit the wire field entirely. Empty candidate lists are valid and can describe a current scan with nothing to review. A missing field does not prove that a previous candidate was accepted; only consumer source and subsequent measurements establish that.

## Identity and configuration

Candidate keys must be stable within the reporting check output. Use a source-defined identity such as a logical volume name, not a random ID or observation timestamp. Choices also have stable keys. The example uses filesystem decisions; containers can define their own choices without a controller-wide disposition vocabulary. Keep instructions specific to the consumer's source files and conventions. They are review data, not permission for an agent to deploy or take unrelated actions.

Choice `parameters` use the existing scalar `Parameter` declarations; `params` supply a complete matching default set. These are proposed-change inputs, not live check parameter overrides. A selection does not mutate the runner's published inventory. Do not publish credentials or sensitive inspection output in candidates, instructions, parameters or defaults: this evidence reaches controller storage, operator screens and copied prompts.

## Bounds and failure behavior

Each discovery has 1–8 distinct choices, 0–100 distinct candidates, and an `omitted` count from 0 to 1,000,000. Candidates and choices use stable keys of at most 128 characters. Labels and titles are nonempty single-line text within 200 UTF-8 bytes. Instructions allow 2048 bytes; candidate details and choice descriptions allow 1024 bytes each. Text must be valid UTF-8 without NUL. Each choice allows at most eight fields, no comparisons, and no unknown schema fields.

The complete discovery is limited to 32,768 bytes of compact JSON with Unicode escaped. The existing aggregate 64 KiB worker output limit still applies to all result lines and diagnostics together, so leave room for the rest of the execution's evidence. Consumers must deliberately select a bounded candidate subset and report the remaining count; the SDK never silently truncates discoveries.

SDK serialization revalidates nested values, and runner supervision independently validates raw worker messages. Invalid discovery evidence makes collection incomplete while retaining earlier valid sibling results with their original timestamps and discovery payloads. Replay transports that original evidence; it is not a fresh scan.

The [shared discovery examples](../contracts/v1/discovery.json) exercise the wire format in both languages. Native regression tests include a real subprocess emitting malformed evidence after a valid result, and installed-wheel typing verifies public discovery declarations outside the checkout.

## Installed local example

[discovery_demo.py](../examples/consumers/src/mondek_examples/discovery_demo.py) observes actual directories beneath `MONDEK_DISCOVERY_DIRECTORY`. It illustrates review choices using directories as stand-ins for logical data volumes, with a maximum of 20 displayed candidates and a 1000-entry inspection bound. It does not detect mounts or implement a filesystem capacity check. Follow-up agent work adds the reviewed bindings or exclusion declarations to that consumer source.

`devenv shell -- python3 tests/browser/run.py --suite discovery` starts the installed example and real controller in a disposable Compose project. The browser changes directories on a project-owned named volume mounted read-only in the runner. No host root or Docker socket is exposed. The journey reviews parameters, copies an agent prompt, verifies inventory did not change, and exercises collection failure, changed observations, stale evidence, recovery and reconnect.
