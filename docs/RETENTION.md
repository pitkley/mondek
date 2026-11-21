# History retention and catch-up

The controller keeps ordinary receipts for seven days and trims unprotected receipts beyond the newest 100,000. Terminal incident, maintenance and abandoned configuration history becomes eligible after thirty days. These are eligibility boundaries, not strict storage caps: current/confirmed measurements, unresolved incidents, unfinished or exhausted delivery, retained evidence references and configuration authority remain protected. Policy apply receipts have a separate lifetime and are not changed here.

Consumer state has [separate quotas and TTL/lifecycle cleanup](CONSUMER-STATE.md). It is not observation history and is not exported into configuration Git. Assignment-local values become inaccessible at retirement; source-wide values survive publication retirement.

## Configure the policy

Set MONDEK_RETENTION_RECEIPT_DAYS (default 7), MONDEK_RETENTION_HISTORY_DAYS (default 30), and MONDEK_RETENTION_MAX_OBSERVATIONS (default 100000) in the controller environment. Environment settings are read at startup; restart the controller to apply changes. Days accept integers from 1 to 36500; the count accepts 1 to 1000000000. Empty, zero, negative, malformed or out-of-range values stop startup with the setting name. There is no unbounded mode.

The Overview API returns the effective policy in its retention summary. Increasing a limit cannot recover already-pruned history. Reducing it makes eligible unprotected records available to the next bounded cleanup pass. A count limit can shorten history below the configured age; references remain protected regardless. Incident opening, latest-failure and closing references protect their observations while the incident is retained; keeping an older failure is independent of the current result or a later recovery. Back up before a deliberate policy reduction.

## Size a fourteen-day lookback

At 32,600–57,600 receipts per day, fourteen days of ordinary history contain about 456,400–806,400 receipts. Use receipts from all runners and all executions in the installation, including executions that report unchanged or unhealthy results. An execution report can contain multiple results in one receipt. Multiply your expected peak daily receipt volume by the desired days and round up for bursts, added checks and runner growth. At 57,600 per day, a count of 1,000,000 leaves room for 193,600 additional receipts, about 24% above the fourteen-day estimate.

For this workload, add these settings to the packaged controller's private environment file:

```dotenv
MONDEK_RETENTION_RECEIPT_DAYS=14
MONDEK_RETENTION_MAX_OBSERVATIONS=1000000
```

The packaged Compose recipe injects these settings from the controller service's `env_file`, selected by `MONDEK_ENV_FILE` and defaulting to `.env`. With the default recipe, `.env` also supplies Compose interpolation values. If you use a separate controller file, put the retention values in that file. Shell exports and Compose's `--env-file` can supply interpolation values such as `MONDEK_ENV_FILE`. Compose does not forward retention values from interpolation alone.

From the installation directory, recreate the controller using the same Compose options you used to start it:

```sh
docker compose up -d --wait --no-deps --force-recreate controller
```

Request `GET /api/v1/overview` through your usual controller access path. The `data.retention` string should report that ordinary measurements expire after 14 days or beyond the newest 1000000 receipts.

An ordinary receipt becomes eligible for trimming when it is older than the age limit or falls outside the newest configured count. The first limit reached determines the lookback for unprotected receipts. Protected receipts can survive both limits, including receipts referred to by current measurements, incidents or retained delivery work. The database can therefore hold more than 1,000,000 receipts even when cleanup has caught up.

## Bounded passes

Each `Sweeper.sweep/1` transaction selects at most 1,000 eligible roots per history category. Age and count trimming share a single 1,000-observation budget. Protection predicates run before the limit, so an old protected row cannot indefinitely hide eligible rows behind it. Count trimming determines the globally newest configured count of receipts before excluding protected evidence, with receipt time and ID providing deterministic ordering.

Terminal parent IDs are selected once and reused for child and parent deletion within the transaction. Shared incidents and their mutually referenced facts/evidence expire atomically. The existing maintenance, assignment, condition and monitoring-loss lock order remains intact; the [transaction contract](TRANSACTIONS-AND-LOCKS.md) describes ownership.

A receipt-time/ID index supports bounded oldest/newest selection without sorting a large equal-time backlog. It replaces the receipt-time-only index, retaining the same leading field for age queries. The ordinary transactional migration builds the replacement before dropping the old index; deployment startup runs migrations before serving the application. This is not an online index migration: building the index can temporarily block writes.

A full category batch requests another pass after the next one-second tick. Each pass commits and yields before the next one, allowing ingestion and ordinary monitoring reconciliation between passes. When no category fills its batch, the ordinary sixty-tick cadence resumes. An exactly full final batch may cause one extra empty pass. A restart starts catch-up from the remaining durable rows; there is no in-memory or persistent cleanup cursor to repair. An interrupted transaction rolls back its complete pass.

The limit bounds selected roots, **not cascaded child rows, scanned rows, database size or elapsed time**. A single historical incident or maintenance series can own many children. Protected history can grow indefinitely. The implementation does not remove serialization, force expiry of unresolved work or promise a fixed ingestion latency.

## Reproducing the measurement

Use the isolated native test database, never an operator installation:

```sh
devenv shell -- sh -c 'PGPORT=55433 docker compose -p mondek-tests up --detach --wait postgres'
devenv shell -- sh -c 'cd controller && MONDEK_RETENTION_PROFILE_ROWS=100000 PGPORT=55433 MIX_ENV=test mix test profiles/retention.exs --trace'
devenv shell -- docker compose -p mondek-tests stop postgres
```

The opt-in profile guards the database name, host, port and Mix environment before its destructive test setup. Choose 10,000 or 100,000 synthetic aged historical receipts, plus one terminal incident per hundred receipts. It refreshes fixture-table statistics, admits real reports through the controller before and during each cleanup pass, samples database lock waits, drains subsequent passes and checks protected evidence. The synthetic terminal parents do not model large notification-child fan-out. This is a database/ingestion experiment, not an end-to-end test or a production capacity guarantee. See [the acceptance guide](../tests/e2e/README.md) for real-service coverage; record timing results together with the exact workload and host.

In the controlled 100,000-receipt comparison, the worst measured ingestion wait fell from 7.54 seconds to 166 milliseconds. Cleanup required 101 committed passes and about 28% more summed work. Stale statistics produced a different, slower plan in a separate run; index availability and root limits alone do not guarantee these timings.

Revisit batch sizing or query/index changes when real storage growth, cleanup duration or ingestion latency supplies evidence. If large protected histories or highly connected episodes dominate, profile those shapes directly rather than claiming that a row limit solves them.
