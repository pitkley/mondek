# Protocol contracts

[The v1 specification](v1/protocol.md) describes the current runner/server protocol and operator endpoints: payloads, identities, timestamps, admission, retries and bounds. Its specification and four JSON fixture files live together in v1/. The JSON files are shared test vectors, not JSON Schema documents. They generate no application code, serializers or validators, and production processes do not load them. Validation is implemented independently in Elixir and Python; tests load the same examples to check agreement on specific cases.

## Versioning

Mondek is experimental, and its protocol may change. For now, use the server and runner SDK from the same source revision. The `v1` name identifies the current protocol format; it does not indicate a stable release. Changes that require an upgrade procedure will document that procedure.

## Executable evidence

Paths below identify the actual fixture consumers; linked test modules contain additional cases beyond these files.

| Shared file | Python consumer | Elixir consumer | What it checks |
| --- | --- | --- | --- |
| [observation.json](v1/observation.json) | [test_runner.py](../runner/tests/test_runner.py), state replay and lost-HTTP-reply tests | [Fixtures.report](../controller/test/support/data_case.ex), used by [monitoring_test.exs](../controller/test/mondek/monitoring_test.exs) and other domain/API tests | A concrete report retains its identity, sequence and source timestamp in the spool and HTTP retry; server ingestion admits it once, recognizes an identical duplicate and rejects a changed payload under the same ID. The Python lost-reply test uses a local test HTTP service; real PostgreSQL/HTTP replay coverage is separate. |
| [result-text.json](v1/result-text.json) | [test_text_contract.py](../runner/tests/test_text_contract.py), `TextContractTests.test_shared_summary_corpus` | [text_contract_test.exs](../controller/test/mondek/text_contract_test.exs) | Valid/invalid summaries, including UTF-8 byte bounds and malformed text, agree across public result constructors/builders and server report admission. This corpus does not cover every diagnostic/details field. |
| [discovery.json](v1/discovery.json) | [test_discovery.py](../runner/tests/test_discovery.py), `DiscoveryTests.test_shared_contract` | [discovery_test.exs](../controller/test/mondek/discovery_test.exs) | Discovery payload acceptance/rejection agrees between Python validation and both server discovery validation and report admission. |
| [check-groups.json](v1/check-groups.json) | [test_check_groups.py](../runner/tests/test_check_groups.py), `CheckGroupTests.test_wire_contract_and_hostile_metadata` | [inventory_test.exs](../controller/test/mondek/inventory_test.exs) | Optional output-group metadata is accepted/rejected by Python snapshot validation and server inventory validation. The Python test also checks malformed groups against the authoring validator. |

Both language suites run in `devenv shell -- mondek test` and CI's **Unit tests and checks** job. See [development commands](../DEVELOPMENT.md) and the [coverage map](../docs/ACCEPTANCE-COVERAGE.md) for isolated database and service-suite requirements. Changing prose alone does not enforce behavior; a protocol change needs implementation and tests as well as updated examples/specification.

## Runtime enforcement and limits

On the server, [Protocol](../controller/lib/mondek/protocol.ex) validates control/envelope/report shapes, versions, text/timestamp bounds and result membership. [Inventory](../controller/lib/mondek/inventory.ex) validates complete source declarations and parameter/output metadata; [Discovery](../controller/lib/mondek/discovery.ex) validates discovery evidence. [Monitoring](../controller/lib/mondek/monitoring.ex) applies session/generation authority, duplicate/conflicting evidence handling and transactional persistence. These runtime paths do not consult the JSON fixtures.

On the runner, [transport](../runner/mondek_runner/transport.py) bounds HTTP exchanges and checks successful responses' protocol version. [runtime](../runner/mondek_runner/runtime.py) validates assignment/authorization data before reconciling accepted scheduling; [bundle](../runner/mondek_runner/bundle.py) validates source/output metadata and frozen snapshots. Authoring and worker validation constrain results before reporting. These are endpoint-specific checks, not a generated, symmetric validator for every field of every request and response.

The shared vectors cover selected examples and hostile boundary cases; they are not an exhaustive conformance suite or proof that the whole prose specification is enforced. There are no complete shared control, inventory or operator-endpoint request/response corpora. Separate native/API tests cover more validation and concurrency, while real service acceptance covers HTTP, PostgreSQL, lost replies, outages and restart. Consult the [coverage map](../docs/ACCEPTANCE-COVERAGE.md) for which scenarios run in ordinary CI versus selected/manual qualification; a passing fixture test alone does not establish mixed-version interoperability or a successful upgrade.

Fixed timestamps in examples and tests are synthetic data. Calendar-sensitive fixtures cover weekdays, recurrence and daylight-saving transitions.
