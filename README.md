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
| `/mcp/servers` | Static MCP catalog used by the setup/discovery prompt |

## Tests

```powershell
.\Test-CaddyGateway.ps1
.\Test-CaddyGateway-Curl.ps1
.\Test-VSMonitoring-Curl.ps1
.\Test-McpDiscovery.ps1             # needs $env:COHESITY_GATEWAY_TOKEN
```

Cohesity MCP setup, DPAPI-protected server-side key, and per-user ACL instructions:
**[COHESITY-MCP.md](COHESITY-MCP.md)**

HPEGreenLake MCP setup. It reuses the same gateway token/ACL and keeps the
GreenLake credential server-side in a DPAPI-protected record:
**[HPEGREENLAKE-MCP.md](HPEGREENLAKE-MCP.md)**

Lansweeper Classic MCP setup. It reuses the same gateway token/ACL and keeps the
Windows/AD credential server-side in a DPAPI-protected record:
**[LANSWEEPER-MCP.md](LANSWEEPER-MCP.md)**

VMware vSphere/vCenter MCP setup. It reuses the same gateway token/ACL and keeps
the domain credential server-side in DPAPI-protected files:
**[VSPHERE-MCP.md](VSPHERE-MCP.md)**

User-facing setup guide to share with remote users:
**[GATEWAY-USER-SETUP.md](GATEWAY-USER-SETUP.md)**

Single consolidated setup/discovery prompt for new and returning users. The
user sets `COHESITY_GATEWAY_TOKEN` locally first; the AI harness never sees or
handles the token value. It reads the MCP catalog at `/mcp/servers`, so it does
not need editing when new MCP servers are added:
**[GATEWAY-ONE-PROMPT-WITH-TOKEN.md](GATEWAY-ONE-PROMPT-WITH-TOKEN.md)**

MCP catalog endpoint (no auth): `http://10.53.19.120:8081/mcp/servers`, backed by
[`mcp-servers.json`](mcp-servers.json).

MCP tests (after setting `$env:COHESITY_GATEWAY_TOKEN` to your issued token):

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
.\Test-GatewayDpapiCredentialStore.ps1  # no token required
```

## Server-side secrets

Upstream credentials are not accepted from clients and are not in the
Caddyfile. All four MCPs now use the same DPAPI-backed pattern: the bridge calls
a restricted local PowerShell helper, which decrypts a Windows-DPAPI-protected
`PSCredential` record and emits one JSON line only to the local bridge process.

```text
C:\caddy-gateway\secrets\cohesity-gateway.xml
C:\caddy-gateway\secrets\hpegreenlake-gateway.xml
C:\caddy-gateway\secrets\lansweeper-gateway.xml
C:\caddy-gateway\secrets\vsphere.xml
C:\caddy-gateway\secrets\vsphere-server.txt
C:\caddy-gateway\secrets\vsphere-ca.pem
```

There are no plain-text `*-gateway.env` credential files. `vsphere-server.txt`
contains only vCenter URLs, and `vsphere-ca.pem` is the public internal CA
bundle.

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

Then open `http://127.0.0.1:8501`. It has date, endpoint and user filters,
daily MCP charts, and per-user/per-MCP tables. It is bound to loopback only;
do not expose it publicly without adding authentication. Use `-Port` to change
the port.

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
