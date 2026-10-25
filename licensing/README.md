# Licensing maintenance map

Start with [coverage, credits and commands](../docs/LICENSING.md). Use `devenv shell -- mondek licenses` to refresh evidence and generated files, then `devenv shell -- mondek licenses-check` to verify policy, notices and lock consistency. Review policy/evidence changes alongside dependency updates; generated files are not a substitute for that review.

| Path | Role and maintenance |
| --- | --- |
| `policy.json` | Hand-reviewed package SPDX policy and exact-version supplements; missing or stale exceptions fail |
| `inventory.json` | Generated package versions, scope, artifact identity and full collected notice evidence; do not edit by hand |
| `source-notices.json` | Known source adaptations, upstream URLs and retained notices included in runtime credits; ordinary source edits are not fingerprint-gated |
| `PHOENIX-LICENSE.md` | Retained original scaffold notice; preserve upstream terms and include them in generated controller credits |
| `runtime-sources.json` | Reviewed runtime versions, checksum-pinned source archives and generated per-notice hashes |
| `runtime/` | Byte-preserved runtime license and incorporated-code evidence, including complete source/header files where notices are embedded; these are upstream material, not Mondek implementation |
| `pyproject.toml`, `uv.lock` | Locked collector/build-check tooling, included in package coverage |

The collectors and failure checks live under `scripts/*licenses.py` and `tests/licensing/`. Package generation produces root notices, the embedded controller subset and SDK artifact notices; their [scopes differ intentionally](../docs/LICENSING.md#generated-and-distributed-files). Runtime refresh may download large archives; routine checks use retained evidence. Normal code review preserves source attributions; runtime upgrades update their pinned evidence.

Final-image audits retain digest-bound reports under ignored `.local/licenses/images/`. They cover exact component ownership and notice evidence, with [distribution-provided OS packages assessed separately](../docs/LICENSING.md#distribution-provided-os-components) from application dependencies. Host tools, build/test operating systems and downstream consumers have separate boundaries.
