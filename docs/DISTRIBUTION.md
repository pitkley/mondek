# Installation and distribution

The normal installation uses the controller/PostgreSQL [image recipe](../deploy/README.md) and an installed SDK as described in [getting started](GETTING-STARTED.md). The [0.0.1a2 release](https://github.com/pitkley/mondek/releases/tag/v0.0.1a2) includes the controller image `ghcr.io/pitkley/mondek/controller:0.0.1a2` for Linux/amd64 and Linux/arm64, plus the wheel and sdist for [mondek on PyPI](https://pypi.org/project/mondek/0.0.1a2/). No source checkout is required for ordinary installation.

Use matching published controller/SDK releases, or the same reviewed source revision for local builds. The versioned wire contracts do not promise arbitrary controller/SDK combinations, and the runner deliberately fences frozen executable snapshots against their installed runtime. Preserve installation state when changing artifacts; see [upgrading](UPGRADING.md). The [controller trust boundary](CONTROLLER-AUTH.md) still applies to a parallel pilot.

## Contributor alternative: a consumer with a portable local SDK wheel

The generator defaults to a registry dependency matching its installed SDK version. Contributors can deliberately use --sdk-path for editable SDK development. To distribute unpublished code without that editable path, build a wheel locally and retain it inside the consumer project. This requires no public upload.

From the chosen Mondek checkout, with the parent of /absolute/my-monitoring already present:

```sh
devenv shell -- uv build --project runner --out-dir .local/sdk
devenv shell -- uv run --project runner --locked mondek-runner init \
  /absolute/my-monitoring --sdk-path ./runner
mkdir -p /absolute/my-monitoring/vendor
cp .local/sdk/mondek-0.0.1a3-py3-none-any.whl /absolute/my-monitoring/vendor/
```

Replace the generated consumer's entire `[tool.uv.sources.mondek]` block with the following. Remove its `editable = true` line:

```toml
[tool.uv.sources.mondek]
path = "vendor/mondek-0.0.1a3-py3-none-any.whl"
```

Resolve and install explicitly using the selected Mondek toolchain:

```sh
devenv shell -- uv lock --project /absolute/my-monitoring
devenv shell -- uv sync --project /absolute/my-monitoring \
  --locked --no-dev --no-editable
```

Keep the wheel, pyproject.toml, uv.lock, consumer source and tests together in the consumer repository. Record the Mondek source revision and wheel SHA-256 in its deployment notes; the lock also records the local wheel hash. Preserve the wheel's embedded license and third-party notices. Review the generated README and update its contributor-override note to describe the vendored wheel before sharing the consumer. Do not include .venv, private datasource configuration or runner state in that repository.

The project can now move to another directory without changing its SDK source. Create a fresh environment there using `uv sync --locked --no-dev --no-editable`, with the selected Python/uv toolchain available. This path is verified with Python 3.13.15 and uv 0.12.5 on macOS; the package’s broader Python minimum is not qualification of every later Python version or operating system. A pinned build tool may still need its ordinary package cache/network access; retaining the wheel does not claim a completely offline build.

From the consumer directory, use the installed executables directly:

```sh
.venv/bin/python -m unittest discover -s tests
.venv/bin/mondek-runner validate --consumer monitoring.app:app
.venv/bin/mondek-runner run --consumer monitoring.app:app --all --results
```

For a disposable local controller, run `devenv shell -- mondek start` from the Mondek checkout. Then, from the consumer directory:

```sh
MONDEK_CONTROLLER_URL=http://127.0.0.1:4001 \
  .venv/bin/mondek-runner --consumer monitoring.app:app \
  --state-dir .mondek-state
```

Choose stable source/target identities before translating real checks. Keep a separate durable state directory for each runner installation, outside deployment replacement directories when deploying updates. Stop the runner before replacing its environment; build and validate the replacement separately. A non-editable installation does not adopt edits to consumer Python automatically: rebuild/reinstall deliberately, retain a complete rollback deployment and verify fresh adopted measurements. Runtime input files remain ordinary external inputs. See [runner deployment](RUNNER-DEPLOYMENT.md) for node/datasource examples and state handling.

## Release artifacts and qualification

Published artifacts are the SDK wheel/sdist and controller image. The [release guide](RELEASING.md) defines namespaces, version/tag conventions, qualification and publication. A generic consumer runner base image is not currently published; the sample runner image remains a demo, not a generic consumer base.

For each new registry release, build artifacts once from the verified revision and test those exact artifacts, including a wheel rebuilt from the sdist, SDK typing/templates/notices and every advertised image architecture. Validate tag/package/controller versions together, retain checksums and component inventories, and give publication credentials only to the publishing job. The release workflow uses trusted publishing for Python; a validation run must not publish as a side effect.

Controller and sample-runner image audits verify exact component inventories, native ownership and retained notices. Distribution-provided OS packages are assessed separately from Mondek application dependencies, without a blanket source-archive publishing requirement. See [licensing](LICENSING.md#distribution-provided-os-components) for the audit scope.
