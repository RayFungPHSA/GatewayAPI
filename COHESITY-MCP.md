# Cohesity MCP through the Caddy gateway

The Cohesity MCP server is a stdio Python process. It has been copied to
`C:\caddy-gateway\cohesity-mcp` and exposed through a small local HTTP bridge
on `127.0.0.1:8400`. Caddy proxies `/cohesity/*` to that bridge on both gateway
listeners.

**The Cohesity/Helios API key is server-side only.** It is not accepted from
clients and is not stored in the Caddyfile, client configs, or the copied MCP
folder. Clients authenticate with a **per-user gateway token** that is mapped
to a named ACL entry with a role.

The same gateway token and ACL are also used by the HPEGreenLake MCP endpoint
at `/hpegreenlake/mcp`. See **[HPEGREENLAKE-MCP.md](HPEGREENLAKE-MCP.md)**.
No second token is required.

- `admin` — full REST/tool access, including `run_backup`, `api_request` with
  any HTTP method, and `collect_protection_group_usage`.
- `read-only` — GET/read tools only. `api_request` is restricted to `GET` with
  no request body. Mutating tools are hidden from `tools/list` and denied by
  `tools/call`.

```
MCP client (X-Gateway-Token only)
        |
        v
Caddy :8081 / :8088  /cohesity/mcp
        |
        v
Cohesity HTTP bridge 127.0.0.1:8400
   - validates token against named ACL
   - injects shared server-side Cohesity key
        |
        v
short-lived cohesity_mcp.py process
        |
        v
https://helios.cohesity.com
```

## Gateway URLs

| Use | URL |
|---|---|
| HTTP (no cert/admin needed) | `http://10.53.19.120:8081/cohesity/mcp` |
| HTTPS (local Caddy CA) | `https://10.53.19.120:8088/cohesity/mcp` |
| Bridge health (no auth) | `http://10.53.19.120:8081/cohesity/health` |

Header on **every** MCP request (initialize, tools/list, tools/call):

```text
X-Gateway-Token: <token issued to you>
```

Do **not** send `X-Cohesity-API-Key`, `X-Helios-API-Key`, or
`Authorization: Bearer`. The bridge rejects those with HTTP 400.

---

## 1. Gateway owner: configure the shared key

The key currently used by the Copilot/CStorageDashboard MCP server is reused.
Create the server-only protected record once:

```powershell
C:\caddy-gateway\cohesity-mcp\Initialize-CohesitySharedKey.ps1
```

This reads `COHESITY_API_KEY` from
`C:\Code\CStorageDashboard\mcp-configs\cohesity\.env` and writes only to
`C:\caddy-gateway\secrets\cohesity-gateway.xml`. The JSON payload is wrapped in
a `PSCredential` and protected with Windows DPAPI for the current Windows
account. The file is also NTFS-restricted to the current user, SYSTEM, and
Administrators. The key is not displayed and no plain-text env file is created.

If the source key changes later, re-import it:

```powershell
C:\caddy-gateway\cohesity-mcp\Initialize-CohesitySharedKey.ps1 -Force
C:\caddy-gateway\cohesity-mcp\Stop-CohesityMcpBridge.ps1
C:\caddy-gateway\cohesity-mcp\Start-CohesityMcpBridge.ps1
```

To rotate the key without a source file, enter it locally when prompted:

```powershell
C:\caddy-gateway\cohesity-mcp\Set-CohesityGatewayCredential.ps1
C:\caddy-gateway\cohesity-mcp\Stop-CohesityMcpBridge.ps1
C:\caddy-gateway\cohesity-mcp\Start-CohesityMcpBridge.ps1
```

> DPAPI is tied to the Windows account that created the record. Run the setup
> script and `Start-CohesityMcpBridge.ps1` under the same account.

---

## 2. Gateway owner: issue per-user tokens

The approved list is built into `Initialize-CohesityGatewayAcl.ps1`. Ray Fung
is the only `admin`; everyone else is `read-only`. The duplicate
`Ray.Fung@phsa.ca` line in the regular-user list is the same person as the
admin, so it is intentionally not issued a second token.

```powershell
C:\caddy-gateway\cohesity-mcp\Initialize-CohesityGatewayAcl.ps1
```

This writes tokens to a temporary restricted file:

```text
C:\caddy-gateway\secrets\gateway-tokens-to-distribute.txt
```

Distribute each token privately, then delete that file. The ACL stores only
SHA-256 fingerprints, so tokens cannot be recovered from it.

For a single user:

```powershell
# read-only is the default
C:\caddy-gateway\cohesity-mcp\New-CohesityGatewayToken.ps1 -Name 'alice@example.com'

# admin
C:\caddy-gateway\cohesity-mcp\New-CohesityGatewayToken.ps1 -Name 'ray.fung@phsa.ca' -Role admin
```

Rotate a token or change a role:

```powershell
C:\caddy-gateway\cohesity-mcp\New-CohesityGatewayToken.ps1 -Name 'alice@example.com' -Role read-only -Force
C:\caddy-gateway\cohesity-mcp\Set-CohesityGatewayRole.ps1 -Name 'alice@example.com' -Role admin
```

