# Optional check packs

A pack is an ordinary Python library providing checks and convenient binding helpers. It has no special controller authority: the runner publishes its declarations, placement selects execution, and the existing configuration, incidents and notification flows apply. Importing a pack never activates it. Consumer-specific monitoring remains ordinary code; this is not an attempt to build a complete monitoring standard library.

## Distribution and selection

The initial dependency-free Linux pack ships inside the runner wheel at `mondek_runner.packs.linux`. Import it only in projects that want it. No agent, package manager or privileged installer runs in the controller or when a runner starts. Future dependency-heavy packs can be separate pinned Python packages installed alongside the consumer using the same deployment workflow; a marketplace, remote installation and UI-created checks are not required by this design. Pack upgrades use normal source sync and runner reinstall/rebuild. Nested SDK pack code participates in the frozen worker dependency fingerprint, so old snapshots cannot silently execute changed pack implementation.

Code declares the pack, host access and **required expectations**. With `discover=True`, the runner also discovers mounts and network interfaces automatically. **Selection policy** decides which discovered resources to monitor, including resources first seen later. Existing parameter contracts control both that selection and the measurement thresholds. Discovery runs only on the matching host, outside execution replay; importing the module performs no host I/O.

```python
from mondek_runner import App, Environment, RunnerContext, Target
from mondek_runner.packs.linux import Interface, LinuxHost, Selection, linux_checks

production = Environment("production", "Production")
host = Target("host:node-a", "node-a")
app = App(
    source_id="my-monitoring",
    runner=RunnerContext(
        "node-a",
        capabilities=("linux-host",),
        target=host,
        local_environment=production,
    ),
    checks=linux_checks(LinuxHost(
        host, production,
        filesystems=("/", "/srv/data"),
        interfaces=(Interface("eth0"),),
        discover=True,
        filesystem_selection=Selection(exclude=("/var/lib/kubelet/pods/*",)),
        memory=True,
        cpu_load=True,
    )),
)
```

`filesystems` and `interfaces` declare required resources, independently of discovery filters: exclusions never silence a required resource. Empty tuples remove required expectations; they do not disable discovery. `discover=False` retains explicit-only behavior. `memory=False` or `cpu_load=False` disables the corresponding host check. `Interface("tun0", healthy_states=("up", "unknown"))` explicitly permits a tunnel's kernel state. A missing required interface or mount is critical.

Discovered resources use host-local mountpoint/interface identity. Reordering declarations, changing a host label or changing the collection root preserves identity. A new mountpoint/interface gets a new resource identity. A CSI volume can be discovered wherever mounted, but this pack does not infer persistent-volume identity across hosts: that needs an authoritative volume identifier from a CSI/Kubernetes-aware integration. Broad threshold and selection rules survive churn; an exact host-local target rule does not follow a volume to another host.

### Automatic resource selection

`Selection(default_include=True, exclude=("pattern", ...))` monitors all eligible resources except matches. `Selection(default_include=False, include=("/srv/*", "/data"))` monitors only matches, including future mounts. Exclusions take precedence over includes. Matching is case-sensitive shell-style glob matching (`*`, `?`, character classes), not regular expressions. Mount patterns match the full mountpoint; interface patterns match its name. The example's Kubernetes exclusion is an optional operator choice, not a built-in exclusion of CSI mounts.

The default filesystem policy excludes kernel pseudo-filesystem types (including `tmpfs`) and immutable `squashfs` images, such as Snap package mounts. SquashFS images are read-only by design; capacity exhaustion alerts are not useful for these images. These remain configurable defaults: remove a type from the exclusion field to discover it, or declare a resource explicitly as required. Real LXD storage filesystems remain eligible; excluding the LXD package's SquashFS mount does not exclude its writable data. The interface policy excludes `lo`, `veth*`, `docker*` and `br-*` to avoid treating every container link as an expected external connection. Change or clear these defaults to monitor bridges automatically. Discovery reports link operational state, so an idle bridge can legitimately be down and requires an appropriate monitoring choice.

