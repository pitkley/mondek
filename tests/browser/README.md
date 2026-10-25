# Browser tests

Run from the repository root:

```sh
devenv shell -- python3 tests/browser/run.py --suite empty
devenv shell -- python3 tests/browser/run.py --suite lifecycle
devenv shell -- python3 tests/browser/run.py --help
```

Use `mondek browser` for all seventeen harness suites; individual suites are usually enough for a focused change. The Linux pack's additional browser journey runs through `mondek linux-acceptance`; the reviewed resource-selection flow across two hosts and three observers runs through `mondek discovery-configuration-acceptance`. The first image build downloads pinned browser dependencies; no host browser installation is needed.

## File map

| Path | Role |
| --- | --- |
| `run.py` | Selects suites, starts isolated Compose services, retains evidence and cleans up |
| `specs/*.spec.mjs` | Operator journeys, grouped by the monitoring feature they exercise |
| `support/helpers.mjs` | Shared UI actions, eventual evidence checks, screenshots and whole-page axe/layout assertions |
| `compose/base.yaml` | Common disposable ports, volumes and browser service |
| `compose/*.yaml` | Suite-specific services and fixture settings; always combined with the root compose.yaml first |
| `fleet/` | Ordinary runner processes and their control fixture for fleet scenarios |
| `playwright.config.mjs` | Suite selection, one worker, bounded waits, zero retries and reporters |
| `Dockerfile`, `package.json`, `package-lock.json` | Matching pinned Chromium/Playwright/axe environment |
| [SCENARIOS.md](SCENARIOS.md) | Detailed workflows, fixture boundaries, scale evidence, artifacts and known limits |

The flow is **select suite → build/reuse images → start owned services → run Playwright → retain evidence → remove owned services/volumes**. Every suite gets its own loopback ports and project; normal installations and volumes are preserved. CI reuses recorded immutable images with rebuilding disabled; see [the CI guide](../../docs/CI.md).

Reports live under ignored `.local/browser/mondek-browser-*/`: summary/cleanup status, Compose/service logs, `report/index.html`, `results.json`, screenshots and failure traces. A failed journey is not automatically retried. Monitoring-loss has a separate restart phase/report. Read the [coverage map](../../docs/ACCEPTANCE-COVERAGE.md) before choosing a broad run.
