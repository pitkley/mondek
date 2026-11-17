# Release preparation

Local commands in this guide validate/build/export artifacts or edit installation references; they never create a tag, push, log in to a registry or upload anything. The separate release workflow can qualify and publish a release after the explicit gates below. Public release and registry configuration remain operator actions.

## Artifact and version contract

The published installation default is recorded in deploy/compose.yaml and the installation guides. Keep release notes and upgrade guidance ready for publication before tagging; the pipeline updates only mechanical installation references. The release examples use Python SDK version 0.0.4, controller version 0.0.4, Git tag v0.0.4 and image tag 0.0.4. Python prerelease markers a/b/rc map to controller alpha/beta/rc identifiers; stable versions match directly. The SDK distribution is mondek. The source repository is pitkley/mondek and controller image is ghcr.io/pitkley/mondek/controller.

```sh
devenv shell -- python scripts/release.py check --tag v0.0.4
devenv shell -- python scripts/release.py build-sdk \
  --tag v0.0.4 --output .local/release/0.0.4
```

The output directory must be new. The command builds wheel/sdist, rebuilds a wheel from that sdist, compares all wheel file contents, checks distribution metadata and records SHA256SUMS/sdk-build.json. The rebuilt wheel is verification evidence; the original qualified wheel/sdist are the distribution pair. This does not replace typing, notices, installed-project or controller qualification.

Build and test a controller image locally using the normal Dockerfile. Qualify the exact prepared SDK wheel with that image:

```sh
docker build -f controller/Dockerfile -t mondek-controller:0.0.4 .
devenv shell -- python scripts/image_licenses.py controller \
  mondek-controller:0.0.4 --output .local/release/0.0.4/controller-licenses.json
devenv shell -- python tests/e2e/install.py \
  --image mondek-controller:0.0.4 \
  --sdk-wheel .local/release/0.0.4/mondek-0.0.4-py3-none-any.whl
```

The image audit records the immutable image identity. Before promotion, retain an immutable image archive/digest and qualify every advertised architecture; a local machine's successful build does not qualify another architecture. The sample runner image is a demo/test fixture, not a promised generic runner distribution.

## Workflow and promotion

`.github/workflows/release.yml` runs on a main push, version-tag push or manual dispatch. Main pushes run normal CI once through the reusable workflow, qualify both controller architectures and automatically publish the combined `edge` image to GHCR in pitkley/mondek. Main image exports use the same SDK and identity checks as release exports. Main publication does not publish the SDK or create a GitHub Release. Tag pushes and the default manual dispatch only qualify artifacts; they do not publish registries or create a GitHub Release. Qualification does upload private GitHub Actions artifacts/evidence, so do not start even a qualification run while uploads are prohibited.

The workflow prepares the SDK wheel/sdist once in a small Python/uv job, including rebuilding the sdist and comparing wheel contents, then uploads the original distribution pair with its checksums. Normal CI and both architecture qualification jobs depend on this preparation and run concurrently. The native CI job downloads and verifies that exact pair before checking its installed wheel, including typing, generated-project tests, local execution, notices and package contents. Release qualification bypasses the normal native dependency cache restore. Ordinary source CI remains nonpublishing and keeps its existing caches.

Alongside CI, native ubuntu-24.04 and ubuntu-24.04-arm jobs each build one controller image. Each tests the exact image with the original SDK wheel: empty UI/startup, real scheduled measurement, SMTP firing/recovery, controller recreation and retained identity/history/settings. It audits that image and exports it with docker save. Export metadata binds the platform, immutable image ID, archive checksum and SDK checksums. Both normal CI and both architecture jobs must succeed before any publication; completed image qualification alone cannot authorize promotion. Publishing jobs load these exports and require the same identities; they never rebuild application artifacts. This targets Linux/amd64 and Linux/arm64. Local emulation is not a substitute for the first successful native hosted qualification. Running qualification concurrently may spend build time on a revision that subsequently fails CI.

