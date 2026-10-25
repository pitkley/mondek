# License collection and credits

Mondek is licensed under Apache-2.0. Third-party components retain their own licenses and notices.

## Find credits

Use **Licenses and credits** in the web UI footer, or open `/licenses`. The page lists the Mondek license and embedded controller runtime package notices; `/licenses/notices` downloads the corresponding plain text. It works in the packaged application without fetched dependency sources or an online license service. It does not inventory the host, runner operating system or separately installed consumer packages.

Start maintenance with the [licensing directory map](../licensing/README.md). The policy is reviewed configuration; inventory and credits are generated outputs.

## Coverage and limits

| Input or artifact | Enforced evidence | Boundary or remaining gap |
| --- | --- | --- |
| Locked Mix packages and Phoenix/LiveView browser imports | `scripts/licenses.py`: exact versions, package notices, approved expressions and version-scoped supplements | Distinguishes controller runtime from build/test; upstream declarations still require review |
| npm packages, including optional platforms | Collector: every lock entry and checksum-verified notice evidence | Production asset dependencies are included in controller credits; build/test tooling stays separate |
| Python build/test tools and consumer locks | Collector plus `mondek licenses-check`: four locked projects and exact build requirements | SDK has no external runtime packages; downstream consumer additions need their own inventory |
| Known source adaptations | `licensing/source-notices.json` and the package collector retain upstream attribution in generated runtime credits | Normal code review maintains the declared attributions; source edits and new file types are not fingerprint-gated |
| Erlang, Elixir and CPython | `scripts/runtime_licenses.py --check`: pinned source archives and retained incorporated-code notices | Checked evidence is version-specific |
| Final controller/sample-runner images | `scripts/image_licenses.py`: exact filesystem, native ownership and reviewed OS notices | Architecture/image-specific inventory, ownership and notice checks; see the OS component scope below |
| SDK wheel/sdist | `tests/typing/run.py`: rebuild from sdist, install outside checkout, inspect metadata/notices | Does not cover Python, OS or consumer-installed dependencies |
| Host/devenv and build/test image OS | No complete license inventory of these tool closures | Outside shipped-runtime reports; Nix pins and package locks alone are not a complete attribution audit |

The native CI phase in `scripts/ci.py` calls `mondek check` and `mondek licenses-check`. These run the collector's stale-output check, runtime notice checks, licensing negative tests, installed-SDK checks and lock consistency checks. The packaged phase audits exact built images before acceptance. Policy tests reject missing/unknown declarations, unapproved combined terms, missing or corrupt evidence, stale supplements, stale generated outputs. Passing these checks establishes their stated boundaries, not blanket legal clearance.

## Commands

After fetching locked controller dependencies with mondek setup, run:

```sh
devenv shell -- mondek licenses
devenv shell -- mondek licenses-check
```

The collector downloads checksum-verified npm/Python source evidence into ignored .local/licenses/cache and reads fetched Hex metadata and notice files. It never executes downloaded npm/Python code. Use python3 scripts/licenses.py --check --offline inside devenv to verify against a populated cache without network access. Missing or corrupt cached evidence fails the check.

## Covered components

Every controller Mix lock entry must be present with matching name/version and license metadata. Production dependency closure is distinguished from test/native-build dependencies. Browser code bundled from Phoenix and LiveView is covered by the controller's Hex notices. Every npm lock entry is accounted for, including optional platform variants. Version-specific esbuild platform entries use the same-version parent's notices and preserve their own locked artifact identities.

Retained Python project locks and exact build requirements must be covered by licensing/uv.lock. The runner currently has no external runtime Python package dependencies. Adding any requires reviewing the runtime inventory and artifact notice scope; it cannot silently inherit the build/test classification.

The policy in licensing/policy.json starts from the original Mondek allowlist. SPDX AND requires every term, OR permits an approved alternative, and WITH requires explicit approval of the combined license/exception. Hex license arrays are conservatively treated as combined requirements. Missing or unapproved declarations and absent notice evidence fail. Read all applicable notice files, including additional NOTICE and third-party attribution files.

The shipped Lucide icons are a production asset dependency. Its retained LICENSE includes both ISC and incorporated Feather MIT terms; an exact-version npm supplement approves both and fails after an unreviewed version change. Production npm dependencies enter controller credits, while build-only packages remain in the root inventory.

Some Hex packages omit the full license file. Explicit version-scoped supplements retain their README license/copyright section and include the Apache text. Stale supplements fail after dependency changes, requiring review rather than ignoring a whole package. Review the generated evidence and policy changes together with lock updates.

## Generated and distributed files

The similarly named notices have deliberately different scopes:

