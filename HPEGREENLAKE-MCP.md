# HPEGreenLake MCP through the Caddy gateway

The HPE GreenLake Fleet MCP server from
`C:\Code\CStorageDashboard\mcp-configs\hpe-fleet` has been copied to
`C:\caddy-gateway\hpegreenlake-mcp` and exposed through a local HTTP bridge on
`127.0.0.1:8401`. Caddy proxies `/hpegreenlake/*` to that bridge on both gateway
listeners.

This server uses the **same gateway token and named-user ACL as Cohesity**. A
user who can call `/cohesity/mcp` can also call `/hpegreenlake/mcp` with the
same `X-Gateway-Token` header and the same `admin`/`read-only` role.

The HPE GreenLake OAuth client credential is **server-side only**. It is not
accepted from clients and is not stored in the Caddyfile, client configs, the
copied MCP folder, or logs.

```
MCP client (X-Gateway-Token only)
        |
        v
Caddy :8081 / :8088  /hpegreenlake/mcp
        |
        v
HPEGreenLake HTTP bridge 127.0.0.1:8401
   - validates token against the shared ACL
   - injects the server-side GreenLake credential
        |
        v
short-lived Node stdio process (src/server.mjs)
        |
        v
HPE GreenLake Storage Fleet API
```

## Gateway URLs

| Use | URL |
|---|---|
| HTTP (no cert/admin needed) | `http://10.53.19.120:8081/hpegreenlake/mcp` |
| HTTPS (local Caddy CA) | `https://10.53.19.120:8088/hpegreenlake/mcp` |
| Bridge health (no auth) | `http://10.53.19.120:8081/hpegreenlake/health` |

Header on **every** MCP request (initialize, tools/list, tools/call):

```text
X-Gateway-Token: <your existing gateway token>
```

Do **not** send `X-GreenLake-Api-Key`, `X-HPE-Api-Key`, `X-Api-Key`,
`X-Client-Secret`, `X-Cohesity-API-Key`, `X-Helios-API-Key`, or
`Authorization: Bearer`. The bridge rejects client-supplied upstream
credentials with HTTP 400.

---

## 1. Gateway owner: configure the server-side credential

The existing GreenLake client credential from the CStorageDashboard project is
reused. Create the server-only protected record once:

```powershell
C:\caddy-gateway\hpegreenlake-mcp\Initialize-HPEGreenLakeSharedKey.ps1
```

This reads approved variable names from
`C:\Code\CStorageDashboard\mcp-configs\hpe-fleet\.env` and writes only to:

```text
C:\caddy-gateway\secrets\hpegreenlake-gateway.xml
```

A raw copy of the source `.env` is never made. The values are wrapped in a
`PSCredential` and protected with Windows DPAPI for the current Windows account.
The destination file is NTFS-restricted to the current user, SYSTEM, and
Administrators. Values are not displayed and no plain-text env file is created.

If the source credential changes later, re-import it:

```powershell
C:\caddy-gateway\hpegreenlake-mcp\Initialize-HPEGreenLakeSharedKey.ps1 -Force
C:\caddy-gateway\hpegreenlake-mcp\Stop-HPEGreenLakeBridge.ps1
C:\caddy-gateway\hpegreenlake-mcp\Start-HPEGreenLakeBridge.ps1
```

To rotate just the client secret locally (and the password-grant password when
`AUTH_METHOD=password`), enter it when prompted:

```powershell
C:\caddy-gateway\hpegreenlake-mcp\Set-HPEGreenLakeGatewayCredential.ps1
C:\caddy-gateway\hpegreenlake-mcp\Stop-HPEGreenLakeBridge.ps1
C:\caddy-gateway\hpegreenlake-mcp\Start-HPEGreenLakeBridge.ps1
```

> DPAPI is tied to the Windows account that created the record. Run setup and
> `Start-HPEGreenLakeBridge.ps1` under the same account.

---

## 2. Gateway owner: tokens and roles

No second token list is needed. HPEGreenLake reads the existing ACL:

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

ACL changes take effect on the next request for both bridges.

### Read-only guardrails

Every current HPEGreenLake tool is read-only:

- `greenlake_connection_status`
- `greenlake_auth_status`
- `greenlake_list_storage_systems`
- `greenlake_capacity_summary`
- `greenlake_list_ports`
- `greenlake_port_summary`

Read-only users see and can call all of them. There are no admin-only
HPEGreenLake tools today. If a future upstream tool is mutating, it remains
hidden from `tools/list` and denied by `tools/call` until it is added to the
explicit read-only allowlist in `http_bridge.py`.

The bridge also enforces `readOnlyHint: true` and `destructiveHint: false` on
every tool it advertises to read-only users.

---

## 3. Gateway owner: start the bridge

```powershell
C:\caddy-gateway\hpegreenlake-mcp\Start-HPEGreenLakeBridge.ps1
```

Expected:

```text
HPEGreenLake MCP bridge started on http://127.0.0.1:8401/mcp (PID 6012).
Auth: shared gateway-token ACL; ACL users: 15
Logs: C:\caddy-gateway\hpegreenlake-mcp\bridge.log
Errors: C:\caddy-gateway\hpegreenlake-mcp\bridge.err.log
```

Stop it with:

```powershell
C:\caddy-gateway\hpegreenlake-mcp\Stop-HPEGreenLakeBridge.ps1
```