List or remove entries:

```powershell
C:\caddy-gateway\cohesity-mcp\Get-CohesityGatewayAcl.ps1
C:\caddy-gateway\cohesity-mcp\Remove-CohesityGatewayToken.ps1 -Name 'alice@example.com'
```

ACL changes take effect on the next request; the bridge reloads the file when
it changes. Unknown or missing tokens are denied by default.

### Read-only guardrails

Read-only tokens cannot call:

- `run_backup`
- `collect_protection_group_usage`
- `api_request` with any method other than `GET`
- `api_request` with a request body
- any tool not on the explicit read-only allowlist

Admin tools are also hidden from `tools/list` for read-only users. The
read-only `api_request` schema advertises `method` as `GET` only.

The read-only toolset includes dedicated GET operations for clusters,
protection groups and runs, policies, alerts, protected objects, recoveries,
audit logs, sources, tenants, encryption, and usage history. The full inventory
and the official endpoints behind each tool are recorded in
[VENDOR-API-COVERAGE.md](VENDOR-API-COVERAGE.md).

---

## 3. Gateway owner: start the bridge

The bridge is not part of Caddy, so it must be running whenever users need the
Cohesity tools.

```powershell
C:\caddy-gateway\cohesity-mcp\Start-CohesityMcpBridge.ps1
```

Expected:

```text
Cohesity MCP bridge started on http://127.0.0.1:8400/mcp (PID 16144).
Auth: per-user gateway tokens; ACL users: 1
Logs: C:\caddy-gateway\cohesity-mcp\bridge.log
Errors: C:\caddy-gateway\cohesity-mcp\bridge.err.log
```

Stop it with:

```powershell
C:\caddy-gateway\cohesity-mcp\Stop-CohesityMcpBridge.ps1
```

Caddy was already reloaded with the new route and token-header hashing. If you
rebuild the Caddyfile:

```powershell
caddy validate --config C:\caddy-gateway\Caddyfile
caddy reload --config C:\caddy-gateway\Caddyfile
```

---

## 4. Each user: configure your MCP client

You need only the gateway token from the owner. You do **not** need a Cohesity
API key.

### OpenCode 2.x

Set the token in a terminal you will use for OpenCode:

```powershell
setx COHESITY_GATEWAY_TOKEN "<your gateway token>"
```

Open a **new** terminal, then merge this into
`%USERPROFILE%\.config\opencode\opencode.json`:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "mcp": {
    "servers": {
      "cohesity": {
        "type": "remote",
        "url": "http://10.53.19.120:8081/cohesity/mcp",
        "oauth": false,
        "headers": {
          "X-Gateway-Token": "{env:COHESITY_GATEWAY_TOKEN}"
        }
      }
    }
  }
}
```

`oauth: false` is required. If you trust the local Caddy root certificate, use
`https://10.53.19.120:8088/cohesity/mcp` instead.

If `COHESITY_GATEWAY_TOKEN` was just set or changed, run
`opencode service restart` so the client inherits the new environment.

### OpenCode 1.x

```json
{
  "mcp": {
    "cohesity": {
      "type": "remote",
      "url": "http://10.53.19.120:8081/cohesity/mcp",
      "enabled": true,
      "headers": {
        "X-Gateway-Token": "{env:COHESITY_GATEWAY_TOKEN}"
      }
    }
  }
}
```

### Claude Code / Claude Desktop

`.mcp.json` or `claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "cohesity": {
      "type": "http",
      "url": "http://10.53.19.120:8081/cohesity/mcp",
      "headers": {
        "X-Gateway-Token": "${COHESITY_GATEWAY_TOKEN}"
      }
    }
  }
}
```

### Other Streamable-HTTP MCP clients

Use one server named `cohesity`, type `http`/`remote`, oauth disabled if the
option exists, and one header:

```text
X-Gateway-Token: <your gateway token>
```

---

## 5. Test the endpoint

Set the token for the current PowerShell session:

```powershell
$env:COHESITY_GATEWAY_TOKEN = '<your gateway token>'
```

Then run either test from the gateway share/copy:

```powershell
C:\caddy-gateway\Test-CohesityMcp.ps1
C:\caddy-gateway\Test-CohesityMcp-Curl.ps1
```

Expected for each:

```text
  PASS  Bridge health endpoint
  PASS  MCP initialize
  PASS  MCP tools/list
  PASS  MCP tools/call list_clusters
  PASS  Missing token is rejected
  PASS  Invalid token is rejected

Result: 6 passed, 0 failed
```

Guardrail verification (uses one admin token and one read-only token):

```powershell
$env:COHESITY_GATEWAY_ADMIN_TOKEN = '<ray.fung token>'
$env:COHESITY_GATEWAY_READONLY_TOKEN = '<a read-only user token>'
C:\caddy-gateway\Test-CohesityMcpGuardrails.ps1
```

