# Release preparation

Local commands in this guide only validate/build/export artifacts; they never create a tag, push, log in to a registry or upload anything. The separate release workflow can qualify and publish a release after the explicit gates below. Public release and registry configuration remain operator actions.

## Artifact and version contract

The first candidate uses Python SDK version 0.0.1a2, controller version 0.0.1-alpha.2, Git tag v0.0.1a2 and image tag 0.0.1a2. Python prerelease markers a/b/rc map to controller alpha/beta/rc identifiers; stable versions match directly. The SDK distribution is mondek. The planned final source repository is pitkley/mondek and controller image is ghcr.io/pitkley/mondek/controller. Names describe the intended release; they do not imply that repositories, namespaces or public artifacts already exist.

```sh
devenv shell -- python scripts/release.py check --tag v0.0.1a2
devenv shell -- python scripts/release.py build-sdk \
  --tag v0.0.1a2 --output .local/release/0.0.1a2
```

The output directory must be new. The command builds wheel/sdist, rebuilds a wheel from that sdist, compares all wheel file contents, checks distribution metadata and records SHA256SUMS/sdk-build.json. The rebuilt wheel is verification evidence; the original qualified wheel/sdist are the distribution pair. This does not replace typing, notices, installed-project or controller qualification.

Build and test a controller image locally using the normal Dockerfile. Qualify the exact prepared SDK wheel with that image:

```sh
docker build -f controller/Dockerfile -t mondek-controller:0.0.1a2 .
devenv shell -- python scripts/image_licenses.py controller \
  mondek-controller:0.0.1a2 --output .local/release/0.0.1a2/controller-licenses.json
devenv shell -- python tests/e2e/install.py \
  --image mondek-controller:0.0.1a2 \
  --sdk-wheel .local/release/0.0.1a2/mondek-0.0.1a2-py3-none-any.whl
```

The image audit records the immutable image identity. Before promotion, retain an immutable image archive/digest and qualify every advertised architecture; a local machine's successful build does not qualify another architecture. The sample runner image is a demo/test fixture, not a promised generic runner distribution.

## Workflow and promotion

`.github/workflows/release.yml` runs on a version-tag push or manual dispatch. Tag pushes and the default manual dispatch only qualify artifacts; they do not publish registries or create a GitHub Release. Qualification does upload private GitHub Actions artifacts/evidence, so do not start even a qualification run while uploads are prohibited.

The workflow calls normal CI once. Its native job builds the SDK wheel/sdist before checking the exact installed wheel, including typing, generated-project tests, local execution, notices and package contents. The sdist rebuild check compares wheel contents. Release preparation bypasses the normal native dependency cache restore. Ordinary source CI remains nonpublishing and keeps its existing caches.

After CI, native ubuntu-24.04 and ubuntu-24.04-arm jobs each build one controller image. Each tests the exact image with the original SDK wheel: empty UI/startup, real scheduled measurement, SMTP firing/recovery, controller recreation and retained identity/history/settings. It audits that image and exports it with docker save. Export metadata binds the platform, immutable image ID, archive checksum and SDK checksums. Publishing jobs load these exports and require the same identities; they never rebuild application artifacts. This targets Linux/amd64 and Linux/arm64. Local emulation is not a substitute for the first successful native hosted qualification.

Publishing requires all of the following:

- A manually dispatched release run with publish=true on the intended v-prefixed version tag.
- The final repository identity pitkley/mondek and repository variable MONDEK_ENABLE_PUBLICATION=true. Keep that variable absent/false until the release is explicitly authorized.
- Successful normal CI and both architecture jobs.
- Approval of the testpypi environment, configured as the first publication gate. That approval authorizes the complete following chain, including production PyPI, GHCR and the GitHub Release. Add a second review to pypi if desired.

