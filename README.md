# Caddy API gateway (native Windows)

Gateway host: `10.53.19.120`

| Listener | Base URL | Notes |
|---|---|---|
| HTTP | `http://10.53.19.120:8081` | No certificate/admin rights needed |
| HTTPS | `https://10.53.19.120:8088` | Caddy local CA; install `caddy-local-root.crt` or use `--ssl-no-revoke` with curl.exe |

## Routes

| Path | Upstream |
|---|---|
| `/todos/*` | `https://jsonplaceholder.typicode.com/todos/*` |
| `/httpbin/*` | `https://httpbin.org/*` |
| `/vsmonitoring/*` | `https://vsmonitoring.healthbc.org/*` |
| `/cohesity/*` | Local Cohesity MCP bridge on `127.0.0.1:8400` |
| `/hpegreenlake/*` | Local HPEGreenLake MCP bridge on `127.0.0.1:8401` |
| `/lansweeper/*` | Local Lansweeper Classic MCP bridge on `127.0.0.1:8402` |
| `/vsphere/*` | Local VMware vSphere/vCenter MCP bridge on `127.0.0.1:8403` |
| `/3parlegacy/*` | Local legacy HPE 3PAR MCP bridge on `127.0.0.1:8404` (`JPN3PAR01`, `cw3par02.phsabc.ehcnet.ca`) |
| `/hpexp8/*` | Local HPE XP Performance Advisor 8.5 MCP bridge on `127.0.0.1:8405` |
| `/brocade/*` | Local Brocade SANnav MCP bridge on `127.0.0.1:8406` |
| `/mcp/servers` | Static MCP catalog used by the setup/discovery prompt |

## Windows service

The gateway is a Windows Service named `CaddyGateway`, configured for Automatic
(Delayed Start) and running as `PHSABC\Ray.Fung`. It starts at boot without an
interactive logon, calls `Start-CaddyGateway.ps1`, and re-runs startup if the
local health check fails. It calls `Stop-CaddyGateway.ps1` when stopped.

One-time installation must be run from an elevated PowerShell prompt:

```powershell
.\Install-CaddyGatewayService.ps1
```

It prompts locally for the Ray.Fung Windows password with masked input and lets
Windows store it for the service. No password is written to a project file. If
the password changes, re-run the installer. Removal:

```powershell
.\Uninstall-CaddyGatewayService.ps1
```

The manual scripts remain available for crash recovery or maintenance:

```powershell
.\Start-CaddyGateway.ps1
.\Stop-CaddyGateway.ps1
```

Logs: `logs\service.log`, `logs\startup.log`, and `logs\shutdown.log`.

## Tests

Run the full suite through the dedicated test runner. It uses Ray's admin token
and the `gateway-test@phsa.ca` read-only token from the restricted distribution
file, so no real user's key is attributed to automated tests.

```powershell
.\Run-GatewayTests.ps1
```

Individual scripts still work, but require the canonical environment variables:

```powershell
$env:CADDY_GATEWAY_TOKEN = '<admin token>'
$env:CADDY_GATEWAY_READONLY_TOKEN = '<gateway-test@phsa.ca token>'
.\Test-McpDiscovery.ps1
```

Cohesity MCP setup, DPAPI-protected server-side key, and per-user ACL instructions:
**[COHESITY-MCP.md](COHESITY-MCP.md)**

HPEGreenLake MCP setup. It reuses the same gateway token/ACL and keeps the
GreenLake credential server-side in a DPAPI-protected record. It exposes all
130 `GET` operations from the official HPE Storage Fleet API 1.4.0 as read-only
tools:
**[HPEGREENLAKE-MCP.md](HPEGREENLAKE-MCP.md)**

Lansweeper Classic MCP setup. It reuses the same gateway token/ACL and keeps the
Windows/AD credential server-side in a DPAPI-protected record:
**[LANSWEEPER-MCP.md](LANSWEEPER-MCP.md)**

VMware vSphere/vCenter MCP setup. It reuses the same gateway token/ACL and keeps
the domain credential server-side in DPAPI-protected files:
**[VSPHERE-MCP.md](VSPHERE-MCP.md)**

