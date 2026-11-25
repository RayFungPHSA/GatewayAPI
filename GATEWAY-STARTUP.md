# Caddy gateway startup and restart procedure

This document explains how the native Windows Caddy gateway and all seven local
MCP bridges start after this computer is restarted.

## Current state

- The `CaddyGateway` Windows Service is configured for **Automatic (Delayed
  Start)** and runs as `PHSABC\Ray.Fung`.
- It starts at boot without anyone logged on at the console.
- The service calls `Start-CaddyGateway.ps1`, then re-runs it if the local
  gateway health check fails. On service stop it calls `Stop-CaddyGateway.ps1`.
- The manual scripts remain available and are the single source of truth:
  `Start-CaddyGateway.ps1` and `Stop-CaddyGateway.ps1`.
- The DPAPI-protected credentials remain tied to `ray.fung`. Do not change the
  service account to `SYSTEM` or another account unless you recreate every
  protected credential record.
- The only related Scheduled Task is `Caddy Gateway Usage Snapshot`, which
  rebuilds the DuckDB usage report. It is not required for the gateway to run.

## One-time service installation

From an **elevated** PowerShell window (`Run as Administrator`), run:

```powershell
& 'C:\caddy-gateway\Install-CaddyGatewayService.ps1'
```

The installer grants `PHSABC\Ray.Fung` the *Log on as a service* right and
prompts locally for that account's Windows password with masked input. The
password is stored only by the Windows Service Control Manager; it is never
written to `C:\caddy-gateway`, echoed, or placed in a plaintext file. If the
Ray.Fung password changes, re-run this installer.

To remove the service later:

```powershell
& 'C:\caddy-gateway\Uninstall-CaddyGatewayService.ps1'
```

Uninstalling the service does not remove any gateway files, logs, credentials,
or the usage snapshot task.

## Quick start after a reboot

Normally no action is needed. Verify the service and routes:

```powershell
Get-Service CaddyGateway
curl.exe http://127.0.0.1:8081/mcp/servers
curl.exe http://127.0.0.1:8081/brocade/health
```

If the service is stopped, or the gateway needs a manual restart after a crash:

```powershell
Restart-Service CaddyGateway
```

You can also run the manual scripts directly as `ray.fung`:

```powershell
& 'C:\caddy-gateway\Start-CaddyGateway.ps1'
& 'C:\caddy-gateway\Stop-CaddyGateway.ps1'
```

Alternatively, double-click `C:\caddy-gateway\Start-CaddyGateway.cmd`.

The start script starts or verifies the seven MCP bridges, validates the
`Caddyfile`, starts Caddy in the background (or reloads it if already running),
waits for the expected listeners, and checks the local token-free routes. It
appends a transcript to `C:\caddy-gateway\logs\startup.log`. The service appends
its own log to `C:\caddy-gateway\logs\service.log`.

Bridge start order does not matter. Starting them before Caddy makes the health
checks pass immediately.

### Manual equivalent

If you prefer to run the steps yourself, use:

```powershell
# 1. Start the seven local MCP bridges first
& 'C:\caddy-gateway\cohesity-mcp\Start-CohesityMcpBridge.ps1'
& 'C:\caddy-gateway\hpegreenlake-mcp\Start-HPEGreenLakeBridge.ps1'
& 'C:\caddy-gateway\lansweeper-mcp\Start-LansweeperBridge.ps1'
& 'C:\caddy-gateway\vsphere-mcp\Start-VsphereBridge.ps1'
& 'C:\caddy-gateway\3parlegacy-mcp\Start-3PARLegacyBridge.ps1'
& 'C:\caddy-gateway\hpexp8-mcp\Start-HPEXP8Bridge.ps1'
& 'C:\caddy-gateway\brocade-mcp\Start-BrocadeBridge.ps1'

# 2. Validate and start Caddy in the background
$caddy = 'C:\Users\ray.fung\AppData\Local\Microsoft\WinGet\Packages\CaddyServer.Caddy_Microsoft.Winget.Source_8wekyb3d8bbwe\caddy.exe'
& $caddy validate --config C:\caddy-gateway\Caddyfile
& $caddy start --config C:\caddy-gateway\Caddyfile
```

If PowerShell blocks the scripts, run them with an explicit execution policy:

