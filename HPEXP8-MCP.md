# HPEXP8 MCP

`HPEXP8` is a read-only MCP for HPE XP Performance Advisor 8.5. It was built
from the project-local `CStorageDashboard\mcp-configs\hpe-xppa` server, but runs
as a gateway HTTP bridge with the shared gateway-token ACL.

## Base URL reachability

| Server | Base URL | TCP/80 | Result |
|---|---|---|---|
| `spapphpxp001.healthbc.org` | `http://spapphpxp001.healthbc.org/pa` | Open | HTTP 200; login and arrayfilter APIs respond |
| `spapphpxp003.fraserhealth.org` | `http://spapphpxp003.fraserhealth.org/pa` | Blocked/timeout | No HTTP response; firewall or host issue pending |

`spapphpxp001.healthbc.org` resolves to `10.254.23.125`;
`spapphpxp003.fraserhealth.org` resolves to `10.118.212.9`. Port 443 is not
listening on either host. The XP PA application is mounted under `/pa`; the
root URL redirects there.

Authenticated live check on `spapphpxp001`:

- `POST /pa/api/auth/login` succeeds and returns a session ID.
- `/pa/api/index/arrayfilter` returns one XP array: `KDCXP01`.
- Dashboard, capacity, database summary, and event-history GETs succeed.

## Endpoints

| Listener | MCP endpoint | Health |
|---|---|---|
| HTTP | `http://10.53.19.120:8081/hpexp8/mcp` | `http://10.53.19.120:8081/hpexp8/health` |
| HTTPS | `https://10.53.19.120:8088/hpexp8/mcp` | `https://10.53.19.120:8088/hpexp8/health` |

Clients authenticate only with the shared gateway token:

```text
X-Gateway-Token: <token issued to the user>
```

Client-supplied XP username/password/session headers are rejected with HTTP 400.

## Server-side credential setup

The existing protected credential from the old MCP was imported into the
gateway secrets store:

```powershell
& 'C:\caddy-gateway\hpexp8-mcp\Set-HPEXP8GatewayCredential.ps1'
```

To rotate the password locally without pasting it into chat:

```powershell
& 'C:\caddy-gateway\hpexp8-mcp\Set-HPEXP8GatewayCredential.ps1 -PromptPassword -Username administrator
```

The script writes:

```text
C:\caddy-gateway\secrets\hpexp8.xml
C:\caddy-gateway\secrets\hpexp8-servers.json
```

Both are NTFS-restricted to the current user, SYSTEM, and Administrators. DPAPI
is account-bound, so setup and bridge start scripts must run as the same Windows
account (`ray.fung`).

## Start / stop the bridge

```powershell
& 'C:\caddy-gateway\hpexp8-mcp\Start-HPEXP8Bridge.ps1'
& 'C:\caddy-gateway\hpexp8-mcp\Stop-HPEXP8Bridge.ps1'
```

The bridge listens on `127.0.0.1:8405` only. `Start-CaddyGateway.ps1` starts or
verifies it along with the other five bridges.

## Tools

All tools are read-only (`readOnlyHint: true`, `destructiveHint: false`):

| Tool | Purpose |
|---|---|
| `xppa_connection_status` | HTTP reachability of both servers |
| `xppa_auth_status` | Login check and authorization availability |
| `xppa_list_arrays` | XP arrays registered in Performance Advisor |
| `xppa_array_details` | Dashboard detail for an XP array |
| `xppa_array_capacity` | Capacity view for an XP array |
| `xppa_array_components` | Component status inventory |
| `xppa_array_ldevs` | LDEV metric view for an explicit time range |
| `xppa_array_replication` | Replication view for an XP array |
| `xppa_database_summary` | DB collection and retention summary |
| `xppa_event_history` | Bounded event history with optional severity filter |

Every tool accepts an optional `server` argument:

```text
spapphpxp001.healthbc.org
spapphpxp003.fraserhealth.org
```

Omitting it queries both servers and labels each result with its owning server.
Array tools also accept an optional `array` argument (`KDCXP01`, serial, or full
label); omitting it returns results for every discovered array on each reachable
server.

The only POST/DELETE calls are the internal login and logout operations. They
are not exposed as tools. Session IDs and passwords are redacted from errors and
usage logs.

## Transport caveat

XP Performance Advisor 8.5 exposes HTTP port 80 only. The user-facing gateway
still supports HTTPS on `:8088`, but the hop from the gateway host to the XP PA
server is plaintext. Tool results report `transportEncrypted: false` in auth
status. Do not configure a client to send the XP credential directly; it is
server-side only.

## Validation

```powershell
& 'C:\caddy-gateway\Test-HPEXP8Mcp.ps1'
& 'C:\caddy-gateway\Test-HPEXP8McpGuardrails.ps1'
```

Expected current state: `configuredServers: 2`, `onlineServers: 1`, with
`spapphpxp003.fraserhealth.org` in `failures`. After its firewall is opened,
confirm `onlineServers: 2`.