Legacy HPE 3PAR WSAPI MCP setup. It covers `JPN3PAR01` and
`cw3par02.phsabc.ehcnet.ca`, reuses the same gateway token/ACL, and keeps the
WSAPI credential server-side in a DPAPI-protected file. Each array's reachability
is reported per-array in tool results:
**[3PARLEGACY-MCP.md](3PARLEGACY-MCP.md)**

HPE XP Performance Advisor 8.5 MCP setup. It reuses the same gateway token/ACL
and keeps the XP credential server-side in a DPAPI-protected record. Both base
URLs are queried by default with per-server attribution; `spapphpxp003` is
firewall-pending:
**[HPEXP8-MCP.md](HPEXP8-MCP.md)**

Brocade SANnav read-only MCP setup. It reuses the same gateway token/ACL, and
the SANnav credential was imported from the old project's plaintext `.env` into
a DPAPI-protected record. No plaintext file was copied into this gateway:
**[BROCADE-MCP.md](BROCADE-MCP.md)**

Vendor API coverage review for all seven MCPs, including read-only-user
enforcement and the official documentation used:
**[VENDOR-API-COVERAGE.md](VENDOR-API-COVERAGE.md)**

Short team overview and example prompts:
**[GATEWAY-TEAM-OVERVIEW.md](GATEWAY-TEAM-OVERVIEW.md)**

User-facing setup guide to share with remote users:
**[GATEWAY-USER-SETUP.md](GATEWAY-USER-SETUP.md)**

Single consolidated setup/discovery prompt for new and returning users. The
user sets `CADDY_GATEWAY_TOKEN` locally first; the AI harness never sees or
handles the token value. It reads the MCP catalog at `/mcp/servers`, so it does
not need editing when new MCP servers are added:
**[GATEWAY-ONE-PROMPT.md](GATEWAY-ONE-PROMPT.md)**

Gateway token variable naming, migration, and rollback:
**[GATEWAY-TOKEN-VARIABLE.md](GATEWAY-TOKEN-VARIABLE.md)**

MCP catalog endpoint (no auth): `http://10.53.19.120:8081/mcp/servers`, backed by
[`mcp-servers.json`](mcp-servers.json).

MCP tests (after setting `$env:CADDY_GATEWAY_TOKEN` to your issued token):

```powershell
.\Test-CohesityMcp.ps1
.\Test-CohesityMcp-Curl.ps1
.\Test-CohesityMcpGuardrails.ps1   # needs admin + read-only tokens
.\Test-HPEGreenLakeMcp.ps1
.\Test-HPEGreenLakeMcp-Curl.ps1
.\Test-HPEGreenLakeMcpGuardrails.ps1
.\Test-LansweeperMcp.ps1
.\Test-LansweeperMcp-Curl.ps1
.\Test-LansweeperMcpGuardrails.ps1
.\Test-VsphereMcp.ps1
.\Test-VsphereMcp-Curl.ps1
.\Test-VsphereMcpGuardrails.ps1
.\Test-3PARLegacyMcp.ps1
.\Test-3PARLegacyMcpGuardrails.ps1
.\Test-HPEXP8Mcp.ps1
.\Test-HPEXP8McpGuardrails.ps1
.\Test-BrocadeMcp.ps1
.\Test-BrocadeMcpGuardrails.ps1
.\Test-GatewayDpapiCredentialStore.ps1  # no token required
```

## Server-side secrets

Upstream credentials are not accepted from clients and are not in the
Caddyfile. All seven MCPs now use the same DPAPI-backed pattern: the bridge calls
a restricted local PowerShell helper, which decrypts a Windows-DPAPI-protected
`PSCredential` record and emits one JSON line only to the local bridge process.

```text
C:\caddy-gateway\secrets\cohesity-gateway.xml
C:\caddy-gateway\secrets\hpegreenlake-gateway.xml
C:\caddy-gateway\secrets\lansweeper-gateway.xml
C:\caddy-gateway\secrets\vsphere.xml
C:\caddy-gateway\secrets\vsphere-server.txt
C:\caddy-gateway\secrets\vsphere-ca.pem
C:\caddy-gateway\secrets\3parlegacy.xml
C:\caddy-gateway\secrets\3parlegacy-servers.json
C:\caddy-gateway\secrets\hpexp8.xml
C:\caddy-gateway\secrets\hpexp8-servers.json
C:\caddy-gateway\secrets\brocade.xml
C:\caddy-gateway\secrets\brocade-servers.json
```

