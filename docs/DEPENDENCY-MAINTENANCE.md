# Dependency maintenance

Every update includes its declarations, locks, applicable notices and verification evidence in the same reviewed pull request. Routine CI runs native checks and packaged smoke; use selected browser coverage or manual full coverage when the changed dependency requires it. Validation jobs have no publishing credentials or repository write permissions.

## Automation and coordinated pins

The [Renovate configuration](../renovate.json) is deliberately disabled until the repository owner installs/selects the Renovate GitHub App and enables this repository. Activation is a repository setup step, not a prerequisite for maintaining dependencies manually. Keep dashboard approval before branch creation, no automerge, two concurrent PRs and one new PR per hour. Start by approving one small update and inspecting its generated locks. The local validator is pinned in the opt-in maintenance environment:

```sh
devenv --profile maintenance shell -- renovate-config-validator --strict --no-global renovate.json
```

Renovate supports [uv lock updates through its PEP 621 manager](https://docs.renovatebot.com/modules/manager/pep621/). It does not regenerate Mondek's license evidence. A maintainer checks out the update branch, regenerates the credits, reviews the diff and pushes that completion before merging; CI intentionally rejects a partial update. Do not introduce a privileged workflow that executes dependency-PR code to write these changes automatically.

| Dependency | Update scope |
| --- | --- |
| Ruff | Group runner/licensing declarations and all four uv locks (including the examples’ embedded SDK metadata); regenerate the build/test license inventory and root credits |
| Mix/npm libraries | Update matching locks, collect exact-version notices, review compatibility and run relevant native/packaged coverage |
| Playwright | Group npm package/lock and browser image tag/digest; retain matching browser binaries and rerun relevant browser journeys |
| Python, Elixir/OTP, Node, uv/uv_build, esbuild | Manual coordinated update with devenv, all applicable Dockerfiles/CI pins, runtime sources/notices and frozen SDK compatibility; bot updates are disabled for these packages |
| devenv CLI | Align the CI install tag, devenv.yaml minimum and developer/getting-started guides; the consistency gate rejects drift. Verify the CI profile without changing unrelated language/input pins |
| Nix/devenv inputs | Run `devenv update` in a focused branch; review the full lock diff and resolved compiler/LSP/tool versions before changing matching image/tool pins |
| GitHub actions | Pin reviewed full commit hashes with release comments; inspect runtime/permission/migration requirements and exercise the hosted workflow |
| Other image digests | Review OS/runtime evidence for the actual changed images and run exact-image audits plus relevant acceptance |

`mondek check` runs `scripts/dependency_pins.py --toolchain`. It checks shared Python image identities, runtime notice versions, CI Python/uv, uv build dependencies, Ruff declarations, npm declaration/lock versions, Playwright image/package, controller/SDK versions and the resolved devenv Python/Elixir/OTP/Node/uv/esbuild tools. A Nix update that changes one of these tools fails until the matching declarations and artifacts are coordinated. Runtime source hashes and notice bytes have their separate licensing gate. The pin check is a consistency guard; it does not establish compatibility with a new runtime by itself.

## Complete a proposed update

Review the intended declaration changes first. Resolve only the affected ecosystems; avoid unrelated upgrades. For Python, update both runner and licensing declarations when the same tool is shared, then:

```sh
devenv shell -- uv lock --project runner
devenv shell -- uv lock --project licensing
devenv shell -- uv lock --project examples/consumers
devenv shell -- uv lock --project examples/policy
# Example locks also embed SDK metadata, including its development groups.
```

For npm, run `npm install --package-lock-only --ignore-scripts --no-audit --no-fund` inside the affected package directory using devenv. For Mix, use `mix deps.update PACKAGE` inside controller, inspect transitive changes and synchronize fetched dependencies with the lock. Then:

```sh
devenv shell -- mondek licenses
devenv shell -- mondek licenses-check
devenv shell -- mondek check
devenv shell -- mondek test
```

Inspect every changed license/NOTICE and inventory record before committing. New or ambiguous terms require exact-version evidence and explicit policy review. Runtime updates also need updated checksum-pinned source evidence in licensing/runtime-sources.json; follow [licensing](LICENSING.md). Keep meaningful stale-credit and incompatible-pin failures in the update's verification notes, then record the passing regenerated checks. Stop only the isolated native test database after testing; preserve ordinary development data.

Choose additional acceptance/browser coverage from the [coverage map](ACCEPTANCE-COVERAGE.md). A lint-tool patch generally needs native/static/installed-SDK checks; image, runtime, transport or UI dependency updates need their actual packaged behavior too. Merge only the tested completed revision. Publishing a package or image is a separate release decision.