Expected: 8 passed, 0 failed. This checks admin-only tool visibility,
GET-only `api_request`, and denial of mutating calls for read-only users.

HTTPS variants:

```powershell
C:\caddy-gateway\Test-CohesityMcp-Curl.ps1 -BaseUrl https://10.53.19.120:8088 -CurlArgs '--ssl-no-revoke'
C:\caddy-gateway\Test-CohesityMcp.ps1 -BaseUrl https://10.53.19.120:8088 -AllowUntrustedCertificate
```

One-line raw HTTP check:

```powershell
curl.exe -sS -H "X-Gateway-Token: $env:COHESITY_GATEWAY_TOKEN" -H "Accept: application/json, text/event-stream" -H "Content-Type: application/json" --data-binary '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' http://10.53.19.120:8081/cohesity/mcp
```

---

## Monitoring usage

Neither log contains a raw Cohesity key or a raw gateway token.

### 1. Caddy access log — all gateway traffic

File: `C:\caddy-gateway\logs\access.log` (JSON lines, rolled at 10 MB)

It records source IP, method, path, status, duration, bytes, and user agent.
`X-Gateway-Token` and legacy key headers are replaced with short SHA-256
hashes. `Authorization` is redacted by Caddy by default.

```powershell
C:\caddy-gateway\Get-GatewayUsage.ps1
C:\caddy-gateway\Get-GatewayUsage.ps1 -SinceHours 168 -Top 50
```

### 2. Cohesity MCP usage log — authenticated per-user activity

File: `C:\caddy-gateway\cohesity-mcp\usage.jsonl`

```json
{"ts":"...","event":"tools/call","user":"alice@example.com","role":"read-only","key_fp":"7a62b44e159e","token_fp":"9f2c1a0b77de","client_ip":"10.53.19.120","ok":true,"tool":"list_clusters","duration_ms":2391.4}
```

- `user` is the authenticated ACL name from the gateway token.
- `role` is `admin` or `read-only`.
- `token_fp` identifies which token was used.
- `key_fp` is the shared server-side Cohesity key fingerprint.
- Denials are logged as `auth_denied` or `tool_denied` with a `reason`.

Report:

```powershell
C:\caddy-gateway\Get-CohesityMcpUsage.ps1
C:\caddy-gateway\Get-CohesityMcpUsage.ps1 -SinceHours 168 -Top 50
```

If you change Caddy logging options, a full `caddy stop` / `caddy start` may be
required — `caddy reload` does not apply output-file changes.

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| HTTP 401 `A gateway token is required` | The MCP client is not sending `X-Gateway-Token` on every request. Check `oauth: false` / `enabled: true` and the `headers` block. |
| HTTP 401 says the header has an unexpanded placeholder | The client sent literal `${COHESITY_GATEWAY_TOKEN}` or `{env:COHESITY_GATEWAY_TOKEN}`. In OpenCode use `{env:COHESITY_GATEWAY_TOKEN}`, then run `opencode service restart`. |
| HTTP 403 `This gateway token is not authorized` | The token was revoked, replaced, or never added to the ACL. Check `Get-CohesityGatewayAcl.ps1`. |
| Tool error says `admin-only` or `GET only` | Your token is `read-only`. Ask the gateway owner to use `Set-CohesityGatewayRole.ps1` if you need admin access. |
| HTTP 400 about client-supplied API keys | A legacy `X-Cohesity-API-Key`, `X-Helios-API-Key`, or `Authorization: Bearer` header is still configured. Remove it; only send `X-Gateway-Token`. |
| Tool result says authentication failed | The shared server-side key is wrong/expired. Rotate it with `Set-CohesityGatewayCredential.ps1` and restart the bridge. |
| `Connection refused` on `127.0.0.1:8400` | The bridge is not running. Run `Start-CohesityMcpBridge.ps1`. |
| Bridge will not start about the protected credential | `secrets\cohesity-gateway.xml` is missing, empty, or was created by another Windows account. Run `Initialize-CohesitySharedKey.ps1 -Force` or `Set-CohesityGatewayCredential.ps1` as the bridge account. |
| Gateway route returns the generic Caddy message | Caddy was not reloaded with the `/cohesity/*` route. Reload the Caddyfile. |
| HTTPS certificate error | Use HTTP `:8081`, install `caddy-local-root.crt`, or pass `--ssl-no-revoke` to curl.exe. |

**Security note:** on HTTP `:8081`, the gateway token travels across the LAN in
cleartext. The ACL prevents unnamed use, but anyone who captures a token can
replay it. Use HTTPS `:8088` wherever the client can trust the Caddy local CA.
The bridge listens only on loopback; keys exist only in the DPAPI-protected
record, and neither keys nor raw tokens are written to logs or client configs.

## Rollback

1. Remove the `/cohesity/*` block from `C:\caddy-gateway\Caddyfile` and reload Caddy.
2. Run `Stop-CohesityMcpBridge.ps1`.
3. Delete `C:\caddy-gateway\secrets` and the gateway-token scripts if returning
   to per-user keys; restore the previous per-user-key bridge and tests.
