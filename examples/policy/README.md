# Checks and optional controller policy in one project

`monitoring.py` reuses the built-in filesystem collector. Its schema and defaults are sufficient on their own: no policy file is required to run the check. `settings.py` declares the source identity, parameter contract and defaults once. The optional `policy.py` generator imports those declarations and changes production thresholds. `policy.json` shows the equivalent handwritten format; choose one authoring method rather than maintaining both in your project.

From the repository root, use the pinned development environment:

```sh
devenv shell -- uv sync --project examples/policy --locked
devenv shell -- uv run --project examples/policy python examples/policy/policy.py
devenv shell -- uv run --project examples/policy mondek-policy validate examples/policy/policy.json
```

The generator emits JSON. Pipe that output into `mondek-policy validate -` or `mondek-policy plan -`; the policy command does not import or execute it. Keep credentials and private datasource settings out of the generated document.

UI edits are automatically versioned in the [controller configuration repository](../../docs/CONFIGURATION-GIT.md). After a project's initial creation, a changed project manifest requires `plan --base REVIEWED_GIT_HEAD`. Fetch and reconcile UI/Git edits before selecting that baseline; never automatically retry an old generated document against a freshly fetched head. Ordinary Git editing is the preferred round-trip workflow.

Once this consumer has published its declarations to a controller, review and apply the optional policy explicitly:

```sh
devenv shell -- uv run --project examples/policy mondek-policy plan examples/policy/policy.json --controller http://localhost:4001 --out .local/policy-example.plan.json
devenv shell -- uv run --project examples/policy mondek-policy apply .local/policy-example.plan.json --controller http://localhost:4001
devenv shell -- uv run --project examples/policy mondek-policy inspect --source policy-example --controller http://localhost:4001
```

These commands do not launch a runner. The check must be published first so the controller can validate its authoritative schema. Run this example with your existing runner deployment workflow and consumer `monitoring:app` from this directory. Applying an empty `rules` list removes only this project's managed rules; it does not remove checks or instance exceptions. Existing exceptions can mask a new policy value, and inspection shows the effective and underlying values. Saved plans contain operational settings and use owner-only file permissions; retain them locally outside Git.
