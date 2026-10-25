# Working on Mondek

Mondek is an experimental monitoring controller and Python SDK/runner. Read DEVELOPMENT.md, CONTRIBUTING.md and docs/README.md before implementation, then the current contracts and guides relevant to the change. Existing behavior, public APIs and documented contracts are the starting point; historical examples are not additional requirements.

## Environment and commands

Use the committed devenv environment for language runtimes and tools. Inspect `devenv version` and `devenv info`; keep shell entry cheap. Docker Compose owns PostgreSQL and other long-running services. Do not start services, install dependencies, migrate databases or generate secrets merely by entering a shell. Keep devenv and language lockfiles committed; update compatible compiler/runtime/LSP pins together.

Use `devenv shell -- mondek help` and DEVELOPMENT.md for supported commands. `mondek setup` installs dependencies explicitly; `mondek check` runs static, format, installed-package, workflow and licensing checks; `mondek test` runs native tests. Select focused real service/browser suites from docs/ACCEPTANCE-COVERAGE.md. Avoid duplicate or full CI runs unless their coverage is needed.

## Architecture and correctness

The controller uses Phoenix/LiveView, Ecto/PostgreSQL and Oban. The SDK/runner uses typed Python interfaces. Keep explicit contexts and ordinary modules; avoid introducing generic workflow frameworks or a service per rule. The controller never imports or executes consumer Python code. Consumer-specific checks and credentials belong outside this repository.

Runner scheduling is independent of transport. Keep one outstanding execution per assignment; bound execution time, output and spool storage. Retry preserves evidence identity and original age. A retained verdict is display state, never a new measurement or permission to skip execution. Preserve stable installation, session, configuration and result identities, replay/admission checks and source-versus-operator configuration ownership.

Use real transactions/constraints for activation, ingestion, current state and durable notification work. Never hold database transactions open during external I/O, preparation or long polling. Database migrations run automatically at packaged controller startup; update migration/upgrade guidance when schema changes. Do not rewrite published migration history or release tags.

## Implementation and verification

Use idiomatic Elixir/Python and native formatters. Test meaningful behavior, especially time boundaries, concurrent writes, replay, partial collection, outages and restart. Use controlled clocks/events plus real process/HTTP/database coverage where relevant. For operator UI changes, preserve clear action scope, current versus historical evidence, consistent vocabulary and usable desktop/narrow layouts; walk through the real app. Fixture-only tests do not establish end-to-end behavior.

Use isolated Compose projects for destructive acceptance work. Stop/remove only resources owned by the current task; preserve ordinary development volumes and unrelated workloads. Never use broad Docker prune commands as test cleanup. Keep real secrets, consumer environments, runtime state, browser profiles and generated evidence out of Git and Nix env/store outputs. Do not send real notifications or change external deployments without authorization.

Use concise result summaries and human-readable findings alongside structured measurement data. Keep errors useful without disclosing credentials or raw private responses. Add dependencies only when needed, preserve upstream notices and regenerate/review the existing third-party credits when dependencies change. Do not add speculative license/source fingerprint gates; follow docs/LICENSING.md.

Keep Markdown paragraphs on single source lines, developer commands short and substantive design material in dedicated docs. Record consequential decisions near the affected design; keep documentation and relevant tests aligned. Work in focused commits and report what changed, what passed and remaining limits. Do not push branches, publish registry artifacts/releases or modify remote repository settings without explicit user authorization.
