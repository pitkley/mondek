# Webhook notifications

The controller can POST incident notifications as Mondek JSON or render a custom JSON template, including the shipped Microsoft Teams Adaptive Card template. One installation-level destination is active at a time. SMTP remains available; check code never sends notifications or receives destination credentials. Acknowledgement, maintenance, grouped contributions, monitoring loss, supersession and explicit retry use the existing durable notification lifecycle.

## Configure a destination

Set these server-only environment variables:

```dotenv
MONDEK_NOTIFICATION_ADAPTER=webhook
MONDEK_WEBHOOK_CONFIG_FILE=/run/secrets/mondek-webhooks.json
```

Mount a private JSON configuration file read-only into the controller. The loader requires no group/other permissions; use mode 0600 with suitable ownership (the packaged image runs as UID 65532). Do not commit real files, URLs, headers or preview output containing private findings. The file is loaded and validated at startup; restart the controller after edits. A minimal configuration is:

```json
{
  "active": "operations",
  "destinations": {
    "operations": {
      "url": "https://receiver.example.invalid/notifications",
      "headers": {"Authorization": "Bearer REPLACE_PRIVATELY"},
      "timeout_ms": 10000
    }
  }
}
```

Omit `headers` for an unauthenticated endpoint. The URL itself may contain a secret token in its path or query, as Teams workflow URLs commonly do. URLs and headers stay in runtime configuration: neither is copied to notification payloads, delivery errors or the operator destination display. The stored destination is `webhook:operations`, with a SHA-256 fingerprint binding that identity to its original URL. Configuration errors omit supplied values. Use HTTPS; plain HTTP is accepted only for explicit localhost/loopback test receivers. URL user information, fragments, raw whitespace, header injection and overrides of transport-controlled headers are rejected. Optional `cacertfile` selects a PEM CA file, relative to the configuration file or absolute; otherwise HTTPS uses system trust. Hostname and certificate-chain verification are required.

In the deployment Compose recipe, set the two environment variables above in its private .env file, and mount `./mondek-webhooks.json:/run/secrets/mondek-webhooks.json:ro`. Set `MONDEK_PUBLIC_URL` to the installation's HTTPS origin for incident links. Deployment mode requires an explicit webhook configuration file. Local development without one retains its existing local recording receiver and payload format.

## Stable Mondek document

With no `template`, the body is a JSON document with `version: 1` and these fields:

| Object | Fields |
| --- | --- |
| `notification` | `id`, `event`, `title`, `summary`, `created_at` |
| `incident` | `id`, `type`, `url`, `closure_reason` |
| `evidence` | `health`, `measured_health`, `display_health`, `source_at`, `environment`, `target`, `affected_count`, `scope` |
| root | `version`, `notice` |

Events are `problem`, `updated`, `recovered`, `closed`, `monitoring_lost` and `monitoring_restored`. Incident type is `health` (including shared conditions) or `monitoring_loss`. IDs and original timestamps retain their source identities. Optional evidence values are JSON null. A target, when present, has `key`, `kind` and `label`. `health` describes the incident at notification creation; `measured_health` is the triggering measurement when available. On measured recovery, `display_health` uses the recovery measurement rather than the incident's prior failing severity. Monitoring-loss documents leave target health null; restored monitoring does not establish healthy targets. Administrative closure is `closed`, with its reason preserved, rather than a manufactured recovery.

The title is bounded to a 240-character label plus its event heading, summary to 4000 characters and target label to 512 characters. The document intentionally exposes a stable notification view rather than internal reducer payloads. Fields may be added compatibly to v1; incompatible meaning or shape changes require a new version. Receivers should ignore additional fields. Group details and full monitoring scope remain available through the incident link.

## Custom JSON templates

Set `template` on a destination to a JSON file path (relative to the configuration file or absolute). Templates are JSON structures, not executable code or raw text substitution. Ordinary objects, arrays and scalar values remain literal. Special directive objects must have exactly the documented keys:

```json
{
  "text": {"$concat": ["Mondek: ", {"$ref": "notification.title"}]},
  "link": {"$ref": "incident.url"},
  "environment": {
    "$if": "evidence.environment",
    "then": {"$ref": "evidence.environment"},
    "else": "Unspecified"
  }
}
```

`{"$ref":"path.to.field"}` substitutes a typed JSON value, preserving strings, numbers, booleans, objects, arrays and null. Dotted paths use object keys, not array indexes. Unknown paths are errors. `{"$concat":[...]}` joins rendered strings; use a conditional for nullable strings. `{"$if":"path","then":...,"else":...}` selects the else branch for null, false, an empty string or an empty array. `{"$each":"path","template":...}` renders an array (at most 100 items), exposing each value as `item`; the document fields remain available inside the loop. There is no evaluation, file access, network access or interpolation inside strings. JSON encoding escapes findings automatically, so embedded quotes, newlines and Unicode cannot change the output structure. Template content must not contain credentials: rendered bodies are persisted and inspectable.