The sequence is original SDK pair to TestPyPI, loaded controller images to GHCR, the same SDK pair to PyPI, then GitHub Release assets/notes. Publishing permissions are limited to the jobs that need them. PyPI uses OIDC with attestations and no stored API token; GHCR uses GITHUB_TOKEN. Existing PyPI versions and existing GitHub Releases cause failure rather than silently skipping/replacing them. Registries cannot be updated atomically: if a later step fails, inspect what succeeded before deciding how to resume. Retry failed publishing jobs within the same run to retain the same artifacts; do not rebuild under an already published version.

GHCR receives the versioned platform tags 0.0.1a2-amd64 and 0.0.1a2-arm64 and their combined 0.0.1a2 index. No latest tag is created. Each image carries source, license, version and final commit labels. The GitHub Release includes the original distributions, SDK checksums, per-platform image identities and scoped license inventories. Image tar files stay in short-lived private Actions artifacts, not GitHub Release assets. An alpha is marked prerelease.

## Account setup before enabling publication

Do these only after agreeing to the final repository/registry setup. The local code does not create accounts, repositories, environments, packages or trusted publishers.

1. Use the release repository pitkley/mondek and make the version tag refer to the approved source. Use a new version for each release; do not reuse a rehearsal version for production.
2. Configure GitHub environments testpypi and pypi. Restrict deployment refs to version tags. Require operator approval on testpypi as the publication gate (and optionally on pypi). Confirm your repository plan supports the chosen protection rules before relying on them. Keep MONDEK_ENABLE_PUBLICATION disabled during qualification/review.
3. In both TestPyPI and PyPI, configure a pending trusted publisher for project mondek, owner pitkley, repository mondek, workflow filename release.yml. Use environment testpypi on TestPyPI and pypi on PyPI. Existing projects use their Publishing settings instead. A pending publisher neither creates the project nor reserves its name; complete any name/ownership resolution before the release.
4. Grant the final repository's Actions access to the GHCR package if it already exists. The workflow requests packages:write only in the GHCR job. Its source label links images to the final repository. Explicitly set package visibility to public when public release is authorized; public repository visibility does not make an existing/private package public automatically.
5. After qualification and the explicit publication decision, enable MONDEK_ENABLE_PUBLICATION, dispatch Release against the intended version tag with publish=true, and review the environment approval with its exact commit/artifact evidence. This run builds once, qualifies and promotes its own artifacts. Merely re-running an earlier qualify-only dispatch does not change its publish input.

PyPI's [pending-publisher guide](https://docs.pypi.org/trusted-publishers/creating-a-project-through-oidc/) and [GitHub publisher setup](https://docs.pypi.org/trusted-publishers/adding-a-publisher/) describe the account fields. See [GitHub's runner reference](https://docs.github.com/en/actions/reference/runners/github-hosted-runners) for platform availability and [GHCR permissions/visibility](https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry) for package access. Do not upload to TestPyPI as an unapproved rehearsal: it is external publication too.

## Post-publication consumption

Verify the GHCR index lists both architectures, set/check public package visibility, then pull anonymously using a clean Docker configuration and the agreed version tag. Verify a clean Python 3.13+ environment can install mondek==0.0.1a2 from production PyPI without maintainer credentials. Generate a project, run its tests/validate/local execution, and connect it to the image-based controller using deploy/README.md. Compare the downloaded Python files with the recorded SDK checksums and record the published image digest. These checks require actual publication and are not closed by local builds or workflow lint.

## Local image export rehearsal

After qualifying an image with the selected SDK pair, preserve and reload it without registry access:

```sh
devenv shell -- python scripts/release.py save-image \
  --image mondek-controller:0.0.1a2 --architecture arm64 \
  --sdk-directory .local/release/0.0.1a2 --output .local/release/controller-arm64
devenv shell -- python scripts/release.py load-image \
  --directory .local/release/controller-arm64 --architecture arm64 \
  --sdk-directory .local/release/0.0.1a2 --tag v0.0.1a2
```

Use the actual qualified architecture. Export requires a new output directory; loading verifies SDK/archive checksums and the restored image ID/platform. Export helpers establish artifact integrity, not that a skipped qualification test passed.
