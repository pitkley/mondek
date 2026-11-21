# Mondek 0.0.6

Controller and SDK versions are both `0.0.6`, with Git tag `v0.0.6` and controller image tag `0.0.6`. Mondek remains experimental. Run matching controller and SDK versions.

## Monitoring and operator workflows

- Checks that read weekly samples can set source measurement freshness up to eight days while keeping the original sample timestamp. The execution interval remains capped at one day. See [the SDK guide](SDK.md).
- The Overview paginates the combined incident list. The browser favicon shows the installation-wide open incident count.
- Recurring maintenance HTTP responses include local and UTC occurrence dates. Saved occurrences expose their current and original dates and status. See [recurring maintenance](RECURRING-MAINTENANCE.md).

## Deployment and access

- Set `MONDEK_NOTIFICATION_ADAPTER=off` to collect measurements and track incidents without a delivery receiver. Existing delivery history stays available and deployment mode still defaults to SMTP. See [notification operations](RUNNERS-AND-NOTIFICATIONS.md#turn-delivery-off).
- Kubernetes deployments can mount webhook configuration from a projected Secret using a dedicated file group. See [webhook configuration](WEBHOOK-NOTIFICATIONS.md).
- Configuration Git can read a token from a file on each request, so operators can rotate it without restarting the controller. An opt-in token header also allows Git clients to use a separate gateway credential for forward authentication. See [Configuration Git](CONFIGURATION-GIT.md).

## Security

The controller updates Phoenix LiveView to 1.2.14, which includes the fix for [CVE-2026-126334](https://cna.erlef.org/cves/CVE-2026-126334.html).

## Upgrading

Back up PostgreSQL and runner state, then upgrade the controller and SDK together. This release adds no database migrations. Review delivery and Configuration Git settings if you adopt either opt-in feature, and upgrade both components before publishing checks that use the larger freshness range. See [upgrade guidance](UPGRADING.md#006-delivery-configuration-git-and-measurement-freshness).