Configuration and template files are limited to 64 KiB; at most 16 destination definitions are allowed. Rendering has a 20-level depth limit, an execution budget and a 256 KiB encoded-body limit. Templates are checked against synthetic lifecycle documents at startup, but real data can still exceed bounds or encounter a nullable field. A rendering failure never rolls back an admitted measurement: it creates a notification with a safe template-error marker and original document; its first dispatch records a failed attempt, marks it exhausted and discards automatic work. Fixing a template affects future occurrences. Explicit retry preserves the original snapshot, including a render failure, rather than silently rewriting history.

## Microsoft Teams

Set `"template": "teams"` in the destination definition. This selects the bundled [Adaptive Card template](../controller/priv/notification_templates/teams.json), using the same generic renderer and HTTP transport. It includes event, summary, health, measurement time, environment, target, scope, creation time, closure reason and an incident link. Copy that file and select its path to customize it.

Create a webhook in the Teams **Workflows** app, using a workflow that receives webhook requests and posts the supplied Adaptive Card attachments to the intended channel/chat. Configure its caller authentication to match the destination: a secret URL with an unauthenticated caller option is supported, as are explicitly configured static authentication headers. OAuth token acquisition/refresh is not implemented. Put the generated URL only in the private configuration. Add workflow co-owners as appropriate for continuity. Microsoft retired connector-based Incoming Webhooks in May 2026; use Workflows rather than an old connector recipe. See [Microsoft's current webhook setup and Adaptive Card examples](https://learn.microsoft.com/en-us/microsoftteams/platform/webhooks-and-connectors/how-to/add-incoming-webhook).

Teams imposes its own payload limits (currently 28 KB). Preview representative real findings and keep customized cards within the receiver's limit; Mondek's generic 256 KiB cap is not a guarantee that Teams will accept a payload. This integration has local JSON, HTTP and TLS verification; posting to an actual Teams tenant remains an explicitly authorized operator test.

## Preview without sending

From the source checkout:

```sh
devenv shell -- sh -c 'cd controller && mix mondek.webhook.preview --template teams --event recovered'
```

The command compiles the controller but does not start it, access a database, load private webhook configuration or send a request. Omit `--template` for default Mondek JSON. Select `--event problem|updated|recovered|closed|monitoring_lost|monitoring_restored`. Use `--template PATH` for a custom template and `--input DOCUMENT.json` for a real or synthetic normalized document instead of an example. Output goes to stdout; treat real notification content as private.

## Delivery, changes and retries

The body, document, content type, destination ID and URL fingerprint freeze at occurrence creation. Each attempt commits before network I/O; database transactions are closed while delivering. Requests include `X-Mondek-Occurrence` with the original notification ID. Delivery is at least once: a lost reply or controller interruption can cause a duplicate with the same ID and body. HTTP 2xx means the receiver accepted the request, not that Teams posted the card or a person read it. HTTP/1.1 response headers are bounded to 16 KiB; bodies are never collected, logged or interpreted. Redirects and hidden HTTP retries are disabled. Each attempt has a total 1–30 second deadline (10 seconds by default), including connection, DNS, TLS and response headers.

HTTP 429 and 503 use the durable retry path and retain the HTTP status. Integer `Retry-After` delays are clamped to 30–900 seconds and combined with the normal increasing delay; other header forms use the normal delay. Other non-2xx responses also retry within the configured budget. Production webhook delays grow from 30 seconds to a 15-minute cap, with the existing `MONDEK_NOTIFICATION_MAX_ATTEMPTS` budget (default 100); the local recording webhook retains its existing timing. Exhausted work remains visible for an explicit reasoned retry.

Changing a template or `active` affects new occurrences. To change destination URLs, add a new destination ID and switch `active`; retain the old definition until queued deliveries drain. Up to 16 definitions can coexist, but only one receives new notifications: there is no fan-out or routing policy yet. Reusing an ID with a different URL fails closed for its older queued deliveries; restoring the exact old ID and URL restores their binding. Headers and connection trust/timeouts remain runtime settings and can rotate without rewriting the frozen body. Keep the webhook file configured when switching to SMTP so queued webhooks can drain; retain SMTP settings when switching to webhooks if queued email still needs delivery. Legacy queued local webhooks retain their original local destination and format.

The document and delivery envelope are distinct inside the existing occurrence payload. The existing occurrence row remains the single delivery slot, with its current attempts and eligibility locks; no database migration is needed. Future routing can reuse the document, destination IDs, renderer and transport while moving these per-destination snapshots, attempts and statuses into multiple delivery rows. This change deliberately does not introduce routing, target management or a generic workflow framework.
