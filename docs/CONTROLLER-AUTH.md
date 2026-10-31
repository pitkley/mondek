# Controller request authentication

The runner and `mondek-policy` accept generic HTTP authentication headers through `MONDEK_CONTROLLER_HEADERS_FILE`. This is gateway authentication, not Mondek user management or runner-specific authorization. Gateway access does not bind requests to a particular runner installation. Use it only within a trusted operator boundary.

## Private file format

```json
{
  "origin": "https://monitoring.example.test",
  "headers": {
    "Authorization": "Bearer YOUR_GATEWAY_TOKEN"
  }
}
```

Use the header names and values required by your gateway. Require a regular file readable by the process, with no group/other permissions (normally mode `0600`). The bounded file must contain exactly `origin` and `headers`. The origin must match the request's HTTPS host and port; credentials are refused over HTTP, for a different origin, or with URL user information. Header names are case-insensitively unique; protocol-controlled headers, control characters, duplicate JSON keys and oversized files are rejected. With no environment variable, local HTTP development continues unchanged.

Every HTTP helper reads the file afresh, so atomically replacing it rotates credentials without restarting the process. Requests already in flight may still use the previous token. Credentials are not put in command arguments, journalled request envelopes, inventory or policy plan files. Datasource HTTP requests do not use these headers. Consumer code runs under the runner's account and is trusted code; this is not a secret isolation boundary against that code.

All runner HTTP exchanges refuse redirects, including redirects to the same origin. The policy CLI also refuses redirects. HTTP 401/403 produces an access-denied diagnostic; authenticated HTTP failures omit the response reason/body to avoid reflecting credentials from a gateway error. Invalid local credential files produce an actionable configuration error without including their contents. Existing retry, execution and journal behavior remains intact; access failures do not count as successful delivery.

## Address-family fallback

Runner controller requests stagger TCP connection attempts by 250 milliseconds and interleave resolved IPv6/IPv4 candidates, preserving resolver order within each family. A nonresponsive preferred address no longer consumes the whole request deadline before the other family is tried. At most 16 resolved candidates are attempted, and losing sockets are closed. The existing helper-process deadline still bounds DNS, connection attempts, TLS and response reads. Only TCP is raced: one winning connection performs TLS and sends one HTTP request. Certificate/hostname errors and HTTP failures do not trigger a second submission; redirect refusal and origin-bound headers remain unchanged. This does not repair a broken IPv6 network, race TLS handshakes, change datasource HTTP clients or alter control/observation admission semantics.

## Gateway configuration

For a hosted installation, protect all operator HTTP routes and `/live` WebSocket connections, including their upgrade requests. Restrict direct origin access to the gateway, for example by binding to loopback behind a local proxy or using firewall rules, so clients cannot bypass those access checks. Protecting only the initial page load is insufficient.

Configure machine access for the three runner endpoints: `/api/v1/inventory`, `/api/v1/control` and `/api/v1/observations`. Keep browser login and machine authentication separate. Gateways may match more specific path policies independently of the root policy; verify the complete gateway-to-origin route, including credential audience checks where applicable. Keep credentials outside source control and runner journals.

`mondek-policy` uses the same private file format, but operator access to `/api/v1/configuration/*` needs an explicit gateway policy and appropriate credentials. Runner endpoint access alone does not grant configuration access. See [runner deployment](RUNNER-DEPLOYMENT.md) for installed-consumer and state handling.

## Read-only connection diagnostic

Execute as the runner's account with the same connection settings:

```sh
mondek-runner doctor --controller https://monitoring.example.test \
  --headers-file /var/lib/mondek/controller-auth.json
```

The defaults are `MONDEK_CONTROLLER_URL` and `MONDEK_CONTROLLER_HEADERS_FILE`. This performs GET requests to the three existing POST-only runner routes. It neither registers a runner nor writes inventory, observations or journal state. Each request has an eight-second total deadline including DNS and body reads (`--timeout` accepts 1–30 seconds). Redirects are refused. Output includes only safe error categories, HTTP status, supported gateway request identifiers and bounded error codes when available; it never prints authentication headers, file contents, response bodies or redirect locations.

A 404/405 is reported as `reachable_unverified`: a server responded to the GET probe, but neither controller identity nor successful POST registration is established. Even an intermediary can generate that response. Exit 0 means all three probes reached this limited result; exit 1 means at least one endpoint needs investigation; exit 2 means the command/settings could not be used. Confirm actual `controller_ready` events and visible runner coverage afterwards.

| Evidence | Next step |
| --- | --- |
| `authentication_file` | Check the configured path, file owner/mode, JSON structure and exact HTTPS origin as the runner account. Do not print its contents. |
| DNS, connection or TLS failure | Check hostname resolution, outbound connectivity and certificate trust on the runner host. |
| Redirect | Check the matched gateway application and machine-access policy; the runner will not follow a login redirect. |
| HTTP 401/403 | Correlate available request identifiers and error codes with gateway security events. Check machine-access policy, credential audience and origin middleware. A 403 alone cannot identify which component rejected the request. |
| `reachable_unverified` | Check real inventory/control/observations journal events and the controller UI. This probe intentionally does not submit a fake runner. |

## Verification boundary

Local tests use real HTTPS, trusted test certificates and the normal bounded subprocess clients. They exercise runner endpoints, policy requests, rejection, credential rotation, redirect refusal, malformed files, read-only diagnostics, journal retry and recovery logging. The [gateway acceptance harness](../tests/e2e/README.md) uses two independent synthetic observers. Local coverage does not establish a deployed installation's gateway policy, reboot recovery or token rotation; verify these in the operator's own environment.