To apply an exclusion immediately without upgrading a runner, open **Configure resource discovery** from a managed Linux result (or from its discovery check’s configuration), select the intended local-check or exact-host policy scope, append `,squashfs` to **Exclude filesystem types (comma-separated globs)** while preserving the other types, then review and save the complete settings. Keep the exact host/environment scope for a single machine, or deliberately broaden it for shared defaults. Existing discovered images retire after the policy becomes active and the next successful inventory refresh; their incidents close administratively and history remains. Saved rules and instance exceptions override future source defaults, so an existing overridden exclusion list must be updated explicitly.

With discovery enabled, **Linux resource discovery** is a normal host check with the `mondek.linux.discovery.v1` contract. Use its Configuration page or a shared rule to edit default inclusion, include/exclude patterns and excluded filesystem types. Pattern fields are comma-separated, with whitespace trimmed around each pattern. Paths containing spaces are supported; a literal comma cannot be expressed as one pattern. Use shared rules to apply the policy across hosts and future resources. Required resources remain in source because their absence must remain a failure.

Selection changes take effect after the policy configuration becomes active and the next successful inventory refresh. The discovery check's measurement describes resources matching its active policy; publication and the first measurements of new resource checks follow independently. The default refresh interval follows the host's 60-second check interval. Filters permit at most 64 patterns per field, each at most 256 characters, within the field's 2048-byte limit.

### Refresh, disappearance and failure

The runner refreshes discovered membership periodically. New selected resources become ordinary independently scheduled checks. A discovered resource that disappears remains in inventory during the configured disappearance grace (120 seconds by default), with unavailable evidence instead of a fabricated recovery. After successful scans establish continued absence, it retires through the existing inventory lifecycle. Explicit exclusion retires it without waiting for disappearance grace. History remains inspectable; open incidents close administratively as source removal, not measured recovery. If it later reappears after retirement, it starts a new monitoring incarnation under the same resource target; shared target rules still match, while old incident controls remain historical.

Unreadable or malformed discovery evidence retains the previous catalogue and reports collection unavailability. Failed scans cannot establish absence. Discovery bookkeeping persists across runner restart. Each accepted resource catalogue is frozen into the worker snapshot: preparation, retries and offline execution never enumerate a different resource set. Unchanged scans do not create new executable revisions. Discovery and membership changes remain bounded by the runner's 512-check limit; exceeding a limit is an error, not silent truncation.

Repeated mountpoints are legitimate, including in systemd service namespaces. Discovery groups their filesystem types before selection: a mountpoint is excluded by type only when every reported layer matches the exclusions. This keeps excluded pseudo-filesystem stacks from blocking the entire host's discovery, without hiding a potentially relevant layer. A selected mountpoint whose capacity collector cannot distinguish overlapping entries remains individually unavailable; discovery never guesses a visible filesystem from mountinfo ordering.

Every check requires the declared `linux-host` capability, the monitored environment and the exact host execution target. The same project can declare all hosts; each runner selects its host only. Access failures do not change placement or erase declarations. Memory/load target the host; disks and links have precise resource targets for durable rules. All appear in the host's browsing group, avoiding a sidebar full of one-check resources.

## Checks and semantics

| Check | Defaults | Evidence and limits |
| --- | --- | --- |
| Memory | WARN ≥80%, CRIT ≥90% | `(MemTotal - MemAvailable) / MemTotal`; available includes reclaimable cache. Linux 3.14+ fields required. Host RAM, not a container's memory limit. |
| CPU load | WARN ≥1, CRIT ≥2 per CPU | Five-minute load average divided by online CPU count from `/proc/stat`. Includes uninterruptible tasks; this is not CPU utilization or cgroup quota saturation. |
| Filesystem | Blocks and inodes each WARN ≥80%, CRIT ≥90% | Requires an exact mount entry and matching device. Block usage follows available-to-unprivileged-processes semantics, excluding reserved free blocks. Worst of blocks/inodes determines health; numeric value is block percentage. Filesystems reporting zero total inodes explicitly omit inode assessment. |
| Interface | Required state `up` | Kernel operational state; an explicitly selected missing link is CRIT. Does not measure connectivity, throughput, error rate or packet loss. |

