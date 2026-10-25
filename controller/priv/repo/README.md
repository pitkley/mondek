# Database migrations

`migrations/00000000000001_current_baseline.exs` creates a fresh installation. It applies the pinned Oban migration and the explicit statements in `baseline.sql`, preserving database constraints and evidence triggers. Function bodies can contain semicolons; `-- mondek:statement` separates whole SQL statements.

Add future changes as new Ecto migrations. Do not edit this baseline to upgrade an existing installation. It rejects historical pre-publication migration ledgers; those installations need a separately reviewed private transition. See [installation state and upgrades](../../../docs/UPGRADING.md).
