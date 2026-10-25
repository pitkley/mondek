# Observer retirement and replacement

## Authority and intent

A source publication is one runner installation publishing one source. It is the unit of retirement: retiring one source must not withdraw another source on the same runner. An observer's measurements, configuration and incidents remain independently identifiable throughout its lifecycle.

Lost contact, stale evidence and failed discovery never mean that monitoring is no longer wanted. A complete accepted source inventory can withdraw that publisher's membership. An explicit operator decision can retire the entire publication. Both are administrative changes, not measured recovery.

## Reviewed lifecycle

From **Coverage → Publishing runners**, inspect a publication and review retirement with a reason. The review identifies affected checks and open incidents, declarations that will disappear, scopes losing their final publisher and remaining independent observers. The saved action retains its reviewed identities and durable history. Changed membership or control authority requires another review.

Retirement means **Retired from this controller**. It fences inventory republication and current admission for that installation/source, even after a new boot or a greater inventory revision. The runner receives an authoritative control response without the retired assignments. A disconnected runner can still execute its last accepted schedule until it reconnects; buffered evidence retains its original identity and age and cannot become current for a successor.

An operator may explicitly identify another active publication of the same source as the replacement. Replacement readiness requires fresh desired-version measurements for every previously selected, resolved scope and compatible effective configuration. A fresh Critical measurement qualifies; it is evidence of a problem, not a failure to observe. Missing, stale, unconfirmed or incompatible coverage blocks a complete replacement. Ordinary retirement remains available when monitoring is intentionally ending.

Replacement records lineage and ends predecessor contributions administratively. It does not transfer stream identities, measurements, individual acknowledgements, instance exceptions or delivery budgets. If the successor already contributes a failure to the same explicitly shared condition, the existing condition episode can remain open under its normal rules. A healthy successor cannot be described as recovery of the predecessor's independent failure. Stable-target maintenance and durable configuration rules continue matching their existing identities.

Saved decisions retain their exact replacement measurements and original configuration, independently of ordinary recent-result retention. **Inspect saved measurement** shows only the output keys that established that decision, with original details and times. Following **Current result** shows the successor's current evidence separately; later recovery cannot rewrite the saved decision.

Restoration is a separate reviewed action. It removes the publication fence, but replay of its last accepted inventory must not revive retired assignments. The controller requests rediscovery for the exact restoration lifecycle revision. The runner must successfully discover installed code and persist a newer inventory carrying that revision; a previously cached but rejected deployment cannot satisfy the request. New membership incarnations need their own current admission and fresh measurements. Historical evidence and closed episodes stay unchanged. Existing older SDK installations continue ordinary monitoring, but must upgrade their SDK before using restoration.

Restored checks use source defaults and matching durable configuration rules. Individual check exceptions and acknowledgements remain with the retired instances. Review these values after restoration when an installation previously used individual overrides.

At most 512 source publications on one runner may wait for restoration at once. Finish or cancel a waiting restoration before exceeding that bound. Cancellation retires the publication again; a later restore has a new lifecycle revision and cannot be satisfied by the cancelled request's inventory.

## Local walkthrough

```sh
devenv shell -- mondek publishers
devenv shell -- mondek publisher-acceptance
devenv shell -- python3 tests/browser/run.py --suite publishers
devenv shell -- mondek publishers-down
```

Open [Publishing runners](http://localhost:4017/coverage/publishers). The separate demo runs two installed service observers of the same source and a node observer of another source. Retire or replace the predecessor, inspect its saved decision and original evidence, then restore it into new check identities. `publishers-down` retains only this demo's data; acceptance and browser commands use disposable project-specific services and volumes. The normal installation receives the same lifecycle UI through `devenv shell -- mondek start`.

## Election and grace boundaries

Independent read-only observers remain the default. Target identity identifies the subject; a shared condition identifies related failures. Neither declares interchangeable execution or cross-observer recovery authority.

No inactivity timer retires a publication or silently reduces expected coverage. A future handover deadline could name a successor and wait for qualifying evidence while leaving existing authority unchanged; expiry would report an incomplete handover. This is different from interpreting silence as disappearance or merging unrelated failure episodes because they occur close together.

Automatic single-executor scheduling would change the current promise that runners execute during controller outages. A lease cannot stop arbitrary Python already running on a disconnected machine. Such a mode would need explicit interchangeable-replica declarations, durable authority epochs, admission fencing and a documented choice between stopping on lease loss and permitting overlapping execution. It is separate from this explicit lifecycle flow.

## Restoration protocol

Control may return `inventory_refresh`, keyed by source ID, with `after_revision` and `lifecycle_revision`. A waiting publication accepts only an inventory newer than that floor carrying the exact epoch as `restoration_revision`. The SDK records that marker after successful isolated discovery; it is transport authority metadata, not part of the consumer's semantic source fingerprint. Retirement returns `publisher_retired`; an inventory that cannot satisfy a waiting restore returns `publication_refresh_required`.

While a request is outstanding, the runner's reported status includes its requested floor/epoch, `pending`, `failed` or `publishing` state, and original attempt time. These reports help diagnose discovery; they do not establish accepted membership or fresh measurement coverage. A cancelled request cannot authorize a later restoration, even if both have the same accepted-inventory floor.

## Acceptance boundaries

- Retire one source while another source on the same runner continues collecting.
- Reject automatic re-entry after newer inventory, boot/session changes and controller restart; retain old buffered evidence historically.
- Invalidate stale membership/control reviews, preserve exact replay behavior and serialize retirement against inventory and ingestion.
- Require successor-owned, fresh desired evidence and compatible effective scope/configuration; accept measured Critical while rejecting stale, missing, old-session or old-generation evidence.
- Preserve shared-condition continuity only through independently admitted contributors; never inherit individual acknowledgement or invent recovery.
- Restore into new assignment/result incarnations after a new inventory revision, with preserved history and durable configuration rules.
- Verify full impact counts and bounded pages, draft/reconnect recovery, desktop/narrow layouts and real browser operation.

## Research context

Checkmk uses explicit clustered-service mapping and warns that vanished-service deletion can interfere with moving resources ([clustered services](https://docs.checkmk.com/latest/en/clustered_services.html)); dynamic discovery distinguishes missing child data from failed source collection ([dynamic host management](https://docs.checkmk.com/latest/en/dcd.html)). Mimir's HA election requires explicitly identified replica groups ([HA deduplication](https://grafana.com/docs/mimir/latest/configure/configure-high-availability-deduplication/)). Kubernetes' leader-election implementation warns that leases alone do not provide fencing ([client-go leader election](https://raw.githubusercontent.com/kubernetes/client-go/master/tools/leaderelection/leaderelection.go)). These support explicit authority boundaries rather than inference from matching target names.
