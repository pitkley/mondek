# Email notifications

The controller can deliver incident notifications to one configured operator address through an SMTP relay. Check code creates monitoring results; it does not send mail or receive SMTP credentials. The existing incident lifecycle decides when a problem, update or closure needs notification. Acknowledgement, maintenance, grouped contributions, supersession and explicit manual retry retain their existing behavior.

## Server configuration

Set these values in the server-only controller environment file. Deployment mode selects SMTP by default; local development keeps its recording webhook unless explicitly changed.

```dotenv
MONDEK_NOTIFICATION_ADAPTER=smtp
MONDEK_SMTP_HOST=mailrelay
MONDEK_SMTP_PORT=25
MONDEK_SMTP_TRANSPORT=plain
MONDEK_SMTP_FROM=mondek@example.invalid
MONDEK_SMTP_TO=operator@example.invalid
MONDEK_SMTP_TIMEOUT_MS=10000
```

The sender and recipient must each be one bare email address, without display names or a comma-separated recipient list. A private relay may accept unauthenticated `plain` delivery. For a relay requiring credentials, set `MONDEK_SMTP_TRANSPORT=starttls` or `tls`, then provide both `MONDEK_SMTP_USERNAME` and `MONDEK_SMTP_PASSWORD`. STARTTLS is required when selected; encryption cannot silently fall back to plaintext. TLS uses the container's trusted certificate authorities and verifies the configured relay hostname. Authentication over plaintext is refused at startup. Missing or invalid configuration produces a value-free error.

The controller must share a suitable private network with the relay. Another Compose project's default network is not automatically reachable. Keep relay credentials and actual addresses on the server. Do not pass these values as Docker build arguments or put them in a source repository. Generic [webhook notifications and Teams templates](WEBHOOK-NOTIFICATIONS.md) are also available. Project-scoped recipient/routing policy and multiple active destinations remain follow-up work; the initial deployment has one installation-level destination.

## What operators receive

Each email identifies the problem, update or closure, check or shared condition, environment, available target, measured summary, original measurement time and incident link. Links use `MONDEK_PUBLIC_URL`. A measured recovery says `RECOVERED`; an administrative closure says `CLOSED` and retains its closure reason. The message describes the state at notification creation; the incident page contains current evidence and contributing checks.

Every occurrence freezes the recipient, sender, public URL, content and `Message-ID`. Changing these settings affects new occurrences; it does not redirect queued notifications. Relay connection settings and credentials remain runtime-only, so credentials can be rotated without rewriting evidence or delivery history. An older queued webhook continues using its original webhook destination even after SMTP is selected. Keep the previous receiver available if those older notifications still need delivery.

## Delivery and failure

An attempt is committed before any SMTP I/O. Database transactions are closed while the controller talks to the relay. The relay's final acceptance response marks the attempt accepted; this does not prove inbox delivery or that a person read the message. The Runners & delivery page and incident notification history expose this distinction.

Delivery is at least once. If the relay accepts the message and its reply is lost, the controller may send the same occurrence again. A retry preserves the exact message bytes and `Message-ID`; receiving mail systems may use that identity to identify duplicates, but deduplication is not promised. Controller failure after relay acceptance likewise leaves an inspectable ambiguous attempt that durable work can retry after restart.

The SMTP client makes one connection attempt per recorded attempt, without hidden library retries or MX fallback. Each attempt has a total deadline, including connection, TLS, authentication and relay response; configure 1–30 seconds, with a 10-second default. Relay response text and SMTP credentials are never persisted in error messages. Failures report safe categories such as rejected authentication, refused connection or uncertain acceptance after timeout.

SMTP retry delays grow from 30 seconds to a 15-minute cap. The default 100-attempt budget covers about 21 hours of retry waiting before exhaustion, plus time spent in attempts or acknowledgement/maintenance holds. `MONDEK_NOTIFICATION_MAX_ATTEMPTS` can lower that bounded budget. Local webhook timing remains unchanged. Exhausted work stays visible and requires an explicit reasoned retry to start another bounded budget; that retry retains the original occurrence, content, destination and SMTP timing.

## Local verification

Focused tests use an isolated PostgreSQL database, local SMTP/HTTP receiver processes and generated dummy TLS certificates:

```sh
devenv shell -- sh -c 'cd controller && PGPORT=55433 MONDEK_TEST_DATABASE=mondek_smtp_test MIX_ENV=test mix test test/mondek/smtp_notification_test.exs test/mondek/notification_test.exs'
```

The reusable [SMTP receiver](../tests/deployment/smtp_receiver.py) records mail locally and provides controlled refusal, timeout, authentication failure and lost-reply modes. It never forwards a message. Deployment acceptance uses that same receiver with real controller and runner services; sending actual external test mail is an operator action after server configuration.
