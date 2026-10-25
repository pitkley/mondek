# Ordinary Python checks

[demo_checks/backlog.py](demo_checks/backlog.py) is a repository-owned asynchronous consumer. The `@check` decorator declares its stable expected result key; the function receives typed thresholds and uses a small datasource to return an ordinary `Result`. The runner supplies installation/session/configuration metadata, scheduling and evidence identity automatically.

Each execution collects a new HTTP snapshot. The result preserves an explicitly supplied source timestamp; a newly received cached snapshot does not acquire a new source age. The synchronous filesystem and HTTP examples live in [the demo's ordinary collectors](demo_checks/collectors.py).

The local fixture can return delay, crash and output-volume fields to exercise real worker supervision. These are explicit demo failure inputs, with no arbitrary command execution. Run all examples with `devenv shell -- mondek demo`; use `devenv shell -- mondek acceptance` to exercise failure/recovery and restart against the packaged system.