Versioned release publication requires all of the following:

- A manually dispatched release run with publish=true on the intended v-prefixed version tag.
- The final repository identity pitkley/mondek and repository variable MONDEK_ENABLE_PUBLICATION=true. Keep that variable absent/false until the release is explicitly authorized.
- Successful normal CI and both architecture jobs.
- Approval of the testpypi environment, configured as the first publication gate. That approval authorizes the complete following chain, including production PyPI, GHCR and the GitHub Release. Add a second review to pypi if desired.

The sequence is original SDK pair to TestPyPI, loaded controller images to GHCR, the same SDK pair to PyPI, then GitHub Release assets/notes. Publishing permissions are limited to the jobs that need them. PyPI uses OIDC with attestations and no stored API token; GHCR uses GITHUB_TOKEN. Existing PyPI versions and existing GitHub Releases cause failure rather than silently skipping/replacing them. Registries cannot be updated atomically: if a later step fails, inspect what succeeded before deciding how to resume. Retry failed publishing jobs within the same run to retain the same artifacts; do not rebuild under an already published version.

GHCR receives the versioned platform tags 0.0.4-amd64 and 0.0.4-arm64 and their combined 0.0.4 index. The same index is also published as `latest`, including alpha and other prerelease versions while Mondek is experimental; this policy may become stable-only in the future. `latest` tracks the most recently published version-tag pipeline, without semantic-version sorting. Main builds publish platform tags `sha-<commit>-amd64` and `sha-<commit>-arm64`, their combined `sha-<commit>` index and the mutable `edge` alias. Both mutable tags contain Linux/amd64 and Linux/arm64; use a version, commit or digest reference when pinning an installation. Each image carries source, license, version and final commit labels. The GitHub Release includes the original distributions, SDK checksums, per-platform image identities and scoped license inventories. Image tar files stay in short-lived private Actions artifacts, not GitHub Release assets. Versions with alpha, beta or rc suffixes are marked as GitHub prereleases. Version 0.0.4 has no prerelease suffix; Mondek still remains experimental.

## Account setup before enabling publication

Do these only after agreeing to the final repository/registry setup. The local code does not create accounts, repositories, environments, packages or trusted publishers.

1. Use the release repository pitkley/mondek and make the version tag refer to the approved source. Use a new version for each release; do not reuse a rehearsal version for production.
2. Configure GitHub environments testpypi and pypi. Restrict deployment refs to version tags. Require operator approval on testpypi as the publication gate (and optionally on pypi). Confirm your repository plan supports the chosen protection rules before relying on them. Keep MONDEK_ENABLE_PUBLICATION disabled during qualification/review.
3. In both TestPyPI and PyPI, configure a pending trusted publisher for project mondek, owner pitkley, repository mondek, workflow filename release.yml. Use environment testpypi on TestPyPI and pypi on PyPI. Existing projects use their Publishing settings instead. A pending publisher neither creates the project nor reserves its name; complete any name/ownership resolution before the release.
4. Grant the final repository's Actions access to the GHCR package if it already exists. The workflow requests packages:write only in the GHCR job. Its source label links images to the final repository. Explicitly set package visibility to public when public release is authorized; public repository visibility does not make an existing/private package public automatically.
5. After qualification and the explicit publication decision, enable MONDEK_ENABLE_PUBLICATION, dispatch Release against the intended version tag with publish=true, and review the environment approval with its exact commit/artifact evidence. This run builds once, qualifies and promotes its own artifacts. Merely re-running an earlier qualify-only dispatch does not change its publish input.

