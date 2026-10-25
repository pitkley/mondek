# Controller

Phoenix/LiveView with explicit Ecto contexts, PostgreSQL and Oban. `Mondek.Monitoring` owns configuration, session admission, evidence reduction and incidents; `Mondek.NotificationWorker` records attempts before external delivery. `Mondek.Sweeper` handles bounded retention and reconstructable UI freshness ticks.

Use `devenv shell -- mondek demo` for the complete release and runner, `devenv shell -- mondek test` for native tests, and [DEVELOPMENT.md](../DEVELOPMENT.md) for native Phoenix iteration. Configuration and observations persist in PostgreSQL; browser state is not authoritative. The controller never imports or executes Python checks.
