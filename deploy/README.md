# Install the Mondek server

Use Docker with Compose. This recipe runs only the controller and PostgreSQL, with persistent database storage and no demo checks or test receiver. It needs no source build, Nix or Python on the controller host. The recipe uses the published 0.0.1a2 image. Set MONDEK_IMAGE to select another version or a locally built controller image.

Copy compose.yaml and .env.example into an installation directory, then:

```sh
cp .env.example .env
chmod 0600 .env
```

Edit .env privately. Set a strong PGPASSWORD and a unique SECRET_KEY_BASE of at least 64 characters (`openssl rand -hex 64` can generate one). Set MONDEK_SMTP_HOST, MONDEK_SMTP_FROM, MONDEK_SMTP_TO and the matching port/transport for your intended relay. Supply paired credentials if required. No relay or recipient is created implicitly. See [SMTP settings](../docs/EMAIL-NOTIFICATIONS.md). Keep this file out of source control and diagnostic output; do not run `docker compose config` without --quiet when sharing logs.

```sh
docker compose up -d --wait
docker compose ps
```

Open http://127.0.0.1:4000. The database has no published port and requires its configured password. Install the SDK in a separate monitoring project and connect its runner to this server; the controller never executes your Python code.

For another machine, protect the controller with an authentication gateway and restrict direct origin access. Set MONDEK_DEPLOYMENT_MODE=true and MONDEK_PUBLIC_URL to the HTTPS origin in .env, and route the gateway to the loopback port. Browser/WebSocket and runner API access both need gateway policies; see [the access boundary](../docs/CONTROLLER-AUTH.md). This alpha has no built-in user authentication.

## Updates and recovery

Back up PostgreSQL and each runner's complete state before upgrading. Keep the prior image digest and locked runner environment. Choose the documented matching controller/SDK release, update MONDEK_IMAGE in .env if pinned there, then:

```sh
docker compose pull controller
docker compose up -d --wait
```

Startup applies pending database migrations automatically; failure prevents the controller from starting. Preserve the same database volume and runner state. Verify fresh measurements, settings and incident history after the update. `docker compose down` stops services while retaining the database; do not use --volumes for a routine update. Restore a coordinated backup with matching application artifacts if recovery is needed. See [upgrades](../docs/UPGRADING.md).

The recipe uses SMTP notifications. The recording webhook adapter belongs to local development/test setups and accepts only its documented local destinations; it is not a general-purpose outgoing webhook channel. Never point a test at a real recipient without authorization.

## Optional PostgreSQL TLS

Controller builds containing this feature support plain PostgreSQL (the unchanged default) and TLS. Postgrex does not use libpq's implicit SSL defaults. Set `PGSSLMODE` explicitly:

| Value | Connection policy |
| --- | --- |
| unset or `disable` | Plain TCP |
| `require` | Require encryption; do not verify the server certificate |
| `verify-ca` | Require TLS and a trusted certificate chain; skip hostname verification |
| `verify-full` | Require TLS, a trusted certificate chain and matching hostname |

Use `verify-full` for an authenticated database connection. With verified modes, `PGSSLROOTCERT` can name a PEM CA file readable inside the controller container; otherwise the runtime's system CA store is used. Mount private CA files read-only. `require` is useful for encryption-only installations with self-signed certificates, but does not authenticate the server. TLS modes never fall back to plaintext. Unsupported modes (including libpq's `allow` and `prefer`) fail at startup. Client certificate authentication is not configured by these settings.

For an external database, create a separate Compose recipe containing the controller service from above, remove its `depends_on: postgres` entry, omit the bundled postgres service and database volume, and replace the controller's hardcoded `PGHOST`, `PGPORT`, `PGDATABASE` and `PGUSER` entries with your database's values. Add `PGSSLMODE: verify-full` and, for a private CA, `PGSSLROOTCERT: /run/certs/database-ca.pem` with a read-only volume such as `./database-ca.pem:/run/certs/database-ca.pem:ro`. Keep `PGPASSWORD` in the private environment file. Startup migrations and the running controller use the same TLS configuration. Do not point this recipe at an existing bundled database volume with different credentials.

A database using a rule such as `hostssl sameuser all 10.0.0.0/8 scram-sha-256` needs TLS enabled on the PostgreSQL server and a database name matching the connecting role. Mondek does not modify server certificates or `pg_hba.conf`; PostgreSQL evaluates its rules in order.

Outside deployment mode, `DATABASE_URL=postgres://…/database?ssl=true` enables Postgrex's verified TLS defaults. For a custom CA use a URL without TLS query parameters together with `PGSSLMODE=verify-full` and `PGSSLROOTCERT`. Combining URL `ssl` with the TLS environment settings is rejected. URL `sslmode` is rejected because Ecto/Postgrex do not implement libpq URL semantics. Deployment mode continues to require separate `PG*` settings and rejects `DATABASE_URL`.
