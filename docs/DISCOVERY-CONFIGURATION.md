# Resource discovery settings

Automatically discovered Linux results link to **Configure resource discovery**. The editor identifies the monitored host and environment separately from the observing runner. Both scope choices concern that host only:

- **Only this discovery check** saves an instance exception, including selection of resources discovered later by that check. It does not follow a replacement observer.
- **Host policy** applies to compatible checks for the exact source, parameter contract, environment and host across current and future observers. Existing local exceptions remain in force until separately reviewed and removed.

Review shows the complete parameter set and marks changed values. Unchanged values are pinned too; settings do not merge field by field. The resource shortcut adds or removes an exact-name exclusion while preserving other patterns. Removing one exclusion does not override another matching pattern. Required resources remain monitored independently of discovery filters; change their source declaration to remove the expectation.

Saving opens a persistent change receipt. Activation, accepted inventory and ordinary check measurement are separate evidence. A successful inventory must identify the active assignment/generation, carry the reviewed selection values and come from the same source and observer. Failed scans retain accepted resources. Administrative retirement preserves historical failure evidence; it is not a measured recovery. A resource included again gets a new observation that needs its own evidence.

Shared-rule conflicts and masking are shown during review. The editor does not raise priority automatically or clear local overrides. A new runner can briefly discover using source defaults before adopting a host policy.

## Inventory metadata

The optional version-1 `discovery` object is declared per check. A Linux manager publishes `kind: manager` and `capability: linux.resources.v1`. Resource checks publish `kind: resource`, `manager_key`, `resource_kind`, `resource_name` and `origin` (`discovered` or `required`). Relationships must reference a manager in the same admitted source/observer inventory and monitored environment. They do not establish group membership, incident equivalence or maintenance propagation. Existing check and target keys remain unchanged.

The public SDK `ManagedResource` declaration supplies resource metadata. Linux packs supply both manager and resource declarations automatically. Older inventories without metadata retain the generic settings paths; the controller never guesses a manager from labels or target hashes.

Optional top-level `catalog_selections` records a manager's accepted or failed catalog scan, its complete selection values, and, after activation, the active assignment ID and generation. These receipts are transport evidence outside the immutable executable snapshot identity. This avoids generation feedback loops and conflicting immutable snapshot bytes. The controller validates declarations and admitted configuration evidence; it never imports source Python or predicts arbitrary discovery callbacks.

## Verification

Run `devenv shell -- mondek discovery-configuration-acceptance` for the isolated packaged controller, three runner processes and real Chromium journey. Two observers monitor Host A and a third monitors Host B, using synthetic Linux kernel files with the ordinary SDK. The journey covers local exclusion, re-inclusion and retained history, exact-host policy with masking and separately reviewed removal, gateway outage/reconnect, required resources, failed scan retention and runner restart. Desktop and 320/390px checkpoints include accessibility checks. Each invocation owns a disposable Compose project and retains separate operator/failure/recovery browser reports under `.local/acceptance/` before removing its containers and volumes. This tests real application persistence, transports and workers against controlled evidence; it does not qualify a deployed host's kernel or credentials.

For a manual review, append `--review`. This keeps a separate loopback-only installation running with ten-second fixture checks and prints its URL, Compose project name, evidence directory and exact stop command. It contains sample data and local recording notifications. Run the printed stop command from the repository root after review; retain volumes to keep its history or explicitly remove only those review volumes.