PyPI's [pending-publisher guide](https://docs.pypi.org/trusted-publishers/creating-a-project-through-oidc/) and [GitHub publisher setup](https://docs.pypi.org/trusted-publishers/adding-a-publisher/) describe the account fields. See [GitHub's runner reference](https://docs.github.com/en/actions/reference/runners/github-hosted-runners) for platform availability and [GHCR permissions/visibility](https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry) for package access. Do not upload to TestPyPI as an unapproved rehearsal: it is external publication too.

## Post-publication consumption

Verify the GHCR index lists both architectures, set/check public package visibility, then pull anonymously using a clean Docker configuration and the agreed version tag. Verify a clean Python 3.13+ environment can install mondek==0.0.4 from production PyPI without maintainer credentials. Generate a project, run its tests/validate/local execution, and connect it to the image-based controller using deploy/README.md. Compare the downloaded Python files with the recorded SDK checksums and record the published image digest. These checks require actual publication and are not closed by local builds or workflow lint.

The [0.0.4 publication run](https://github.com/pitkley/mondek/actions/runs/44155827718) passed full CI and native AMD64/ARM64 qualification before promotion. Public artifact verification completed on 2026-11-17: anonymous GHCR pull, a fresh Python 3.13 installation from production PyPI and package checksums against the release assets passed. Both controller platform inventories contain Plug 1.20.4, and the pulled ARM64 image matches the immutable identity in the release evidence. The controller index digest is `sha256:23ecce0232a074058d0ffda6f1b9c40e4036707e68dc56fd6cbf349c249fce29`.

A fresh isolated post-publication image/installed-runner check also passed on 2026-11-17, covering generated-project tests, validation, local execution, real measurements, SMTP firing/recovery, controller recreation and retained runner identity/history/settings. On the heavily loaded local host, two attempts timed out on the initial five-second UI request; the successful functional check used a temporary wrapper allowing 60 seconds for localhost HTTP reads instead of five. Product artifacts and runner deadlines were unchanged. This establishes functionality with the adjusted local read allowance, not a local latency pass. Native hosted qualification for both architectures passed the unmodified acceptance harness before publication.

After the GitHub Release is published, the final workflow job checks public PyPI wheel/sdist bytes against the qualified SDK hashes and anonymously checks the GHCR index and both platform image identities against the release evidence. It updates installation pins and release links together in README.md, deploy/compose.yaml, deploy/README.md, docs/GETTING-STARTED.md and docs/DISTRIBUTION.md, then commits directly to the latest main. This normal push triggers CI and edge qualification; it does not publish another versioned release or loop back into installation promotion. The job does not repeat the full consumer suite after publication. The detailed 0.0.4 record above is historical evidence, not a checklist to rewrite for every release.

The release-defaults environment holds RELEASE_DEFAULTS_KEY, a repository-specific write deploy key. Its deployment policy permits only version tags. The main required-status-check ruleset permits deploy-key pushes; this is the repository’s only write deploy key. GitHub applies that exception to deploy keys as a class, so reconsider it before adding other write deploy keys. Force-push, deletion and linear-history rules remain enforced. No personal access token or general Actions bypass is needed. To rotate it, replace the deploy key and environment secret.

If public verification or reference matching fails, the release remains published and installation defaults remain unchanged. Fix the cause and rerun the failed job in the same release run; matching defaults produce no commit. If main moved during the job, the ordinary push fails safely; rerun to start from its latest contents. The helper also refuses promotion if main has already advanced to a different source version. Never force-push or republish artifacts to repair this step.

## Local image export rehearsal

After qualifying an image with the selected SDK pair, preserve and reload it without registry access:

```sh
devenv shell -- python scripts/release.py save-image \
  --image mondek-controller:0.0.4 --architecture arm64 \
  --sdk-directory .local/release/0.0.4 --output .local/release/controller-arm64
devenv shell -- python scripts/release.py load-image \
  --directory .local/release/controller-arm64 --architecture arm64 \
  --sdk-directory .local/release/0.0.4 --tag v0.0.4
```

Use the actual qualified architecture. Export requires a new output directory; loading verifies SDK/archive checksums and the restored image ID/platform. Export helpers establish artifact integrity, not that a skipped qualification test passed.
