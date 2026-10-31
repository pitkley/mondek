# Mondek

Mondek is code-driven monitoring: write Python checks that describe what matters to your systems, run them where their data is accessible, and inspect the results in a web UI. Your code owns the monitoring logic, expected coverage and datasource access. Operators can change the thresholds and settings you explicitly delegate, without moving that logic out of Python.

> [!WARNING]
> Mondek is experimental software that has seen only limited testing so far. It was implemented almost entirely by modern AI coding agents. Evaluate it alongside your existing monitoring before relying on it.

Mondek has no built-in user authentication or permission management. Use it on loopback or behind an [authenticated gateway with direct origin access blocked](docs/CONTROLLER-AUTH.md); admitted operators share full access. The experimental alpha assumes trusted operators and runners.

A **Mondek server** stores results, tracks incidents and delivers notifications. **Runners** load your monitoring project and execute its checks independently near the systems they observe. A check can produce several results, and your project can use ordinary Python libraries and abstractions. See [how the pieces fit together](docs/CONCEPTS.md).

Mondek is available as a [published controller image](https://github.com/pitkley/mondek/releases/tag/v0.0.1a2), a [Python SDK on PyPI](https://pypi.org/project/mondek/) and source. Use matching controller/SDK releases, or the same reviewed source revision when building locally; see the [alpha scope](docs/RELEASE-NOTES.md).

Use the [documentation index](docs/README.md) to find guides for getting started, writing checks, operating an installation and contributing.

## Get started

For the image-based server installation, use [the controller/PostgreSQL Compose recipe](deploy/README.md). For the installed SDK workflow, follow [your first monitoring project](docs/GETTING-STARTED.md). Release `0.0.1a2` is available from GHCR and PyPI. The source/contributor workflow below remains available for local development.

For agent-assisted installation before any server is running, copy [the repository setup prompt](docs/AGENT-WORKFLOWS.md#before-the-ui-is-running) into your coding agent.

Reusable [agent skills](skills/README.md) cover server setup, runner setup/deployment and check authoring.

With Nix, devenv 2.3.1+ and a running Docker engine:

```sh
devenv shell -- mondek start
# Empty local installation: http://localhost:4001/guide
```

Follow [your first monitoring project](docs/GETTING-STARTED.md) to create a separate Python project, install a portable SDK wheel, connect a runner and observe failure/recovery. Start with the [SDK guide](docs/SDK.md) when writing checks. To stop the local server while keeping its data:

```sh
devenv shell -- mondek stop
```

To try sample monitoring instead, run `devenv shell -- mondek demo` and open http://localhost:4000. Stop it with `devenv shell -- mondek services-down`. The [demo explanation](examples/demo_checks/README.md) describes the included SDK and local inputs; [additional examples](examples/consumers/README.md) cover node and datasource monitoring. Each installation has separate persistent data. Initial builds/downloads can take several minutes.

Write ordinary Python checks, register datasource access and declare expected results in a [consumer package](examples/consumers/README.md). Dedicated runners can query monitoring databases; node-local runners can inspect accessible filesystems, processes and application files. **Checks** searches the result inventory; **Configuration** edits only parameters explicitly delegated by the source. Source changes add or withdraw monitoring while retaining history. One execution can produce several independently tracked results.

Your Python project owns its monitoring policies and abstractions. Mondek runs that code and preserves its evidence; it does not require a built-in check type for each use case. See the [authoring API](docs/SDK.md) and [porting guide](docs/MIGRATING-CONSUMERS.md).

[Check inventory](docs/CHECK-INVENTORY.md) groups results by their monitored target, with problems first, separate observer evidence and complete matching summaries across bounded pages.

[Result detail](docs/RESULT-DETAIL.md) leads with the last confirmed measurement and your check's explanation, keeping later collection failures separate from retained health.

[Configuration and runner inspection](docs/OPERATOR-PAGES.md) explains adoption progress, measurement coverage and notification delivery.

[Configuration rules](docs/CONFIGURATION-RULES.md) apply delegated values to current and future compatible checks, including stable targets that move between runners. Try the separate two-runner example with `devenv shell -- mondek rules` and verify it with `devenv shell -- mondek rules-acceptance`.

[Configuration history and Git](docs/CONFIGURATION-GIT.md) automatically preserve UI edits and accept validated pushes to one main branch. Verify the UI/Git/runner round trip and fresh-installation restore with `devenv shell -- mondek configuration-acceptance`.

Use the [node and datasource deployment walkthrough](docs/RUNNER-DEPLOYMENT.md) to validate, run and start installed consumers outside the demo fixtures.

The UI offers reviewable, copyable [coding-agent prompts](docs/AGENT-WORKFLOWS.md) for setup, project creation, check authoring, deployment planning, source removal and incident investigation.

Use [scheduled maintenance](docs/MAINTENANCE.md) for planned notification windows or [finite weekly series](docs/RECURRING-MAINTENANCE.md), including stable targets that move between runners. Review exact dates before saving; checks continue throughout and each window remains independent of other windows and incident acknowledgements.

The sample filesystem check measures the Linux container's filesystem. Demo ports bind to loopback, and demo notifications use a local recording webhook receiver.

[Runner deployment](docs/RUNNER-DEPLOYMENT.md) explains installed consumers and persistent runner state. Review the [controller trust boundary](docs/CONTROLLER-AUTH.md) before hosting an installation. Use a reverse proxy for access protection; general production readiness remains outside the current milestone.

See [DEVELOPMENT.md](DEVELOPMENT.md) for focused commands and [operations](docs/OPERATIONS.md) for behavior and bounds.

The [acceptance coverage map](docs/ACCEPTANCE-COVERAGE.md) lists every maintained verification command, its CI job and intentional manual-only coverage.


[Acknowledgements](docs/ACKNOWLEDGEMENTS.md) cover incident lifetimes, long holds, UTC expiry and notification behavior, with focused acceptance commands.


## Layout

| Directory | Purpose |
| --- | --- |
| `controller/` | Phoenix, LiveView, explicit Ecto contexts, PostgreSQL, Oban |
| `runner/` | Python execution supervisor, scheduler, local spool, control and reporting |
| `contracts/` | [Experimental protocol specification and shared test vectors](contracts/README.md) |
| `examples/` | Installed node, Prometheus and capacity consumers, plus the original demo |
| `tests/e2e/` | Real controller/runner/notification acceptance scenarios |
| `scripts/` | Repeatable development and validation commands |
| `docs/` | Current authoring, operator and correctness guides |


See the [experimental alpha notes](docs/RELEASE-NOTES.md) and [fixed-source installation guide](docs/DISTRIBUTION.md) for distribution scope and compatibility.

## License

Apache-2.0. See [LICENSE](LICENSE). Third-party components retain their own licenses and notices.

See [contributing](CONTRIBUTING.md) for verification and dependency updates, and [security](SECURITY.md) for private reporting and deployment boundaries.
