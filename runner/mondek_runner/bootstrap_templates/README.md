# My monitoring

This project contains ordinary Python checks. The local sample has a private input file and two thresholds explicitly delegated to Mondek's configuration UI. No services were started and no checks were registered by project creation.

## Install and check locally

Use Python 3.13+ and uv. __SDK_MODE__ The first sync creates uv.lock; commit it with your project, then use --locked.

```sh
uv sync --project __PROJECT__
cd __PROJECT__
uv run --locked python -m unittest discover -s tests
uv run --locked mondek-runner validate --consumer monitoring.app:app
uv run --locked mondek-runner run --consumer monitoring.app:app --check queue-backlog --results
```

## Connect to a Mondek server

Start the server with its image-installation Compose recipe, or use an existing server. Run this project's runner with the appropriate controller origin:

```sh
uv run --locked mondek-runner --consumer monitoring.app:app \
  --controller http://127.0.0.1:4000 --state-dir .mondek-state
```

Checks appear when the runner publishes its complete inventory. Change Warning at or Critical at in Configuration and wait for Measured. The server never runs your Python code. Local run uses source defaults unless --params supplies a complete override; it does not fetch saved server configuration.

From this project directory, set `printf '1000000\n' > sample-backlog.txt` for a critical result, then `printf '0\n' > sample-backlog.txt` for recovery. Missing or malformed input reports UNKNOWN without removing monitoring. Stop the runner with Ctrl+C and reuse its state directory on restart. Never share an active state directory between runners. Use an absolute state path for a service and protect any externally accessible server with an authentication gateway.

For deployment, install with `uv sync --locked --no-dev --no-editable`, use `.venv/bin/mondek-runner`, and reinstall changed project code before restarting. Keep the locked environment and persistent runner state separate. See the Mondek SDK and runner deployment guides for private datasource settings and gateway authentication.

## Make it yours

The copied example app and tests retain their Mondek template copyright/license notices. Your additions remain yours: preserve those existing notices and add your own appropriate attribution for your contributions. Project generation does not assign your new code to the template author. The generated metadata and initially empty package initializer carry a license identifier without inventing a copyright holder.

Edit `src/monitoring/app.py` and its tests. Choose the source, environment, check, target and output identities before monitoring real resources; `node-a` and the sample queue are examples. Keep an identity when the monitored subject and meaning stay the same. Choose a new one when a different resource or meaning needs independent history. Each runner installation needs its own durable state directory.

The file path is private deployment configuration, separate from the UI's thresholds. The default is `sample-backlog.txt` in the directory where you launch the runner. Set `MONDEK_BACKLOG_FILE` to an absolute path to use another file or launch from another directory. This runner sees files on the machine where it runs; a container needs the relevant mount. The declared construction environment lets accepted code retain its original settings if a replacement import fails.

Add your own helpers, classes, packages and checks. Mondek supplies execution, evidence, inventory and explicitly delegated settings; domain logic remains yours. Restart the runner after installing changed code. A successful complete inventory removes checks absent from `checks`; an import error retains accepted monitoring. Removal closes current incidents as source removal, not recovery, and retained history remains inspectable. Refactoring a function while retaining its identity preserves continuity.

Before uninstalling this runner's monitoring entirely, publish the same App with an empty `checks` list and confirm retirement in the controller, then stop the runner. Uninstalling the package first is an import failure, not a request to remove coverage.

Use the controller's Setup runner guide for copyable coding-agent prompts. Before deploying beyond local development, review the Mondek runner deployment guide; authentication and production fleet deployment remain deferred.