There are no plain-text `*-gateway.env` credential files. `vsphere-server.txt`
contains only vCenter URLs, `vsphere-ca.pem` is the public internal CA bundle,
`3parlegacy-servers.json` contains only the two 3PAR array names and URLs, and
`hpexp8-servers.json` contains only the two XP Performance Advisor base URLs,
and `brocade-servers.json` contains only the SANnav host and port.

DPAPI is tied to the Windows account that created the record. Setup scripts and
bridge start scripts must run under the same account. All secret files and the
`secrets` directory are NTFS-restricted to the current user, SYSTEM, and
Administrators.

Rotate a credential with:

```powershell
.\cohesity-mcp\Set-CohesityGatewayCredential.ps1
.\hpegreenlake-mcp\Set-HPEGreenLakeGatewayCredential.ps1
.\lansweeper-mcp\Set-LansweeperGatewayCredential.ps1
.\vsphere-mcp\Set-VsphereGatewayCredential.ps1
.\3parlegacy-mcp\Set-3PARLegacyGatewayCredential.ps1  # prompts for the metrics password
.\hpexp8-mcp\Set-HPEXP8GatewayCredential.ps1          # imports old DPAPI record; -PromptPassword rotates
.\brocade-mcp\Set-BrocadeGatewayCredential.ps1        # imports old .env locally; -PromptPassword rotates
```

For initial import from the source CStorageDashboard project only:

```powershell
.\cohesity-mcp\Initialize-CohesitySharedKey.ps1 -Force
.\hpegreenlake-mcp\Initialize-HPEGreenLakeSharedKey.ps1 -Force
.\lansweeper-mcp\Initialize-LansweeperSharedKey.ps1 -Force
.\vsphere-mcp\Initialize-VsphereSharedKey.ps1 -Force
```

After any credential change, stop and restart that MCP's bridge.

All MCP servers reuse one named-user ACL (token fingerprints, not raw
tokens):

```text
C:\caddy-gateway\secrets\cohesity-gateway-acl.json
```

```powershell
.\cohesity-mcp\Initialize-CohesityGatewayAcl.ps1
.\cohesity-mcp\New-CohesityGatewayToken.ps1 -Name 'alice@example.com' -Role read-only
.\cohesity-mcp\Set-CohesityGatewayRole.ps1 -Name 'alice@example.com' -Role admin
.\cohesity-mcp\Get-CohesityGatewayAcl.ps1
.\cohesity-mcp\Remove-CohesityGatewayToken.ps1 -Name 'alice@example.com'
```

## Usage monitoring

```powershell
.\Get-GatewayUsage.ps1            # Caddy access log: requests by IP/path
.\Get-GatewayUsageDuckDB.ps1      # DuckDB: per-MCP, per-token, daily trends
.\Update-GatewayUsageSnapshot.ps1 # Refresh the dashboard's DuckDB snapshot now
.\Refresh-GatewayUsageDashboard.ps1 # Snapshot + restart dashboard immediately
.\Get-CohesityMcpUsage.ps1        # Cohesity MCP: users, tokens, tools
.\Get-HPEGreenLakeMcpUsage.ps1    # HPEGreenLake MCP: users, tokens, tools
.\Get-LansweeperMcpUsage.ps1      # Lansweeper MCP: users, tokens, tools
.\Get-VsphereMcpUsage.ps1         # vSphere MCP: users, tokens, tools
```

`Get-GatewayUsageDuckDB.ps1` needs Python 3 and DuckDB
(`python -m pip install duckdb`). It excludes localhost health checks and
scanner probes from usage counts, and accepts `-Days`, `-Top`, `-CsvPath`,
`-AclPath` and `-IncludeHealthChecks`.

