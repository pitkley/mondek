# Contributing

Mondek is experimental. Start with [the development commands](DEVELOPMENT.md), [the acceptance coverage map](docs/ACCEPTANCE-COVERAGE.md) and the relevant current contract in docs or contracts. The [documentation index](docs/README.md) maps guides by task. Keep a change focused and explain the behavior it changes and the verification performed.

Use the committed devenv environment for language tools and Docker Compose for services. Entering the shell must remain cheap. Keep real credentials, consumer-specific monitoring code, runtime state and generated test evidence outside commits. Use isolated Compose projects for acceptance work and preserve ordinary development volumes.

## Verification

Run `devenv shell -- mondek check` for formatting, typing, installed SDK, workflow security and license/source checks. Run `devenv shell -- mondek test` for the native PostgreSQL, runner, example and harness tests. Select additional real service/browser suites from the coverage map when changing the behavior they exercise; record which commands passed and any remaining limitations in the pull request.

Pull requests and main pushes run the smaller packaged smoke set as well as native checks. Manual runs also default to smoke. The explicit full mode exercises further timing, outages, restart, policy and browser journeys, and costs substantially more time. Reserve a full run for changes needing its coverage or a deliberate qualification baseline. Avoid simultaneous runs of the same revision and mode. Superseded runs on the same ref cancel automatically.

## Dependency updates

Update declarations and their matching locks together. Python projects use committed uv.lock files; the controller uses mix.lock and its JavaScript assets use package-lock.json. Keep language/compiler pins compatible across devenv, Dockerfiles and the SDK runtime checks. A Nix input update can change several toolchains at once and deserves a separate review.

After synchronizing the locked environments, run `devenv shell -- mondek licenses`, review every changed license/NOTICE and commit all generated credits. Then run `mondek licenses-check`, `mondek check`, native tests and the relevant packaged acceptance. CI rejects missing or unapproved evidence and stale generated files. Resolve a new license explicitly in the reviewed policy rather than hiding a dependency or broadening the allowlist without evidence. See [licensing](docs/LICENSING.md) for artifact coverage and corresponding-source obligations.

Dependency automation should propose reviewed pull requests, without automatic merges or publishing credentials. Lock/credit regeneration remains part of each update; passing a version bot's checks alone does not establish compatibility or notice completeness. Enabling a bot and repository rules is a separate repository setup step.

See [dependency maintenance](docs/DEPENDENCY-MAINTENANCE.md) for the coordinated pin matrix, lock/notice regeneration commands and deliberate Renovate activation. CI rejects partial runtime/tool updates as well as stale credits.

## Compatibility and releases

Keep evidence identity and original timestamps intact across replay. Treat stored protocol, configuration, snapshot and notification identities as compatibility contracts. Changes to those contracts need explicit migration/upgrade reasoning and relevant real restart coverage; [the existing upgrade guide](docs/UPGRADING.md) illustrates the migration and state-preservation requirements.

The [contract guide](contracts/README.md) explains versioning, runtime validation and which fixtures each language tests.

Source publication, package releases and container distribution are separate steps. A passing image notice audit does not establish that its exact corresponding-source delivery is ready. Do not add automatic registry publication to validation jobs. Release versions, supported artifacts and recipient access must be settled and verified before publishing them.
