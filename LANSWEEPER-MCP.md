# Lansweeper MCP through the Caddy gateway

The on-prem Lansweeper Classic web-console MCP from
`C:\Code\CStorageDashboard\mcp-configs\lansweeper` has been copied to
`C:\caddy-gateway\lansweeper-mcp` and exposed through a local HTTP bridge on
`127.0.0.1:8402`. Caddy proxies `/lansweeper/*` to that bridge on both gateway
listeners.

This server uses the **same gateway token and named-user ACL as Cohesity and
HPEGreenLake**. A user who can call `/cohesity/mcp` can also call
`/lansweeper/mcp` with the same `X-Gateway-Token` header and the same
`admin`/`read-only` role.

The Lansweeper Windows/AD credential is **server-side only**. It was copied
from the source project's `lansweeper.env` into a restricted secrets file by the
gateway owner. It is not accepted from clients and is not stored in the
Caddyfile, client configs, the copied MCP folder, prompts, or logs.

The source credential values were not displayed during setup.

```
MCP client (X-Gateway-Token only)
        |
        v
Caddy :8081 / :8088  /lansweeper/mcp
        |
        v
Lansweeper HTTP bridge 127.0.0.1:8402
   - validates token against the shared ACL
   - injects the server-side Windows/AD credential
        |
        v
short-lived Node stdio process (src/server.js)
        |
        v
Lansweeper Classic web console (login.aspx + authenticated page/report reads)
```

## Gateway URLs

| Use | URL |
|---|---|
| HTTP (no cert/admin needed) | `http://10.53.19.120:8081/lansweeper/mcp` |
| HTTPS (local Caddy CA) | `https://10.53.19.120:8088/lansweeper/mcp` |
| Bridge health (no auth) | `http://10.53.19.120:8081/lansweeper/health` |

Header on **every** MCP request (initialize, tools/list, tools/call):

```text
X-Gateway-Token: <your existing gateway token>
```

Do **not** send `X-Lansweeper-Username`, `X-Lansweeper-Password`,
`X-Lansweeper-Api-Key`, `X-Lansweeper-Key`, `X-Api-Key`, `X-Client-Secret`,
`X-Cohesity-API-Key`, `X-Helios-API-Key`, or `Authorization: Bearer`. The bridge
rejects client-supplied upstream credentials with HTTP 400.

---

## 1. Gateway owner: configure the server-side credential

The credential record was created from the source project's
`C:\Code\CStorageDashboard\mcp-configs\lansweeper\lansweeper.env`. Only approved
variable names were copied into a DPAPI-protected `PSCredential` record:

```text
C:\caddy-gateway\secrets\lansweeper-gateway.xml
```

A raw copy of the source file was never placed in the gateway folder. The
values are protected with Windows DPAPI for the current Windows account, and the
destination file is NTFS-restricted to the current user, SYSTEM, and
Administrators. Values are not displayed by the setup script and no plain-text
env file is created.

To re-import the source record:

```powershell
C:\caddy-gateway\lansweeper-mcp\Initialize-LansweeperSharedKey.ps1 -Force
C:\caddy-gateway\lansweeper-mcp\Stop-LansweeperBridge.ps1
C:\caddy-gateway\lansweeper-mcp\Start-LansweeperBridge.ps1
```

To rotate only the Windows/AD password locally, enter it when prompted:

```powershell
C:\caddy-gateway\lansweeper-mcp\Set-LansweeperGatewayCredential.ps1
C:\caddy-gateway\lansweeper-mcp\Stop-LansweeperBridge.ps1
C:\caddy-gateway\lansweeper-mcp\Start-LansweeperBridge.ps1
```

The copied MCP folder deliberately contains **no** `lansweeper.env` or `.env`.
`src\server.js` and `scripts\probe.mjs` only load a credential file if
`LANSWEEPER_ENV_FILE` is explicitly set; normal gateway startup removes that
variable so the Node child inherits credentials only from the bridge process,
which reads them from the DPAPI record.

> DPAPI is tied to the Windows account that created the record. Run setup and
> `Start-LansweeperBridge.ps1` under the same account.

> The current configuration uses the Windows account from the source project as
> requested. For a longer-lived production setup, consider replacing it with a
> dedicated least-privilege Lansweeper read-only service account.

---

## 2. Gateway owner: tokens and roles

No second token list is needed. Lansweeper reads the existing ACL:

```text
C:\caddy-gateway\secrets\cohesity-gateway-acl.json
```

Manage users with the existing scripts:

```powershell
C:\caddy-gateway\cohesity-mcp\Get-CohesityGatewayAcl.ps1
C:\caddy-gateway\cohesity-mcp\New-CohesityGatewayToken.ps1 -Name 'alice@example.com' -Role read-only
C:\caddy-gateway\cohesity-mcp\Set-CohesityGatewayRole.ps1 -Name 'alice@example.com' -Role admin
C:\caddy-gateway\cohesity-mcp\Remove-CohesityGatewayToken.ps1 -Name 'alice@example.com'
```

ACL changes take effect on the next request; no bridge restart is needed.

### Read-only guardrails

All current Lansweeper tools are read-only:

- `lansweeper_connection_status`
- `lansweeper_auth_status`
- `lansweeper_discover_endpoints`
- `lansweeper_list_assets`
- `lansweeper_fetch_page`

Read-only users see and can call all of them. There are no admin-only
Lansweeper tools today. If a future upstream tool is mutating, it remains
hidden from `tools/list` and denied by `tools/call` until it is added to the
explicit read-only allowlist in `http_bridge.py`.

The bridge also enforces `readOnlyHint: true` and `destructiveHint: false` on
every tool it advertises to read-only users.

---

## 3. Gateway owner: start the bridge

```powershell
C:\caddy-gateway\lansweeper-mcp\Start-LansweeperBridge.ps1
```

Expected:

```text
Lansweeper MCP bridge started on http://127.0.0.1:8402/mcp (PID 1234).
Auth: shared gateway-token ACL; ACL users: 15
Logs: C:\caddy-gateway\lansweeper-mcp\bridge.log
Errors: C:\caddy-gateway\lansweeper-mcp\bridge.err.log
```

Stop it with:

```powershell
C:\caddy-gateway\lansweeper-mcp\Stop-LansweeperBridge.ps1
```

Caddy is already reloaded with the `/lansweeper/*` route. If you rebuild the
Caddyfile:

```powershell
caddy validate --config C:\caddy-gateway\Caddyfile
caddy reload --config C:\caddy-gateway\Caddyfile
```

---

## 4. Each user: configure your MCP client

Reuse the same `COHESITY_GATEWAY_TOKEN` environment variable and add a
`lansweeper` server entry. Keep existing `cohesity` and `hpegreenlake` entries.

The consolidated prompt in
**[GATEWAY-ONE-PROMPT-WITH-TOKEN.md](GATEWAY-ONE-PROMPT-WITH-TOKEN.md)** does
this automatically by reading `/mcp/servers`. It assumes the user has already
set `COHESITY_GATEWAY_TOKEN` locally and never handles the token value itself.

### OpenCode 2.x

```json
{
  "$schema": "https://opencode.ai/config.json",
  "mcp": {
    "servers": {
      "cohesity": {
        "type": "remote",
        "url": "http://10.53.19.120:8081/cohesity/mcp",
        "oauth": false,
        "headers": { "X-Gateway-Token": "{env:COHESITY_GATEWAY_TOKEN}" }
      },
      "hpegreenlake": {
        "type": "remote",
        "url": "http://10.53.19.120:8081/hpegreenlake/mcp",
        "oauth": false,
        "headers": { "X-Gateway-Token": "{env:COHESITY_GATEWAY_TOKEN}" }
      },
      "lansweeper": {
        "type": "remote",
        "url": "http://10.53.19.120:8081/lansweeper/mcp",
        "oauth": false,
        "headers": { "X-Gateway-Token": "{env:COHESITY_GATEWAY_TOKEN}" }
      }
    }
  }
}
```

After changing the token or config, run:

```powershell
opencode service restart
```

### OpenCode 1.x

```json
{
  "mcp": {
    "lansweeper": {
      "type": "remote",
      "url": "http://10.53.19.120:8081/lansweeper/mcp",
      "enabled": true,
      "headers": { "X-Gateway-Token": "{env:COHESITY_GATEWAY_TOKEN}" }
    }
  }
}
```

### Claude Code / Claude Desktop

```json
{
  "mcpServers": {
    "lansweeper": {
      "type": "http",
      "url": "http://10.53.19.120:8081/lansweeper/mcp",
      "headers": { "X-Gateway-Token": "${COHESITY_GATEWAY_TOKEN}" }
    }
  }
}
```