| Generated output | Distribution purpose |
| --- | --- |
| Root `licensing/inventory.json` and `THIRD_PARTY_LICENSES.md` | All collected locked application/build/test packages and reviewed source adaptations |
| `controller/priv/licenses.json` and `THIRD_PARTY_LICENSES.md` | Controller runtime packages and reviewed copied-source notices, embedded in the release and UI |
| `runner/THIRD_PARTY_LICENSES.md` | Dependency-free SDK scope statement, shipped in wheel/sdist |
| `controller/priv/LICENSE` and `runner/LICENSE` | Exact copies of the project license for those artifacts |

`scripts/licenses.py` generates all seven outputs in one pass; `--check` compares each byte without rewriting stale files. Do not synchronize copies manually or make their package inventories identical. Controller runtime notices are generated into controller/priv, embedded at compile time, and exposed at /licenses and /licenses/notices. Packaged releases need no dependency source checkout or network access to display them. Notice text is escaped in HTML.

The runner wheel and sdist include LICENSE and THIRD_PARTY_LICENSES.md through package metadata. The installed SDK verification rebuilds a wheel from the sdist and checks license metadata/files outside the checkout. Controller and sample-runner images also carry repository notices under /usr/share/doc/mondek.

## Source notices and runtime licenses

The collector includes known upstream adaptations declared in licensing/source-notices.json. Their source references, license terms and retained notice files enter the same generated runtime credits as package dependencies. Editing an adapted source file does not require approving a new fingerprint. Normal code review preserves upstream attribution; there is no exhaustive file-type classifier or repository-wide source-header gate. Existing source notices remain in place.

mondek licenses-check also verifies the retained language-runtime notices with scripts/runtime_licenses.py --check.

licensing/runtime-sources.json pins Erlang/OTP 29.0.5, Elixir 1.20.3 and CPython 3.13.15 source archives by SHA-256 and records 24 original notice/header files. mondek licenses can fetch and regenerate those files; routine checks use retained evidence without downloading runtime sources. Container images carry applicable runtime evidence under /usr/share/doc/mondek/runtime. Python's [incorporated software terms](https://docs.python.org/3.13/license.html) require looking beyond its top-level license; the retained evidence includes Doc/license.rst, mpdecimal, mimalloc, dtoa and HACL/KreMLin headers. OTP evidence includes asmjit, PCRE, Ryu, zstd and zlib notices.

## Exact image checks

Run devenv shell -- mondek image-licenses to build both images and retain reports under .local/licenses/images/<run-id>. This starts no application or monitoring services. scripts/image_licenses.py creates an unstarted, network-disabled container by immutable image config digest, reads its exported filesystem without extraction, and removes only that container. Reports contain the config digest, any registry manifest digests, architecture, rootfs layer digests, installed Debian binary/source versions, complete package copyright text, referenced common-license texts, release application versions, runtime source provenance and hashes/owners of ELF files. Local build config digests are immutable image identities, not registry manifest digests; reports preserve that distinction. The JSON is a project-specific audit inventory, not an SPDX/CycloneDX document or a vulnerability scan.

Images extend their pinned Debian or official Python base normally, preserving ordinary Docker layers and base-image configuration. The auditor checks the final installed filesystem exported from an unstarted container. It records layer digests for identity; it does not require flattening or inspect payloads hidden by later deletions in individual layers. It rejects unknown native ownership, mismatched release/runtime identities and missing application/runtime notices. Debian copyright and referenced common-license texts must be present and nonempty, but wording changes do not require manual hash approval. [Debian copyright metadata](https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/) remains separate from the application-library SPDX allowlist.

The sample runner copies only its Python package, removes pip and ensurepip, and keeps CPython's original notices. Both final filesystems preserve Debian copyright/common-license files. gzip's Debian notice incorrectly names its GFDL-1.3 reference GFDL-3; the images retain the original notice and provide that alias to the unchanged GFDL-1.3 text. The audit retains the license text and its reference. This follows [Debian's distribution-notice layout](https://www.debian.org/doc/debian-policy/ch-docs.html#copyright-information).

CI builds and audits the images independently, retaining per-image evidence. Changed OS notice text is recorded without an exact-byte approval policy. Audits are specific to the architecture and image actually built; an ARM64 result does not establish AMD64 coverage. Build/test images, host devenv tools and downstream consumer images are outside the runtime-image report. Build dependencies remain in the separate package inventory.

## Distribution-provided OS components

Debian packages installed through the base image or apt are tracked separately from libraries incorporated into Mondek. Image checks retain their exact binary/source package identities, copyright notices and referenced license texts. They reject missing or empty notices and unclassified native files, while recording updated distribution notice text without an approval fingerprint. The application dependency allowlist continues to apply to Mondek's own dependencies.

Mondek does not impose a blanket requirement to download and republish source archives for every distribution-provided OS package. The report states its audit scope rather than declaring universal redistribution approval or failure. Individual components retain their own license terms; the installation method does not change those terms. Modified OS packages or newly copied native components require their own review. Host tools, build/test operating systems and downstream consumer additions remain outside these runtime reports.
