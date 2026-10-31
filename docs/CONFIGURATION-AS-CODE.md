# Configure a monitoring project from code

UI saves and Git pushes now share automatic controller-owned configuration history. Prefer the [configuration repository](CONFIGURATION-GIT.md) for routine round trips. The project-policy CLI below remains a compatibility/import workflow; it cannot silently overwrite newer UI edits.

Check code and optional installation policy can live in the same project. Runners publish check definitions and execute them; `mondek-policy` explicitly manages controller rules. Starting or reconnecting a runner never applies installation-wide policy. The controller receives JSON and does not import your Python code.

## Start with values in your check code

Keep `@check(params=...)`, `Binding(params=...)` and consumer-owned helpers as your ordinary source configuration. No matching policy file is required. A check without a `parameters` schema keeps its complete parameter set source-owned. Declaring a schema makes the complete set operator-configurable: source values become defaults, which a rule or instance exception may override. Binding values change defaults; they do not change whether the check has delegated its parameters.

Values resolve as one complete set: **instance exception → highest-priority matching rule → source defaults**. Values are not merged field by field. Configuration shows the origin, differences from code defaults and the policy beneath an exception. It also explains when removing an exception would uncover a conflict. A saved desired version is separate from the version the runner last measured. If saved settings change while a form is open, the UI keeps the older draft, explains its version and offers an explicit reload.

Use a rule when you want shared policy for present and future compatible checks, a stable moving target, or changes independent of a check deployment. Keep datasource URLs, credentials, paths, target membership and schedules in the consumer/deployment rather than putting private access settings in operator policy.

The [same-project example](../examples/policy/README.md) uses a reusable filesystem collector, shared Python declarations and either a handwritten JSON policy or an ordinary Python generator. Choose one authoring method; the two example files demonstrate equivalent inputs, not files you must maintain together.

## Inspect effective settings

Install the SDK in your monitoring project's locked environment as usual. It now provides `mondek-policy` alongside `mondek-runner`. From this checkout, use:

```sh
devenv shell -- uv run --project runner mondek-policy inspect \
  --controller http://localhost:4001 --source YOUR_SOURCE_ID
```

Inspection does not execute a check or change settings. It shows the controller's accepted source defaults, saved values, origins, exceptions and desired/measured generations. Use `--page 2` for more checks and `--json` for machine-readable output. It cannot inspect an unpublished edit in your working tree; validate and publish that source through your existing runner workflow, then inspect what the controller accepted. Private datasource settings are not part of the inventory.

## Author optional policy

```json
{
  "version": 1,
  "project": "my-monitoring",
  "rules": [
    {
      "key": "production-volume-limits",
      "name": "Production volume limits",
      "source_id": "my-checks",
      "parameter_contract": "volume.pending-items.v1",
      "environment": "production",
      "params": {"warning_items": 50, "critical_items": 100}
    }
  ]
}
```

The project and rule keys identify resources independently of labels. A rule names the source and the author's parameter contract; it does not copy the parameter schema. Planning resolves and validates against the controller's accepted declarations within the rule's scope. A new rule therefore needs a compatible source to have registered first; a new future scope without matches requires an unambiguous source contract. An existing rule may remain with no current matches using its captured schema. Conflicting schemas within the proposed scope need an explicit correction; the planner never guesses from matching field names.

Optional selectors are `environment` and an exact `target_kind`/`target_key` pair. Omit selectors to cover all compatible environments or targets within the named source and contract. Optional `priority` defaults to zero and `enabled` defaults to true. The source and parameter contract of an existing managed key cannot be reinterpreted; remove that key and use a new one for a different meaning. See [durable rules](CONFIGURATION-RULES.md) for conflicts, schema evolution, complete parameter sets and shared executions.

This slice manages durable parameter rules only. It rejects unknown fields and resource types rather than silently ignoring them. Notification policy and recurring maintenance are separate later increments.

## Validate, review and apply

Run these commands inside your monitoring environment, or prefix each with `devenv shell -- uv run --project runner` from this checkout:

```sh
mondek-policy validate policy.json
mondek-policy plan policy.json --controller http://localhost:4001 --base REVIEWED_GIT_HEAD --out policy.plan.json
mondek-policy apply policy.plan.json --controller http://localhost:4001
```

`validate` is offline: it checks document structure and scalar limits without imports, credentials, network access or check execution. `plan` contacts the controller to resolve schemas and show creates, updates, adoption, removals, unchanged rules, affected checks, complete values and masking exceptions. Conflicts in effective settings block application. An instance exception can mask an underlying rule conflict; the plan discloses it, and you must resolve that conflict before removing the exception. Neither command changes saved configuration.

