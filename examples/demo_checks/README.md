# The demo consumer

These checks are sample monitoring code shipped with Mondek. `devenv shell -- mondek demo` starts them in the sample runner image, together with the server and a local target/notification receiver. Stop that demo with `devenv shell -- mondek services-down`; its data persists.

`from mondek_runner import ...` resolves to the SDK included in this checkout. runner/Dockerfile copies runner/mondek_runner into the image and puts /app/runner and /app/examples on PYTHONPATH. This demo does not download an independently released SDK package. A source-mode command likewise uses the checkout's `PYTHONPATH=runner:examples`.

The controller starts empty; this consumer publishes the same source-owned Python inventory as any monitoring project. Assignment IDs are generated UUIDs, while `filesystem`, `http` and `consumer` are source check keys. The collectors in collectors.py and backlog.py belong to this example rather than an alternate SDK execution path.

The filesystem result measures the runner container's filesystem. The HTTP and backlog examples use the owned local fixture. They illustrate check execution and delegated settings, not your machine's complete monitoring configuration.

For your own monitoring, start with [a separate project and portable installed SDK wheel](../../docs/GETTING-STARTED.md). That project owns its code/dependencies and runner state. Use [the SDK guide](../../docs/SDK.md) to write checks, or [installed consumers](../consumers/README.md) for broader node/datasource examples. Editing the demo is not required to create a monitoring project.
