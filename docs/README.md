# Documentation

These guides are for people using and developing Mondek. Coding agents use the same SDK and protocol references; [agent workflows](AGENT-WORKFLOWS.md) provide task-specific entry points. Start with the path that matches your task; there is no need to read every guide before trying the experimental source preview.

## Get started

Read [how Mondek fits together](CONCEPTS.md), then follow [your first monitoring project](GETTING-STARTED.md): start an empty server, create a separate Python project, connect a runner and observe failure/recovery. The [repository README](../README.md) has the short startup commands; [source installation](DISTRIBUTION.md) explains fixed revisions and portable SDK artifacts. Read the [preview scope](RELEASE-NOTES.md) and [access boundary](CONTROLLER-AUTH.md) before hosting an installation.

## Write and deploy checks

Start with the [Python SDK guide](SDK.md) and [runner API reference](../runner/README.md). Use [installed examples](../examples/consumers/README.md) or the [demo explanation](../examples/demo_checks/README.md) for working code. The [porting guide](MIGRATING-CONSUMERS.md) covers translating an existing monitoring project.

| Task | Guide |
| --- | --- |
| Run your project near its data | [Runner deployment](RUNNER-DEPLOYMENT.md) and [runner contexts](RUNNER-CONTEXTS.md) |
| Monitor several environments | [Environment bindings](MULTI-ENVIRONMENT-CHECKS.md) |
| Define browsing groups and related failures | [Check groups](CHECK-GROUPS.md) and [grouped incidents](GROUPED-INCIDENTS.md) |
| Delegate configuration to operators | [Configuration as code](CONFIGURATION-AS-CODE.md) and [durable rules](CONFIGURATION-RULES.md) |
| Declare expected monitoring and placement | [Coverage](COVERAGE.md) |
| Report discoverable resources | [Discovery SDK](DISCOVERY-SDK.md) and [review workflow](DISCOVERY-REVIEW.md) |
| Use the optional Linux checks | [Check packs](CHECK-PACKS.md) |

## Operate an installation

Start with [operations and bounds](OPERATIONS.md), [check inventory](CHECK-INVENTORY.md), [result detail](RESULT-DETAIL.md) and [configuration/runner inspection](OPERATOR-PAGES.md).

| Task | Guide |
| --- | --- |
| Investigate gaps or lost monitoring | [Missing measurements](MEASUREMENT-INVESTIGATION.md), [coverage](COVERAGE.md) and [monitoring-loss notifications](MONITORING-LOSS.md) |
| Inspect runners and delivery attempts | [Runners and notifications](RUNNERS-AND-NOTIFICATIONS.md) and [email setup](EMAIL-NOTIFICATIONS.md) |
| Acknowledge incidents or plan notification windows | [Acknowledgements](ACKNOWLEDGEMENTS.md), [maintenance](MAINTENANCE.md) and [repeating maintenance](RECURRING-MAINTENANCE.md) |
| Retire or replace an observer | [Observer lifecycle](OBSERVER-LIFECYCLE.md) |
| Review configuration history or restore it | [Configuration Git](CONFIGURATION-GIT.md) |
| Manage history and upgrades | [Retention](RETENTION.md) and [upgrade guide](UPGRADING.md) |

## Contribute and inspect the implementation

Use [contributing](../CONTRIBUTING.md), [development commands](../DEVELOPMENT.md), [CI flow](CI.md), [release preparation](RELEASING.md) and the [acceptance coverage map](ACCEPTANCE-COVERAGE.md) to choose verification for a change. [Dependency maintenance](DEPENDENCY-MAINTENANCE.md) and [licensing/credits](LICENSING.md) explain the update gates; [security](../SECURITY.md) covers private reporting.

For implementation work, start with [protocol contracts and fixture enforcement](../contracts/README.md), [SDK/HTTP boundaries](API-BOUNDARIES.md), [transactions and locks](TRANSACTIONS-AND-LOCKS.md) or [UI conventions](UI-CONVENTIONS.md). These references describe the current implementation and its limits; the protocol's v1 marker is experimental, as explained in the [versioning guidance](../contracts/README.md#versioning).

[Resource discovery settings](DISCOVERY-CONFIGURATION.md) explains monitored-host scope, reviewed saves and accepted inventory receipts.