For an existing project, a plan that changes its rules requires `--base` with the full 40-character controller Git revision you reviewed. Fetch the configuration repository, reconcile any intervening UI or Git edits into your document, and use `git rev-parse origin/main` to obtain that revision. Do not automatically fetch a fresh revision and retry an unchanged stale document: review the differences first. New projects and exact no-op documents may omit `--base`. An explicitly supplied stale revision is always rejected. API callers use the equivalent `base_head` field. The plan response includes `repository_head`; exported policy documents remain portable and do not embed installation revisions.

`apply` uses the exact reviewed document and controller address. A review expires after fifteen minutes; any accepted configuration change, or changed relevant source declarations, requires a new preview. Ordinary measurements do not invalidate it. Application is atomic for the supported managed set, and repeating an unchanged policy preserves rule/configuration revisions. The controller records an apply receipt, so an uncertain response can be retried with the same saved plan. A retry of a previously successful older plan returns its historical receipt and discloses newer project changes; it never rolls current policy back.

With Git access disabled, review current settings in the UI and copy the accepted revision from Configuration history for `--base`. `GET /api/v1/configuration/revision` also exposes that revision for inspection; automatically fetching it is not a substitute for reconciling the document you intend to apply.

UI editors use scoped concurrency guards: a changed rule, affected check or reviewed bulk member requires a new review. An unrelated accepted change can coexist with the UI edit; the atomic configuration snapshot preserves both. Git and legacy project-policy documents describe broader desired state and therefore use the accepted repository revision as their baseline.

Unapplied plans created before configuration-history support must be recreated with a reviewed baseline. Previously applied saved plans retain historical receipt replay.

Saved plans use owner-only file permissions and may contain operational settings. Keep them out of Git; `.local/` is suitable in this checkout. `--out` replaces the named local output file. The CLI refuses redirects and uses bounded input, response size and request lifetime. It never automatically replans or retries a write.

To generate policy in Python, emit ordinary JSON locally and pass `-` as the input filename:

```sh
python policy.py | mondek-policy validate -
python policy.py | mondek-policy plan - --controller http://localhost:4001 --base REVIEWED_GIT_HEAD --out policy.plan.json
```

Keep generation independent of datasource construction and live secrets. The policy command reads the resulting JSON; it does not load the generator or your runtime `App`. Do not generate project policy from a runner's filtered inventory: another runner may legitimately observe subjects that this one excludes.

## Existing UI rules and explicit exceptions

Export a project's current managed rules:

```sh
mondek-policy export --project my-monitoring --controller http://localhost:4001 --out policy.json
```

To bring an existing UI-created rule under project ownership, add an explicit adoption to the export:

```sh
mondek-policy export --project my-monitoring --adopt RULE_UUID=production-volume-limits \
  --controller http://localhost:4001 --out policy.json
```

Export only writes the local document. Review it, then plan/apply to transfer ownership. A rule owned by another project/key cannot be taken over implicitly. The UI labels each rule’s project and permits previewed edits. UI edits are automatically committed; reconcile them before applying an older project document. Explicit instance exceptions remain available for individual scheduled checks and are never silently removed by applying policy. Use the existing reviewed **Remove exception and use rules/defaults** flow to resume following policy.

Removing a rule from a complete project document removes only that project's rule after review. An explicit empty `rules` list removes all its managed rules. Unmanaged UI rules, other projects, check membership, instance exceptions and measurement/incident history remain. A removal plan previews the resulting fallback values. Prior rule snapshots remain in durable apply receipts and historical configurations retain their original origin/value snapshots.

## Bounds and verification

A document supports at most sixty-four rules, within the existing installation limit of 512 rules. One atomic plan can affect at most 512 current scheduled checks. Narrow the scope or use separate named projects, each with its own complete document, before exceeding those bounds. Never apply partial documents under the same project name: omitted rules are removed. The first implementation retains project apply receipts for reliable retry/audit; it does not currently expire that history automatically.

```sh
devenv shell -- mondek policy-acceptance
devenv shell -- python3 tests/browser/run.py --suite policy
```

The acceptance command uses disposable Docker services and installed workers reading real local files. It exercises CLI planning/application, ownership/adoption, source and exception precedence, replay, conflicts, moving subjects, offline adoption and reconnect. The browser suite exercises managed inspection, source comparisons, explicit exceptions and live ownership/removal at desktop and narrow widths. Neither command modifies external installations or contacts an external notification recipient.
