# Mondek runner and SDK

Mondek is an experimental monitoring tool with code-defined Python checks and a separate controller for results, incidents, configuration and notifications. This package supplies the typed check-authoring SDK, local execution commands, persistent runner and configuration-policy CLI. The controller never executes your Python code.

Python 3.13 or newer is required. With uv installed, create a monitoring project:

```sh
uv tool install mondek==0.0.1a3
mondek-runner init my-monitoring
cd my-monitoring
uv sync
uv run --locked python -m unittest discover -s tests
uv run --locked mondek-runner validate --consumer monitoring.app:app
uv run --locked mondek-runner run --consumer monitoring.app:app --all --results
```

Connect its runner to the matching Mondek controller:

```sh
uv run --locked mondek-runner --consumer monitoring.app:app \
  --controller http://127.0.0.1:4000 --state-dir .mondek-state
```

The generated example measures a local backlog file; its README explains failure/recovery, data access and deployment. Keep each runner's state directory across restarts and use an absolute path for a service. Store secrets outside source control and use an authentication gateway for externally accessible controllers; this alpha has no built-in authentication.

See [getting started](https://github.com/pitkley/mondek/blob/main/docs/GETTING-STARTED.md), the [SDK guide](https://github.com/pitkley/mondek/blob/main/docs/SDK.md) and [runner deployment](https://github.com/pitkley/mondek/blob/main/docs/RUNNER-DEPLOYMENT.md). Use matching controller/SDK releases; experimental does not promise arbitrary mixed-version compatibility.

Apache-2.0. The wheel/sdist include LICENSE and third-party notices. The SDK has no external runtime Python dependencies.
