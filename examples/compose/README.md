# Advanced demo overlays

Start an empty Mondek installation with `devenv shell -- mondek start`. These optional overlays illustrate larger monitoring setups; `mondek help examples` lists their start/stop commands.

| Overlay | Example |
| --- | --- |
| `parity.yaml` | Node and Prometheus observers, plus opt-in capacity/bulk profiles |
| `placement.yaml` | One consumer placed across nodes and a monitoring runner |
| `rules.yaml` | Delegated settings for a movable volume across runners |
| `linux.yaml` | Installed Linux pack consumers |
| `grouped.yaml` | Independent observers contributing to a shared incident |
| `coverage.yaml` | Source-declared targets/services and measurement coverage gaps |
| `publishers.yaml` | Retirement/replacement examples layered on coverage.yaml |

The repository's `compose.yaml` is always first, so relative build and bind paths still resolve from the repository root. For direct inspection, run `docker compose -f compose.yaml -f examples/compose/parity.yaml config` there. CLI commands keep separate project names and ports; their stop commands preserve volumes. Disposable acceptance/browser overlays live under tests/, with the same root base-file rule.
