# Mondek 0.0.9

Controller and SDK versions are both `0.0.9`, with Git tag `v0.0.9` and controller image tag `0.0.9`. Mondek remains experimental. Run matching controller and SDK versions.

## Maintenance

- Stable check selectors follow runner replacements by exact source, check key and monitored environment. A selector can cover every output of the check or restrict coverage to an exact target. See [maintenance scope](MAINTENANCE.md#choose-the-scope-deliberately).
- Weekly maintenance can continue until canceled. Mondek reviews an initial set of dates, keeps a bounded reserve and catches up before notification workers start. The series detail shows any future date that cannot be scheduled because of its local clock rules. See [open-ended weekly maintenance](RECURRING-MAINTENANCE.md#run-a-schedule-until-canceled).

## Runner and monitoring

- Checks can opt in to [bounded stale reads](CONSUMER-STATE.md#opt-in-to-a-stale-read) during qualifying transport failures. Cached reads preserve original timestamps and expiry and carry no compare-and-set version. Enable the session-scoped cache explicitly on the runner.
- A check can [defer evaluation](MONITORING-LOSS.md#deferred-output-evaluation) of one output to an exact owner output on the same source, runner and monitored environment. The owner needs fresh admitted evidence. Deferral preserves the previous confirmed measurement and the original monitoring-loss deadline.
- Monitoring-loss incident details expose the recorded closing evidence used in restoration notifications.

## Upgrading

Back up PostgreSQL and complete runner state directories before updating both components. Packaged startup applies two migrations for selector validation and recurring generation. See [upgrade guidance](UPGRADING.md#009-stable-maintenance-and-temporary-evaluation-handoffs).
