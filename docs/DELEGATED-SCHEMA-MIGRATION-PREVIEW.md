# Preview delegated parameter schema changes

Use `POST /api/v1/configuration/schema-migration/preview` to review a proposed complete inventory against the controller's accepted configuration before publishing it. This endpoint reads a consistent snapshot and leaves publications, assignments, rules, exceptions and configuration history untouched.

Send the exact `InventoryRequest` JSON prepared for publication, including the source ID, installation ID, revision and all checks. The installation must already have an accepted publication for that source. Omitting a check from the proposed complete inventory previews its withdrawal. Use the normal controller access boundary for configuration routes.

```sh
curl --fail-with-body --header 'Content-Type: application/json' \
  --data-binary @candidate-inventory.json \
  'http://localhost:4001/api/v1/configuration/schema-migration/preview?page=1'
```

Check rows report additions, withdrawals, and changes to ownership, contracts, schemas, defaults or rule scope for delegated checks. Field differences identify changed types, units and other attributes. The report validates the previously accepted source defaults under the candidate schema so you can see what changed. It also validates each saved instance exception after initializing new fields from candidate defaults, using the same value precedence as inventory reconciliation. `blockers` lists source changes that cannot preserve the identity and interpretation of existing delegated fields. `rule_resolution` reports the prospective winner or a diagnostic using the saved rules and exceptions.

Rule rows include matching rules before or after the edit, their revisions and whether their captured schema differs. A rule can match all or only some targets of a check. Check the reported missing, removed or invalid fields and failed comparisons against the new schema. The report includes counts of other currently matching assignments and other publisher installations, with up to eight sampled installation IDs. This helps identify shared policy affected by a rule change, including sibling checks on the same publisher. Preview rows expose field names and diagnostics without returning saved parameter values.

`candidate.digest` identifies the normalized request body. `review_digest` also binds the report to the accepted publication and the affected assignment, exception and rule revisions used in the read. Pages contain up to 20 rows and share this digest while the inputs stay the same. Repeat the preview if the digest changes during review. Oversized sets of rule scopes return an error and no partial report.

The publication status distinguishes a new candidate, accepted replay, older revision, same-revision conflict, retired publisher and a publisher awaiting inventory refresh. Publication still uses the normal runner workflow and performs its own admission checks. The preview issues no review token and performs no migration or value conversion.