Use HTTPS URLs instead if your client trusts the Caddy local CA.

---

## 5. Tool behavior

| Tool | What it does |
|---|---|
| `lansweeper_connection_status` | Checks network/TLS reach to the configured console without logging in. |
| `lansweeper_auth_status` | Logs in with the configured server-side account and reports success; never returns the password or real username. |
| `lansweeper_discover_endpoints` | Probes candidate web-console paths and reports which return asset-like tables. Use this first if the asset path is unknown. |
| `lansweeper_list_assets` | Reads the Lansweeper `Assets` report as JSON records, with `page`, `top`, `order`, `orderby`, `filters`, and `limit`. |
| `lansweeper_fetch_page` | Fetches an authenticated web-console page as `tables`, `text`, or `html`. Useful for exploring report pages. |

Because this is a Classic web-console MCP, each gateway request starts a
short-lived Node stdio process. The Lansweeper session lives only inside that
request; no browser cookie or credential is returned to the client.

---

## 6. Test the endpoint

Set the token for the current session:

```powershell
$env:COHESITY_GATEWAY_TOKEN = '<your gateway token>'
```

Then run:

```powershell
C:\caddy-gateway\Test-LansweeperMcp.ps1
C:\caddy-gateway\Test-LansweeperMcp-Curl.ps1
```

Expected: 7 passed / 0 failed and 8 passed / 0 failed.

Guardrail verification (uses one admin and one read-only token):

```powershell
$env:COHESITY_GATEWAY_ADMIN_TOKEN = '<ray.fung token>'
$env:COHESITY_GATEWAY_READONLY_TOKEN = '<a read-only user token>'
C:\caddy-gateway\Test-LansweeperMcpGuardrails.ps1
```

Expected: 6 passed / 0 failed.

HTTPS variants:

```powershell
C:\caddy-gateway\Test-LansweeperMcp-Curl.ps1 -BaseUrl https://10.53.19.120:8088 -CurlArgs '--ssl-no-revoke'
C:\caddy-gateway\Test-LansweeperMcp.ps1 -BaseUrl https://10.53.19.120:8088 -AllowUntrustedCertificate
```

One-line raw check:

```powershell
curl.exe -sS -H "X-Gateway-Token: $env:COHESITY_GATEWAY_TOKEN" -H "Accept: application/json, text/event-stream" -H "Content-Type: application/json" --data-binary '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' http://10.53.19.120:8081/lansweeper/mcp
```

---

## 7. Monitoring usage

Neither log contains a raw Lansweeper Windows/AD credential or a raw gateway token.

- Caddy access log: `C:\caddy-gateway\logs\access.log`
- Lansweeper MCP usage log: `C:\caddy-gateway\lansweeper-mcp\usage.jsonl`

```powershell
C:\caddy-gateway\Get-LansweeperMcpUsage.ps1
C:\caddy-gateway\Get-LansweeperMcpUsage.ps1 -SinceHours 168 -Top 50
```

Entries include `server`, `user`, `role`, `token_fp`, `client_ip`, `event`,
`tool`, and a non-reversible `key_fp` for the server-side credential.

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| HTTP 401 `A gateway token is required` | Client is not sending `X-Gateway-Token`. |
| HTTP 401 unexpanded placeholder | Restart the client after setting `COHESITY_GATEWAY_TOKEN`. |
| HTTP 403 `not authorized for Lansweeper MCP` | Token is missing from the shared ACL or was rotated. |
| HTTP 400 about client-supplied credentials | Remove Lansweeper/Cohesity/HPE key headers; send only `X-Gateway-Token`. |
| Tool says `not available to read-only users` | The tool is not on the explicit allowlist. Ask the gateway owner. |
| Tool result says login failed | Update the server-side credential with `Initialize-LansweeperSharedKey.ps1 -Force` and restart the bridge. |
| Tool result says `returned the login page` | The configured account can log in but cannot read that path, or the session expired. Try `lansweeper_discover_endpoints`. |
| `Connection refused` on `127.0.0.1:8402` | Run `Start-LansweeperBridge.ps1`. |
| Gateway returns the generic Caddy message | Reload Caddy with the `/lansweeper/*` route. |

**Security note:** HTTP `:8081` sends the gateway token in cleartext on the LAN.
Use HTTPS `:8088` wherever the client can trust the Caddy local CA.
