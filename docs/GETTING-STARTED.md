# Your first monitoring project

This walkthrough starts an empty local Mondek server, creates your own Python monitoring project, and connects one runner. It uses a small file-backed queue check so failure and recovery need no external service or credentials. Read [the concepts](CONCEPTS.md) for the relationship between server, runners and project code.

## Installed artifacts

The registry release is being prepared. After the selected alpha is published, start the server using [the two-service image recipe](../deploy/README.md), then use Python 3.13+ and uv on the runner host:

```sh
uv tool install mondek==0.0.1a2
mondek-runner init my-monitoring
cd my-monitoring
uv sync
uv run --locked python -m unittest discover -s tests
uv run --locked mondek-runner validate --consumer monitoring.app:app
uv run --locked mondek-runner run --consumer monitoring.app:app --all --results
uv run --locked mondek-runner --consumer monitoring.app:app \
  --controller http://127.0.0.1:4000 --state-dir .mondek-state
```

Use the exact SDK version matching the controller release; the generator pins the installed version in the project. Before registry publication, install the qualified local wheel directly rather than inventing a registry release. The generated README covers local input, failure/recovery and a non-editable deployment. Use an absolute state directory for a persistent service. No Mondek checkout or Nix is needed for installed artifacts.

## Contributor/source walkthrough

You need a Mondek source checkout, Nix, devenv 2.3.1 or newer, and a running Docker engine. The checkout supplies Python and uv. Run the commands below from one chosen Mondek revision; the first builds/downloads can take several minutes. This is a local evaluation with loopback access and a local notification receiver. Review [the access boundary](CONTROLLER-AUTH.md) before hosting a server for other machines.

## 1. Start the server

From the Mondek checkout, run:

```sh
devenv shell -- mondek start
```

Open http://localhost:4001/guide. The installation is empty: a running server alone does not monitor anything. Existing installations keep their data; if the default ports are already occupied, choose another local installation/port before continuing instead of deleting volumes. Use the server address printed by your command in the runner settings below.

## 2. Create a separate project with a portable SDK

In the Mondek checkout, enter its toolchain shell:

```sh
devenv shell
```

The remaining commands in this section run inside that shell. Choose a new project path whose parent exists; generation refuses to overwrite an existing directory:

```sh
export MONDEK_CHECKOUT="$PWD"
export MONDEK_PROJECT="$HOME/my-monitoring"
uv build --project runner --out-dir .local/sdk
uv run --project runner --locked mondek-runner init "$MONDEK_PROJECT" --sdk-path ./runner
mkdir -p "$MONDEK_PROJECT/vendor"
cp .local/sdk/mondek-0.0.1a2-py3-none-any.whl "$MONDEK_PROJECT/vendor/"
```

Generation creates `src/monitoring/app.py`, tests and a `sample-backlog.txt` input. It starts no runner or registration. The generator initially selects an editable SDK checkout for development. For this portable installation, replace its entire `[tool.uv.sources.mondek]` block in your project's pyproject.toml with:

```toml
[tool.uv.sources.mondek]
path = "vendor/mondek-0.0.1a2-py3-none-any.whl"
```

Remove the generated `editable = true` line from that block. Then install the project and its retained SDK wheel:

```sh
uv lock --project "$MONDEK_PROJECT"
uv sync --project "$MONDEK_PROJECT" --locked --no-dev --no-editable
cd "$MONDEK_PROJECT"
```

Keep pyproject.toml, uv.lock, the vendor wheel, source and tests in your own project repository. Record the chosen Mondek revision and wheel checksum; 0.0.1a2 is candidate metadata until actually released, not a promise that all builds with that version are interchangeable. See [distribution](DISTRIBUTION.md) for relocation, artifact provenance and upgrade details. The generated README also describes the editable development alternative; use the installed commands below for this wheel-based path.

## 3. Validate and collect locally

From your monitoring project directory:

```sh
.venv/bin/python -m unittest discover -s tests
.venv/bin/mondek-runner validate --consumer monitoring.app:app
.venv/bin/mondek-runner run --consumer monitoring.app:app --all --results
```

The first run should report a complete collection with a backlog result of OK and value 0. These commands do not register checks with the server. `validate` imports trusted project code and checks its declarations. `run` executes the checks; exit status zero means collection completed, and can still accompany a CRIT result. Inspect the measured health in its JSON output.

Local execution uses defaults from your source, unless you select one check with `--check CHECK_KEY` and supply a complete `--params` override. It does not fetch settings saved in the server's UI.

## 4. Start one persistent runner

Still in your project directory:

```sh
MONDEK_CONTROLLER_URL=http://127.0.0.1:4001 \
  .venv/bin/mondek-runner --consumer monitoring.app:app --state-dir .mondek-state
```

Leave it running. In the web UI, **Runners** shows the connection and **Checks** shows Queue backlog. Wait for a fresh measurement with value 0: contact alone is not enough. The runner publishes checks from code; you do not create them in the UI. A remote runner needs an address it can reach; localhost always refers to its own host.

## 5. Observe a failure and recovery

In a second terminal, enter your monitoring project directory and change only the sample input:

```sh
printf '1000000\n' > sample-backlog.txt
```

Wait for a fresh Critical result and inspect its incident. The local receiver records notification delivery; it contacts no external recipient. Then:

```sh
printf '0\n' > sample-backlog.txt
```

Wait for a fresh healthy result and measured recovery of that incident. Missing or malformed input reports Unknown rather than removing the check. In **Configuration**, you can edit the example's explicitly delegated thresholds and follow Saved → Prepared → Active → Measured. The Python project still defines their meaning and allowed values.

## 6. Restart and make it yours

Stop the runner with Ctrl+C, then repeat the same start command with the same `.mondek-state` directory. Confirm the same runner installation returns and fresh measurements resume. Give each independently running process its own durable state directory; never run two against the same state. For deployment updates, keep state outside directories that will be replaced.

Edit the project's app.py and tests to monitor your own goal, using the [SDK guide](SDK.md). Because this path installs non-editably, stop the runner and reinstall changed consumer code before restarting:

```sh
# Inside the Mondek toolchain shell, from your monitoring project:
uv sync --locked --no-dev --no-editable --reinstall-package mondek-monitoring
```

Then rerun the local tests, validate and run commands before restarting. Choose stable source/check/result/target identities before observing real resources. Keep credentials and access paths in private runner-side settings. Source changes can deliberately retire checks; an import failure is not a request to remove them.

To stop the server, run `devenv shell -- mondek stop` from the Mondek checkout; its database persists. For repeatable runner deployment, continue with [runner deployment](RUNNER-DEPLOYMENT.md). For help from a coding agent, use [the matching agent workflow](AGENT-WORKFLOWS.md); its instructions should follow this same human-readable path.