Token hashes in the Caddy log are matched against `secrets\cohesity-gateway-acl.json`
by fingerprint prefix, so the report shows real user names and roles. Hashes
not in the ACL (test tokens, for example) are shown as `(unmapped)`.

Web dashboard (install once with `python -m pip install streamlit`):

```powershell
.\Start-GatewayUsageDashboard.ps1
```

Then open `http://127.0.0.1:8501`. The main page has date, endpoint and user filters,
and the **Live Status** page shows token-free health checks for the gateway,
all seven MCP health endpoints (via gateway and loopback), VS Monitoring/httpbin/todos routes,
CaddyGateway service, usage snapshot task, and Prometheus metrics.
hourly/daily MCP charts (hourly by default via **Chart granularity**), and
per-user/per-MCP tables. Times use `America/Vancouver`
(permanent BC Pacific Time, UTC-07:00); tick **Show UTC instead** in the
sidebar to switch back to UTC. Daily charts are grouped by local calendar day.
The IANA database currently labels this offset `MST`; BC calls it `PCT`. Set
`GATEWAY_DISPLAY_TZ` to override the zone. It is bound to loopback only; do not
expose it publicly without adding authentication. Use `-Port` to change the
port.

### Hourly DuckDB snapshot

The dashboard reads `analytics\usage.duckdb` so history survives Caddy log
rotation. Task Scheduler runs `Caddy Gateway Usage Snapshot` at 5 minutes past
each hour; it merges any new `logs\access*.log` rows into the snapshot and writes
`analytics\snapshot.log`. The import is incremental and skips event IDs already
stored, so re-runs are safe.

Check it with:

```powershell
Get-ScheduledTask -TaskName 'Caddy Gateway Usage Snapshot' | Select-Object TaskName, State
Get-ScheduledTaskInfo -TaskName 'Caddy Gateway Usage Snapshot' | Select-Object LastRunTime, LastTaskResult, NextRunTime
Get-Content 'C:\caddy-gateway\analytics\snapshot.log' -Tail 20
```

The task runs as `SYSTEM` with highest privileges, so it continues when no user
is logged on. DuckDB is installed in `.pythonlibs\` and added to `PYTHONPATH` by
the wrapper, because the interactive user's per-user Python packages are not
visible to SYSTEM.

Prometheus metrics for gateway health are enabled in `Caddyfile` (they have no
per-path or per-caller labels):

```text
http://127.0.0.1:9180/metrics    # loopback-only, read-only
http://localhost:2019/metrics    # admin API
```

Logs:

- `C:\caddy-gateway\logs\access.log`
- `C:\caddy-gateway\cohesity-mcp\usage.jsonl`
- `C:\caddy-gateway\hpegreenlake-mcp\usage.jsonl`
- `C:\caddy-gateway\lansweeper-mcp\usage.jsonl`
- `C:\caddy-gateway\vsphere-mcp\usage.jsonl`

Raw keys and raw gateway tokens are never logged; credential headers are
hashed in the Caddy access log.

## Caddy management

Startup and restart procedure after a computer reboot:
**[GATEWAY-STARTUP.md](GATEWAY-STARTUP.md)**

One-command startup after a reboot (starts the four MCP bridges, validates the
`Caddyfile`, then starts or reloads Caddy):

```powershell
& 'C:\caddy-gateway\Start-CaddyGateway.ps1'
```

Or double-click `C:\caddy-gateway\Start-CaddyGateway.cmd`. The script logs to
`C:\caddy-gateway\logs\startup.log`.

```powershell
caddy validate --config C:\caddy-gateway\Caddyfile
caddy reload --config C:\caddy-gateway\Caddyfile
caddy stop
```

On this host, the current shell may need the full path:

```powershell
& 'C:\Users\ray.fung\AppData\Local\Microsoft\WinGet\Packages\CaddyServer.Caddy_Microsoft.Winget.Source_8wekyb3d8bbwe\caddy.exe' reload --config C:\caddy-gateway\Caddyfile
```

## Firewall

If remote machines cannot connect:

```powershell
New-NetFirewallRule -DisplayName 'Caddy Gateway 8081/8088' -Direction Inbound -LocalPort 8081,8088 -Protocol TCP -Action Allow -Profile Any
```
