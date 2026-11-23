# Caddy gateway startup and restart procedure

This document explains how to start the native Windows Caddy gateway and all
four local MCP bridges after this computer is restarted.

## Current state

- Caddy is **not installed as a Windows service**.
- There is no logon auto-start task for Caddy or the MCP bridges.
- The only related Scheduled Task is `Caddy Gateway Usage Snapshot`, which
  rebuilds the DuckDB usage report. It is not required for the gateway to run.
- After a reboot, the gateway must be started manually.
- The DPAPI-protected credentials are tied to the Windows account that created
  them. Start the bridge scripts as the same account (`ray.fung`). Do not start
  them as `SYSTEM` or another service account unless you recreate the protected
  credential records.

## Quick start after a reboot

Open PowerShell as the normal `ray.fung` user and run:

```powershell
# 1. Start the four local MCP bridges first
& 'C:\caddy-gateway\cohesity-mcp\Start-CohesityMcpBridge.ps1'
& 'C:\caddy-gateway\hpegreenlake-mcp\Start-HPEGreenLakeBridge.ps1'
& 'C:\caddy-gateway\lansweeper-mcp\Start-LansweeperBridge.ps1'
& 'C:\caddy-gateway\vsphere-mcp\Start-VsphereBridge.ps1'

# 2. Validate and start Caddy in the background
$caddy = 'C:\Users\ray.fung\AppData\Local\Microsoft\WinGet\Packages\CaddyServer.Caddy_Microsoft.Winget.Source_8wekyb3d8bbwe\caddy.exe'
& $caddy validate --config C:\caddy-gateway\Caddyfile
& $caddy start --config C:\caddy-gateway\Caddyfile
```

Bridge start order does not matter. Starting them before Caddy makes the health
checks pass immediately.

If PowerShell blocks the scripts, run them with an explicit execution policy:

```powershell
powershell.exe -ExecutionPolicy Bypass -File 'C:\caddy-gateway\cohesity-mcp\Start-CohesityMcpBridge.ps1'
powershell.exe -ExecutionPolicy Bypass -File 'C:\caddy-gateway\hpegreenlake-mcp\Start-HPEGreenLakeBridge.ps1'
powershell.exe -ExecutionPolicy Bypass -File 'C:\caddy-gateway\lansweeper-mcp\Start-LansweeperBridge.ps1'
powershell.exe -ExecutionPolicy Bypass -File 'C:\caddy-gateway\vsphere-mcp\Start-VsphereBridge.ps1'
```

## Caddy start vs run

Use `caddy start` after a reboot. It launches Caddy as a background process and
returns control to PowerShell.

```powershell
& $caddy start --config C:\caddy-gateway\Caddyfile
```

You can also use `caddy run`, but the PowerShell window must remain open:

```powershell
& $caddy run --config C:\caddy-gateway\Caddyfile
```

Do **not** use `caddy reload` as the first command after a reboot. `reload`
requires an already-running Caddy process and admin endpoint. Use `start` (or
`run`) first.

If Caddy is already running and you only changed the `Caddyfile`, use:

```powershell
& $caddy validate --config C:\caddy-gateway\Caddyfile
& $caddy reload --config C:\caddy-gateway\Caddyfile
```

If you need a full Caddy restart on a running machine:

```powershell
& $caddy stop
& $caddy start --config C:\caddy-gateway\Caddyfile
```

## Verify the gateway

From the gateway host, confirm the listeners:

```powershell
Get-NetTCPConnection -State Listen |
  Where-Object { $_.LocalPort -in @(8081,8088,8400,8401,8402,8403,9180,2019) } |
  Select-Object LocalAddress,LocalPort,OwningProcess |
  Sort-Object LocalPort
```

Confirm the routes:

```powershell
curl.exe http://127.0.0.1:8081/todos/1
curl.exe http://127.0.0.1:8081/mcp/servers
curl.exe http://127.0.0.1:8081/cohesity/health
curl.exe http://127.0.0.1:8081/hpegreenlake/health
curl.exe http://127.0.0.1:8081/lansweeper/health
curl.exe http://127.0.0.1:8081/vsphere/health
```

Expected listening ports:

| Port | Purpose |
|---:|---|
| `8081` | HTTP gateway for remote users |
| `8088` | HTTPS gateway using the Caddy local CA |
| `8400` | Cohesity MCP bridge |
| `8401` | HPEGreenLake MCP bridge |
| `8402` | Lansweeper MCP bridge |
| `8403` | vSphere MCP bridge |
| `9180` | Loopback-only Prometheus metrics |
| `2019` | Caddy local admin API |

Remote URLs:

```text
http://10.53.19.120:8081
https://10.53.19.120:8088
```

The firewall rule for `8081`/`8088` and the Caddy local CA certificate persist
across reboots. Do not recreate them for a normal restart.

## Optional end-to-end tests

Without a gateway token:

```powershell
& 'C:\caddy-gateway\Test-CaddyGateway.ps1'
& 'C:\caddy-gateway\Test-CaddyGateway-Curl.ps1'
& 'C:\caddy-gateway\Test-VSMonitoring-Curl.ps1'
& 'C:\caddy-gateway\Test-McpDiscovery.ps1'
```

With your gateway token in `$env:COHESITY_GATEWAY_TOKEN`:

```powershell
& 'C:\caddy-gateway\Test-CohesityMcp.ps1'
& 'C:\caddy-gateway\Test-HPEGreenLakeMcp.ps1'
& 'C:\caddy-gateway\Test-LansweeperMcp.ps1'
& 'C:\caddy-gateway\Test-VsphereMcp.ps1'
```

Guardrail tests additionally need the admin and read-only token environment
variables described in `README.md`.

## Troubleshooting

| Symptom | Check / fix |
|---|---|
| `Connection refused` on `8081`/`8088` | Caddy is not running. Run `caddy start` with the `Caddyfile`. |
| `caddy reload` fails after reboot | Expected. Use `caddy start` or `caddy run` first. |
| Port `8400`–`8403` missing | The corresponding bridge is not running. Run its `Start-*` script as `ray.fung`. |
| Bridge starts but logs a DPAPI/decrypt error | The script was run under the wrong Windows account. Use the account that created `C:\caddy-gateway\secrets\*.xml`. |
| HTTPS certificate warning | Use HTTP `:8081`, install `caddy-local-root.crt`, or use `curl.exe --ssl-no-revoke` on Windows. |
| MCP client says token placeholder is unexpanded | Set `COHESITY_GATEWAY_TOKEN` in the client environment, then run `opencode service restart` or open a new terminal. |
| Gateway returns generic Caddy page for `/todos/1` | Reload Caddy with the current `Caddyfile`, then retry. |

Bridge logs:

```text
C:\caddy-gateway\cohesity-mcp\bridge.err.log
C:\caddy-gateway\hpegreenlake-mcp\bridge.err.log
C:\caddy-gateway\lansweeper-mcp\bridge.err.log
C:\caddy-gateway\vsphere-mcp\bridge.err.log
```

Caddy access log:

```text
C:\caddy-gateway\logs\access.log
```

## Future improvement

If automatic startup is desired, the gateway can be converted to a Windows
service or logon Scheduled Task. Any such service must run under the same
Windows account that owns the DPAPI credential records, or the records must be
recreated under that service account.