Caddy was already reloaded with the `/hpegreenlake/*` route. If you rebuild the
Caddyfile:

```powershell
caddy validate --config C:\caddy-gateway\Caddyfile
caddy reload --config C:\caddy-gateway\Caddyfile
```

---

## 4. Each user: configure your MCP client

Reuse the same `COHESITY_GATEWAY_TOKEN` environment variable. Add a second MCP
server entry named `hpegreenlake`; keep the existing `cohesity` entry.

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
        "headers": {
          "X-Gateway-Token": "{env:COHESITY_GATEWAY_TOKEN}"
        }
      },
      "hpegreenlake": {
        "type": "remote",
        "url": "http://10.53.19.120:8081/hpegreenlake/mcp",
        "oauth": false,
        "headers": {
          "X-Gateway-Token": "{env:COHESITY_GATEWAY_TOKEN}"
        }
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
    "cohesity": {
      "type": "remote",
      "url": "http://10.53.19.120:8081/cohesity/mcp",
      "enabled": true,
      "headers": {
        "X-Gateway-Token": "{env:COHESITY_GATEWAY_TOKEN}"
      }
    },
    "hpegreenlake": {
      "type": "remote",
      "url": "http://10.53.19.120:8081/hpegreenlake/mcp",
      "enabled": true,
      "headers": {
        "X-Gateway-Token": "{env:COHESITY_GATEWAY_TOKEN}"
      }
    }
  }
}
```

### Claude Code / Claude Desktop

```json
{
  "mcpServers": {
    "cohesity": {
      "type": "http",
      "url": "http://10.53.19.120:8081/cohesity/mcp",
      "headers": {
        "X-Gateway-Token": "${COHESITY_GATEWAY_TOKEN}"
      }
    },
    "hpegreenlake": {
      "type": "http",
      "url": "http://10.53.19.120:8081/hpegreenlake/mcp",
      "headers": {
        "X-Gateway-Token": "${COHESITY_GATEWAY_TOKEN}"
      }
    }
  }
}
```

Use HTTPS URLs instead if your client trusts the Caddy local CA.

---

## 5. Test the endpoint

Set the token for the current session:

```powershell
$env:COHESITY_GATEWAY_TOKEN = '<your gateway token>'
```

Then run:

```powershell
C:\caddy-gateway\Test-HPEGreenLakeMcp.ps1
C:\caddy-gateway\Test-HPEGreenLakeMcp-Curl.ps1
```

Expected: 6 passed / 0 failed and 7 passed / 0 failed.

Guardrail verification (uses one admin and one read-only token):

```powershell
$env:COHESITY_GATEWAY_ADMIN_TOKEN = '<ray.fung token>'
$env:COHESITY_GATEWAY_READONLY_TOKEN = '<a read-only user token>'
C:\caddy-gateway\Test-HPEGreenLakeMcpGuardrails.ps1
```

Expected: 6 passed / 0 failed.

HTTPS variants:

```powershell
C:\caddy-gateway\Test-HPEGreenLakeMcp-Curl.ps1 -BaseUrl https://10.53.19.120:8088 -CurlArgs '--ssl-no-revoke'
C:\caddy-gateway\Test-HPEGreenLakeMcp.ps1 -BaseUrl https://10.53.19.120:8088 -AllowUntrustedCertificate
```

One-line raw check:

```powershell
curl.exe -sS -H "X-Gateway-Token: $env:COHESITY_GATEWAY_TOKEN" -H "Accept: application/json, text/event-stream" -H "Content-Type: application/json" --data-binary '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' http://10.53.19.120:8081/hpegreenlake/mcp
```

---

## 6. Monitoring usage

Neither log contains a raw GreenLake credential or a raw gateway token.

- Caddy access log: `C:\caddy-gateway\logs\access.log`
- HPEGreenLake MCP usage log: `C:\caddy-gateway\hpegreenlake-mcp\usage.jsonl`

```powershell
C:\caddy-gateway\Get-HPEGreenLakeMcpUsage.ps1
C:\caddy-gateway\Get-HPEGreenLakeMcpUsage.ps1 -SinceHours 168 -Top 50
```

Entries include `server`, `user`, `role`, `token_fp`, `client_ip`, `event`,
`tool`, and a non-reversible `key_fp` for the server-side client secret.

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| HTTP 401 `A gateway token is required` | Client is not sending `X-Gateway-Token`. |
| HTTP 401 unexpanded placeholder | Restart the client after setting `COHESITY_GATEWAY_TOKEN`. |
| HTTP 403 `not authorized for HPEGreenLake MCP` | Token is missing from the shared ACL or was rotated. |
| HTTP 400 about client-supplied keys | Remove GreenLake/HPE/Cohesity key headers; send only `X-Gateway-Token`. |
| Tool says `not available to read-only users` | The tool is not on the explicit allowlist. Ask the gateway owner. |
| Tool result says GreenLake authentication failed | Update the server-side credential with `Initialize-HPEGreenLakeSharedKey.ps1 -Force` and restart the bridge. |
| `Connection refused` on `127.0.0.1:8401` | Run `Start-HPEGreenLakeBridge.ps1`. |
| Gateway returns the generic Caddy message | Reload Caddy with the `/hpegreenlake/*` route. |

**Security note:** HTTP `:8081` sends the gateway token in cleartext on the LAN.
Use HTTPS `:8088` wherever the client can trust the Caddy local CA.