Default schedule: every 60 seconds, ten-second execution limit, 180-second freshness. Each selected resource gets an independently bounded worker. Kernel text reads are capped at 1 MiB; interface inventory is bounded at 4096 entries and source selection at 128 mounts/128 links per host. Missing expected resources are measured failures; unreadable, inconsistent or malformed evidence returns UNKNOWN (collection unavailable), preserving the last confirmed measurement rather than presenting it as fresh. A failed mount lookup never falls back to measuring its parent filesystem. An overmount ambiguity or changed device during collection is unavailable.

## Configuration as code and UI

Measurement contracts are `mondek.linux.memory.v1`, `mondek.linux.load.v1` and `mondek.linux.filesystem.v1`. Warning/critical threshold fields are shared across hosts and resources, so a durable rule can apply to all compatible checks, including future declarations. The `mondek.linux.discovery.v1` contract controls discovered membership through the same rule and exception flow. Collection roots, required resources and required-interface accepted states remain source-owned; operators cannot redirect collection outside the declared host root through threshold or selection fields.

For example, include this rule in the project's normal policy document and use the existing `mondek-policy plan`/`apply` workflow:

```json
{
  "key": "linux-filesystem-limits",
  "name": "Filesystem capacity limits",
  "source_id": "my-monitoring",
  "parameter_contract": "mondek.linux.filesystem.v1",
  "params": {
    "warning": 85,
    "critical": 95,
    "inode_warning": 80,
    "inode_critical": 90
  }
}
```

Use Configuration → shared settings for the same contract in the UI. Add an environment or exact filesystem target selector for narrower policy; use the normal configuration export/seed to obtain its stable key rather than hand-computing it. Instance exceptions remain available. Plain Python projects can also override a returned `Binding`'s `params` with `dataclasses.replace`, preserving the complete schema and comparisons. No separate pack-specific configuration language is introduced.

## Native and container deployment

A native Linux runner reads `/proc`, `/sys` and selected mount metadata as its ordinary service user. No root, sudo, Docker socket or new capability is required. Existing systemd sandbox visibility must permit these paths; inaccessible paths are reported explicitly. `/` means the runner's current Linux namespace; running the example inside Docker measures that namespace and kernel-visible host counters, not the macOS machine or necessarily the Docker host's mount inventory.

To deliberately inspect a Linux host through a read-only root bind, pass `root="/hostfs"`. Memory/load read that root's proc files; mount inventory uses `/hostfs/proc/1/mountinfo`, then verifies selected paths' device IDs before space collection. Expose the intended host proc, sysfs and filesystems, including relevant submounts. Merely creating directories is insufficient. Do not use a different container's PID namespace or an incomplete root bind and assume it represents the host. Permission/device mismatch is unavailable, with diagnostic guidance. Actual host mount propagation remains an operator deployment check; synthetic fixture coverage is not evidence about the real server's mounts.


## Local verification

```sh
devenv shell -- mondek linux-acceptance
```

This builds the installed example in isolated Docker services. One observer reads real Linux kernel evidence; another reads bounded synthetic kernel files for deterministic memory/link/mount failure, invalid evidence and recovery. It exercises dynamic additions, failed discovery, restart, disappearance and administrative incident closure, plus buffered reconnect and local notifications. A real Chromium walkthrough covers host grouping, details, shared thresholds, discovery selection, narrow layout and browser reconnect; the saved selection is then exercised against newly appearing resources. Only this command's disposable project is removed. Evidence is retained under `.local/acceptance/`. It does not access your deployed hosts or prove their filesystem permissions.

See [resource discovery settings](DISCOVERY-CONFIGURATION.md) for scope, required resources and accepted-inventory progress.
