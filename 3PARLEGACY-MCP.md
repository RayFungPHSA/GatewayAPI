# 3PARLegacy MCP

`3PARLegacy` is a read-only MCP for the legacy HPE 3PAR arrays:

| Array | WSAPI URL | Status |
|---|---|---|
| `JPN3PAR01` | `https://142.71.40.232` | TCP/443 firewall-pending |
| `cw3par02.phsabc.ehcnet.ca` | `https://cw3par02.phsabc.ehcnet.ca:8080` | Online — HP_3PAR 7400, WSAPI 3.2.2.709 |

It is intentionally **not** registered for `CWALLETRA01` or `SMHALLETRA01`;
those arrays are available through the HPEGreenLake MCP.

> Current network state: `cw3par02.phsabc.ehcnet.ca` is reachable and
> authenticated on HTTPS/8080. `JPN3PAR01` can be pinged, but TCP/443 times out
> while its firewall rule is pending. Calls return `configuredArrays: 2`,
> `onlineArrays: 1`, with a structured `JPN3PAR01: timed out` failure.

## Endpoints

| Listener | MCP endpoint | Health |
|---|---|---|
| HTTP | `http://10.53.19.120:8081/3parlegacy/mcp` | `http://10.53.19.120:8081/3parlegacy/health` |
| HTTPS | `https://10.53.19.120:8088/3parlegacy/mcp` | `https://10.53.19.120:8088/3parlegacy/health` |

Clients authenticate only with the shared gateway token:

```text
X-Gateway-Token: <token issued to the user>
```

The username `metrics` and its password are server-side only. Client-supplied
3PAR username/password/session-key headers are rejected with HTTP 400, and
gateway tokens are mapped to names/roles through the shared ACL at
`C:\caddy-gateway\secrets\cohesity-gateway-acl.json`.

## Server-side credential setup

Run this locally on the gateway host as `ray.fung` (the account that starts the
bridge):

```powershell
& 'C:\caddy-gateway\3parlegacy-mcp\Set-3PARLegacyGatewayCredential.ps1'
```

The script:

- defaults the username to `metrics`,
- prompts for the password with `Read-Host -AsSecureString` (masked),
- writes `C:\caddy-gateway\secrets\3parlegacy.xml` (Windows DPAPI),
- writes `C:\caddy-gateway\secrets\3parlegacy-servers.json` with `JPN3PAR01`
  and `cw3par02.phsabc.ehcnet.ca` (HTTPS/8080),
- restricts both files to the current user, SYSTEM, and Administrators.

**Never paste the password into chat, a client config, a prompt, or a
`*.env` file.** DPAPI records are account-bound; setup and start scripts must
run under the same Windows account.

## Start / stop the bridge

```powershell
& 'C:\caddy-gateway\3parlegacy-mcp\Start-3PARLegacyBridge.ps1'
& 'C:\caddy-gateway\3parlegacy-mcp\Stop-3PARLegacyBridge.ps1'
```

The bridge listens on `127.0.0.1:8404` only. Caddy exposes it through
`/3parlegacy/*`. After a reboot, use
`C:\caddy-gateway\Start-CaddyGateway.ps1` to start all five bridges and Caddy.

## Tools

All tools are read-only (`readOnlyHint: true`, `destructiveHint: false`) and
accept an optional `array` argument. Omitting it queries both configured arrays;
pass `array: "JPN3PAR01"` or `array: "cw3par02.phsabc.ehcnet.ca"` to target one.

| Tool | Upstream GET |
|---|---|
| `threepar_connection_status` | `/api/v1/system` |
| `threepar_inventory_summary` | `/api/v1/cpgs`, `/volumes`, `/volumesets`, `/hosts`, `/hostsets`, `/ports` |
| `threepar_list_cpgs` | `/api/v1/cpgs` |
| `threepar_list_volumes` | `/api/v1/volumes` |
| `threepar_list_volume_sets` | `/api/v1/volumesets` |
| `threepar_list_hosts` | `/api/v1/hosts` |
| `threepar_list_host_sets` | `/api/v1/hostsets` |
| `threepar_list_ports` | `/api/v1/ports` |
| `threepar_list_users` | `/api/v1/users` |
| `threepar_capacity_summary` | `/api/v1/capacity` |

The bridge authenticates per array with the official WSAPI
`POST /api/v1/credentials` call, reuses the returned session key in the
`X-HP3PAR-WSAPI-SessionKey` header, and exposes no mutating operation. If an
array reports `invalid session key`, the cached key is discarded and one fresh
authentication is attempted before the failure is returned. Session keys and
passwords are redacted from errors and usage logs.

The array certificate chains are currently untrusted by Windows, so the bridge
disables certificate verification only for the configured HTTPS array URLs.
Client-supplied URLs and credentials are never accepted, so a remote caller
cannot use this as a general proxy. Prefer installing/pinning the array CA when
it becomes available.

## Validation

```powershell
& 'C:\caddy-gateway\Test-3PARLegacyMcp.ps1'
& 'C:\caddy-gateway\Test-3PARLegacyMcpGuardrails.ps1'
```

The main test asserts the catalog/route, tool annotations, DPAPI health, both
array names, and structured per-array results. The guardrail test asserts that
missing tokens, unknown tokens, and client-supplied upstream credentials are
denied.

While `JPN3PAR01` is firewall-pending, expect `onlineArrays: 1` with
`cw3par02.phsabc.ehcnet.ca` online and `JPN3PAR01` in `failures`. After the
firewall is opened, confirm `onlineArrays: 2`.
