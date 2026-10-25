# Install the Mondek server

Use Docker with Compose. This recipe runs only the controller and PostgreSQL, with persistent database storage and no demo checks or test receiver. It needs no source build, Nix or Python on the controller host. The 0.0.1a1 registry image is being prepared; until it is published, supply MONDEK_IMAGE with a locally built controller tag.

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
