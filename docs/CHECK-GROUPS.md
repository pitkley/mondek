# Source-defined check groups

A target identifies the resource being monitored. An optional `CheckGroup` organizes results for browsing without changing that identity. A group is scoped by monitoring source and monitored environment, independently of the runner that observes it. Results without an explicit group fall back to their target.

```python
from mondek_runner import Binding, CheckGroup, Output, Target

node = CheckGroup("node", "node.example.test")

binding = Binding(
    container_check,
    group=node,
    outputs=(
        Output(
            "status",
            "Container running",
            Target("container:controller", "Controller", "container"),
        ),
    ),
)
```

`Binding.group` provides the default for its outputs. An explicit `Output.group` overrides that default, including outputs declared by `@check`. Each result has one browsing group; groups are flat and do not duplicate results across several memberships. Keep the group key stable when changing its display label. Keys use the SDK stable-identifier syntax and fit within 128 characters; labels are nonempty single-line UTF-8 text within 200 bytes.

Grouping is presentation metadata. Renaming or moving a group must not replace resource history, acknowledge failures, correlate incidents, select execution placement or broaden configuration and maintenance scope. Group changes are published through the normal consumer source flow. Both selected and excluded declarations retain their group metadata in Coverage, even when the monitored scope cannot yet be resolved.

Multiple runners can publish results into the same source/environment group. Each observation remains independent. Different sources or monitored environments remain separate even when their group keys or labels match. Group labels describe browsing organization rather than authoritative resource ownership; publishers should use common consumer helpers to keep their labels consistent.

## Browsing and live updates

Checks offers List and By group. Both use the same groups and keep precise target links on result rows. The group column searches the complete matching index independently of the global result filters: hiding the selected group with this search does not replace its results. Entries are ordered alphabetically, so a health change does not reshuffle navigation. Results within a group remain ordered by urgency.

The column initially loads 100 entries. Scrolling or the keyboard-accessible Load more button extends the cumulative listing by 100, up to 1,000; refine the local search beyond that bound. Loaded limits, selection and search are represented in the URL, and the browser retains column scroll across live updates and reconnects. Changes to membership or names can change the alphabetical prefix; this is a live index, not a frozen inventory snapshot. Group totals reflect global result filters.

Groups have no separate lifecycle: an empty group disappears from the active results view. During staggered runner updates, declarations with the same scoped group key and different labels use the lexicographically first label until publication converges. Different sources or monitored environments never merge merely because labels or keys match. Old exact-target investigation links preserve their scope; a legacy navigation selection opens a containing group (alphabetically first if the target's results now span groups).

Run the packaged acceptance journey with `devenv shell -- python3 tests/browser/run.py --suite check-groups`. It publishes real measurements from two installed consumers, exercises independent target identities and large-group navigation, then republishes renamed/moved groups and verifies retained result and acknowledged incident identities. It uses a disposable Compose project and local notification capture.
