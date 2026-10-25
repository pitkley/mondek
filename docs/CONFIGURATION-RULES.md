# Durable configuration rules

The consumer project defines checks, targets, schemas and which complete parameter sets operators may edit. A **configuration rule** saves an operator's values independently of the runner that currently observes a target. It applies when a compatible check appears, remains saved while no checks match, and applies again after the target moves.

Rules may be managed through the UI or explicitly applied from your monitoring project using [configuration as code](CONFIGURATION-AS-CODE.md). A project-managed rule shows its owner and is read-only in the UI. Source defaults remain sufficient when you do not need a rule; both management interfaces use the same contracts, precedence and adoption behavior.

## Choose the right scope

In **Configuration**, choose **New shared rule** to find compatible settings by check name, setting label or source. The chooser groups active delegated checks by their author's source, shared parameter contract and complete schema; similar field names alone never establish compatibility. Each group displays an example check's label and the number of scheduled checks and results sharing those settings. Source-owned checks remain configurable in their consumer code.

Choosing a group starts with **All monitored environments** and **All targets**. The initial parameter values come from one example check's current settings, which may themselves be an exception; review them rather than assuming every check has the same defaults. Alternatively, start from an individual check and choose **Create durable rule** to retain that check's monitored environment and, when all its results share one target, its exact target. Both paths require a scope-and-value preview before saving.

A rule always names its source and parameter contract. Choose **One monitored environment** or **One exact target** to narrow it; target identity is its `kind` and stable `key`. Existing declarations provide suggestions, and manual IDs allow rules for future checks. Discovery separates differing schemas to make their forms understandable, but does not silently narrow a rule to that schema: review still exposes incompatible declarations in the chosen source/contract scope as configuration problems.

For example, a consumer might declare `parameter_contract="volume.pending-items.v1"` and report `Target("volume:orders", "Orders export volume", kind="volume")` from whichever node currently has that volume. A rule for this target in Production follows the stable volume ID. A rule selecting a node's root filesystem needs a node-specific ID instead. Display names, access paths and runner installation IDs are not substitutes for the monitored subject's identity.

The parameter contract is the check author's promise of shared meaning. Two checks with similar `warning` and `critical` fields do not become compatible merely because their forms look alike. Declare a new contract when units or interpretation change.

Delegate portable policy such as thresholds. Keep observer-specific mount paths, connection details and datasource access in source/deployment settings. A source-fixed field represented as a singleton choice is still part of the complete schema; changing that path on relocation would correctly make the captured rule incompatible. The movable-volume example keeps its file access separate from the delegated item-count limits.

## One complete parameter set

Mondek resolves values in this order:

1. An explicit **instance exception** for this scheduled check.
2. The matching enabled rule with the highest numeric priority.
3. The check's **source defaults**.

Each winner supplies the whole parameter set. Mondek does not merge individual fields from several rules. Two matching rules at the same winning priority are a conflict; changing their creation order cannot break the tie. Choose distinct priorities or disjoint scopes.

Changing values through individual or bulk configuration creates instance exceptions; saving identical values remains a no-op. An exception is deliberately local to the scheduled instance and can mask a later rule change. Use **Remove exception and use rules/defaults**, review the resulting values, then save to resume following policy. Existing installations retain their accepted delegated values as exceptions during migration; upgrading must not silently replace existing operator settings. Source defaults follow the latest accepted source declaration; explicit rules and exceptions retain their own values. Every effective configuration freezes the complete values actually assigned to that generation.

## Review and adoption

Rule edits require a preview showing current matching checks, affected results, proposed values, masked exceptions and conflicts. Saving checks the reviewed membership, assignment and rule revisions again. A concurrent source update or another operator edit requires another preview. Rules continue to apply to future compatible instances after the save; the preview is not a permanent selection of today's checks.

The scope summary distinguishes complete matches from partial matches of a multi-target execution, checks excluded by the environment/target restrictions, and checks leaving a previous rule's scope. Exclusions count active checks with the same source and contract, not the entire installation. Disabling preserves the declared scope but releases its current checks to other rules or source defaults. The reviewed changes include both entering and leaving checks; incompatible declarations retain their own field labels and units in the comparison.

Saving and measuring remain separate stages. A disconnected runner continues its accepted configuration until it reconnects and prepares the new desired version. The UI must not present saved parameters as already measured. Each immutable configuration records the origin of its effective values, including the rule revision where applicable.

After saving, the page follows the exact check versions changed by that action, including offline adoption and later superseding changes. An unchanged check or a retained exception does not appear as a newly saved version. Reconnecting the browser preserves this progress; reopening the page shows the current rule, and each individual check retains its current adoption and measurement history. Installation-wide adoption remains available below the Configuration inventory.

An enabled rule with zero current checks is valid. It represents policy waiting for matching coverage, not proof that the target is healthy or monitored. Disabling a rule preserves it and resolves affected checks through the remaining rules or source defaults.

This local slice supports 512 saved rules and at most 512 current checks matching an enabled rule. A later inventory that would exceed that rule's limit is rejected with a configuration diagnostic, preserving accepted monitoring. Narrow or split the rule before expanding coverage. This keeps an admitted rule within the atomic editing limit; disabled rules remain inspectable and can be narrowed before enabling them.

## Schema changes and shared executions

Rules capture the source-declared schema used during review. A semantic match with an incompatible schema is a visible configuration problem, not a missing match. This first implementation deliberately requires the same complete schema for rule application. Refresh a rule from a current source-declared schema and review its values explicitly when adopting a changed schema under the same contract. A rejected source update retains the accepted runtime; its rule diagnostic remains visible even when the new runner has no accepted matching check yet.

For a compatible source evolution blocked by a captured rule schema, disable the rule through review, publish the source update, then load the new declaration into the rule and review it before enabling it again. Changing field types or units requires a new check identity and a new parameter contract for the changed meaning; changing the contract alone does not allow reinterpreting saved values under an existing check identity. An enabled rule cannot simultaneously use two different schemas under one contract; separate their scopes or upgrade the checks together.

Parameters belong to a scheduled execution. If that execution reports several targets, a target-specific rule applies only when every output belongs to that target. A partial target match is a conflict with guidance to split the execution into independently configurable checks. A contract-wide or environment-wide rule may intentionally configure the complete shared execution.

## Configuration continuity and incident history

The same target ID on two runners produces two independent observed instances. A rule can configure both; it does not elect an observer, combine evidence or merge incidents.

An intentional complete inventory withdrawal retires the old instance and records `source_removed` on its open incidents. Reappearance on another runner creates a new stream with its own measurements and incidents. Old history stays accessible. Disconnection alone does not withdraw membership or claim recovery. Automatic observer handoff, disappearance grace and incident continuity across observers remain separate product work.

## Try it locally

```sh
devenv shell -- mondek rules
# http://localhost:4014/configuration
devenv shell -- mondek rules-acceptance
devenv shell -- mondek rules-down
```

The demo installs the same ordinary Python consumer on two node runners. A node-local file supplies actual monitored data; explicit membership identifies which node observes the logical volume. The acceptance command uses its own disposable Compose project, moves the stable target, exercises conflicts and reconnects, and retains evidence under `.local/acceptance/`. Normal demo shutdown retains its volumes.
