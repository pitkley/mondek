# Mondek 0.0.10

Controller and SDK versions are both `0.0.10`, with Git tag `v0.0.10` and controller image tag `0.0.10`. Mondek remains experimental. Run matching controller and SDK versions.

## Maintenance and configuration

- Keep finite or open-ended weekly schedules in a project manifest. Review the changes through the maintenance project API, then apply them atomically. Replacing schedules preserves started windows and individual exceptions. See [maintenance as code](MAINTENANCE-AS-CODE.md).
- Preview how a candidate runner inventory would affect delegated parameter defaults, assignment exceptions and scoped rules. The preview is read-only. See [delegated schema migration preview](DELEGATED-SCHEMA-MIGRATION-PREVIEW.md).

## Runner

- The trivial and Kubernetes GET fixtures passed the [Linux ARM64 warm-worker qualification](WARM-WORKER-QUALIFICATION.md). Warm workers remain opt-in.
- The [runner storage study](RUNNERS-WITHOUT-PERSISTENT-VOLUMES.md) describes identity, journal recovery and evidence loss when a Pod-local state directory is replaced.

## Upgrading

Back up PostgreSQL and complete runner state directories before updating both components. Packaged startup adds maintenance project storage. Existing schedules retain their operator ownership. See [upgrade guidance](UPGRADING.md#0010-maintenance-projects-and-schema-migration-previews).