```powershell
powershell.exe -ExecutionPolicy Bypass -File 'C:\caddy-gateway\cohesity-mcp\Start-CohesityMcpBridge.ps1'
powershell.exe -ExecutionPolicy Bypass -File 'C:\caddy-gateway\hpegreenlake-mcp\Start-HPEGreenLakeBridge.ps1'
powershell.exe -ExecutionPolicy Bypass -File 'C:\caddy-gateway\lansweeper-mcp\Start-LansweeperBridge.ps1'
powershell.exe -ExecutionPolicy Bypass -File 'C:\caddy-gateway\vsphere-mcp\Start-VsphereBridge.ps1'
powershell.exe -ExecutionPolicy Bypass -File 'C:\caddy-gateway\3parlegacy-mcp\Start-3PARLegacyBridge.ps1'
powershell.exe -ExecutionPolicy Bypass -File 'C:\caddy-gateway\hpexp8-mcp\Start-HPEXP8Bridge.ps1'
powershell.exe -ExecutionPolicy Bypass -File 'C:\caddy-gateway\brocade-mcp\Start-BrocadeBridge.ps1'
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
  Where-Object { $_.LocalPort -in @(8081,8088,8400,8401,8402,8403,8404,8405,8406,9180,2019) } |
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
curl.exe http://127.0.0.1:8081/3parlegacy/health
curl.exe http://127.0.0.1:8081/hpexp8/health
curl.exe http://127.0.0.1:8081/brocade/health
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
| `8404` | 3PARLegacy MCP bridge (JPN3PAR01 and cw3par02.phsabc.ehcnet.ca) |
| `8405` | HPEXP8 MCP bridge (XP Performance Advisor 8.5) |
| `8406` | Brocade MCP bridge (SANnav Management Portal) |
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

With your gateway token in `$env:CADDY_GATEWAY_TOKEN`:

```powershell
& 'C:\caddy-gateway\Test-CohesityMcp.ps1'
& 'C:\caddy-gateway\Test-HPEGreenLakeMcp.ps1'
& 'C:\caddy-gateway\Test-LansweeperMcp.ps1'
& 'C:\caddy-gateway\Test-VsphereMcp.ps1'
& 'C:\caddy-gateway\Test-3PARLegacyMcp.ps1'
& 'C:\caddy-gateway\Test-HPEXP8Mcp.ps1'
& 'C:\caddy-gateway\Test-BrocadeMcp.ps1'
```

Guardrail tests additionally need the admin and read-only token environment
variables described in `README.md`.

## Troubleshooting

| Symptom | Check / fix |
|---|---|
| `CaddyGateway` service is not Running | Run `Restart-Service CaddyGateway`; check `C:\caddy-gateway\logs\service.log` and `startup.log`. |
| Service fails to start with logon error | The stored Ray.Fung password is wrong or expired, or *Log on as a service* was revoked. Re-run `Install-CaddyGatewayService.ps1` elevated. |
| `Connection refused` on `8081`/`8088` | Caddy is not running. Run `Restart-Service CaddyGateway` or `Start-CaddyGateway.ps1`. |
| `caddy reload` fails after reboot | Expected. Use `caddy start` or `caddy run` first. |
| Port `8400`–`8406` missing | The corresponding bridge is not running. Run its `Start-*` script as `ray.fung`. |
| Bridge starts but logs a DPAPI/decrypt error | The script was run under the wrong Windows account. Use the account that created `C:\caddy-gateway\secrets\*.xml`. |
| `/3parlegacy/health` is OK but tools report `JPN3PAR01: timed out` | The gateway host cannot reach `142.71.40.232:443` yet. The bridge is healthy; the array firewall rule is still pending. |
| `/hpexp8/health` is OK but `spapphpxp003.fraserhealth.org` is in `failures` | TCP/80 to `10.118.212.9` is blocked or the server is down. `spapphpxp001.healthbc.org` remains usable. |
| HTTPS certificate warning | Use HTTP `:8081`, install `caddy-local-root.crt`, or use `curl.exe --ssl-no-revoke` on Windows. |
| MCP client says token placeholder is unexpanded | Set `CADDY_GATEWAY_TOKEN` in the client environment, then run `opencode service restart` or open a new terminal. |
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

If automatic startup is desired, `Start-CaddyGateway.ps1` can be used as the
action for a logon Scheduled Task, or the gateway can be converted to a Windows
service. Either mechanism must run under the same Windows account that owns the
DPAPI credential records, or the records must be recreated under that account.
