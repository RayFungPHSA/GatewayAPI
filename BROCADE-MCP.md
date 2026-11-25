# Brocade MCP

`Brocade` is a read-only MCP for the Brocade SANnav Management Portal. It was
brought over from `CStorageDashboard\mcp-configs\Brocade`, converted from a stdio
server with a plaintext `.env` into a gateway HTTP bridge that uses the shared
gateway-token ACL. Its nine tools are live against SANnav 2.4.0a, but they are
**not all documented external REST APIs**; see
[Official API coverage](#official-api-coverage).

## Endpoint

| Listener | MCP endpoint | Health |
|---|---|---|
| HTTP | `http://10.53.19.120:8081/brocade/mcp` | `http://10.53.19.120:8081/brocade/health` |
| HTTPS | `https://10.53.19.120:8088/brocade/mcp` | `https://10.53.19.120:8088/brocade/health` |

SANnav endpoint: `https://10.254.22.251:443`. TCP/443 is reachable; TCP/80 is
closed. The SANnav certificate is self-signed, so TLS verification is disabled
only for this one configured HTTPS endpoint.

Clients authenticate only with the shared gateway token:

```text
X-Gateway-Token: <token issued to the user>
```

Client-supplied SANnav username, password, session, or Basic auth headers are
rejected with HTTP 400.

## Credential handling

The old project stored `SANNAV_HOST`, `SANNAV_USER`, `SANNAV_PASS`, and
`SANNAV_PORT` in a plaintext `.env`, and its README embedded the password in an
example command. **Neither the `.env` nor that README was copied into this
gateway.**

The setup script reads those values locally, converts the password to a
`SecureString` in memory, and writes a DPAPI-encrypted `PSCredential` record:

```powershell
& 'C:\caddy-gateway\brocade-mcp\Set-BrocadeGatewayCredential.ps1'
```

To rotate the password locally with masked input (never paste it into chat):

```powershell
& 'C:\caddy-gateway\brocade-mcp\Set-BrocadeGatewayCredential.ps1 -PromptPassword -Username sanswitchRO
```

It writes:

```text
C:\caddy-gateway\secrets\brocade.xml
C:\caddy-gateway\secrets\brocade-servers.json
```

`brocade.xml` contains `<SS N="Password">`, a DPAPI-encrypted SecureString bound
to the `ray.fung` Windows account. `brocade-servers.json` contains only the host
and port. Both files and the `secrets` directory are NTFS-restricted to the
current user, SYSTEM, and Administrators.

The bridge calls
`brocade-mcp\scripts\Get-BrocadeGatewayCredential.ps1` at startup. That helper
emits JSON to the local Python process only. The password is never in an
environment variable, Caddy config, client config, prompt, or MCP request.
Usage logs record only a 12-character SHA-256 fingerprint of the credential,
and errors redact passwords, Basic auth, and session IDs.

DPAPI is account-bound: setup and bridge start must run as the same Windows
account (`ray.fung`).

## Start / stop the bridge

```powershell
& 'C:\caddy-gateway\brocade-mcp\Start-BrocadeBridge.ps1'
& 'C:\caddy-gateway\brocade-mcp\Stop-BrocadeBridge.ps1'
```

The bridge listens on `127.0.0.1:8406` only. `Start-CaddyGateway.ps1` starts or
verifies it along with the other six bridges.

## Tools

All nine tools are read-only (`readOnlyHint: true`, `destructiveHint: false`,
`idempotentHint: true`):

| Tool | Path used by this bridge | Documented 2.4.0x external API | Purpose |
|---|---|---|---|
| `list-fabrics` | `/inventory/fabrics` | `GET /external-api/v1/inventory/fabrics/` | Fabrics with health and inventory counts |
| `list-switches` | `/firmwaremanagement/switches` | `GET /external-api/v1/inventory/switches/` | Switches with model, firmware, IP, fabric |
| `list-hosts` | `/inventory/hosts` | None | Hosts connected to the SAN |
| `list-host-ports` | `/inventory/fabrics/All/hosts/All/ports` | `GET /external-api/v1/inventory/deviceports/?type=host` | Host-side FC ports and connectivity |
| `list-storages` | `/inventory/storages` | None | Storage arrays |
| `list-storage-ports` | `/inventory/fabrics/ALL/storages/All/ports` | `GET /external-api/v1/inventory/deviceports/?type=storage` | Storage-side FC target ports |
| `list-zones` | Aggregated from host/storage ports | Derived from `deviceports` `activeZones`/`zoneAlias`; no named zones GET | Active zones and members |
| `get-connectivity-map` | Aggregated from host/storage ports | Derived from `deviceports`/`switchports`; no named endpoint | Host-to-storage paths through switches |
| `get-overview` | Aggregated from the above | Derived from fabrics/switches/ports; `healthsummarydetails` requires read/write | Counts and health summary |

Filters match the original server: `fabric`, `health`, `search`, `host`,
`storage`, and `portRole` where applicable. `get-overview` is deliberately
bounded to counts and health distributions, so it does not return large raw
inventories.

The only POST is the internal UI login `POST /auth/login` with Basic auth and
`initiator: SANNAV_UI`. It returns a `sessionId` used as the `Authorization`
header on subsequent GETs and refreshed after five minutes. That POST is not
exposed as an MCP tool. The official guide documents
`POST /external-api/v1/login/` instead; the bridge currently inherits the
source server's internal login and has not been migrated to the external login.

`/inventory/connections` returns HTTP 403 for the read-only service account, so
it is not used by any tool.

## Official API coverage

Checked against the official Broadcom guide for the live appliance version
(SANnav **2.4.0a** reported by `GET /external-api/v1/about/`):

- [SANnav 2.4.0x REST API and Northbound Streaming Reference Manual](https://techdocs.broadcom.com/us/en/fibre-channel-networking/sannav/management-portal-rest-api/2-4-0x.html)
- [PDF](https://techdocs.broadcom.com/content/dam/broadcom/techdocs/us/en/pdf/fc-networking/software-sannav/sannav-240x-restapi.pdf)
- [Current REST API documentation index](https://docs.broadcom.com/docs/management-portal-rest-api)

The 2.4.0x guide documents GET endpoints for fabrics, switches, switch ports,
device ports (with `type=host` and `type=storage` filters), discovery, FCR
topology, chassis, enclosures, about, and password policy. It also documents
`POST /external-api/v1/fos/rest/` as a read-only proxy for two Fabric OS zone
GETs, but that call requires the **Element Manager - Product Administration**
privilege. A live probe with the read-only service account returned HTTP 403
with that exact requirement. `POST /external-api/v1/healthsummary/healthsummarydetails/`
likewise requires Health Score Configuration read/write permission, so it is not
available to this read-only account.

Result for the nine registered tools:

- **4 have direct documented equivalents**: `list-fabrics`, `list-switches`,
  `list-host-ports`, `list-storage-ports`.
- **3 can be derived from documented data but have no named endpoint**:
  `list-zones`, `get-connectivity-map`, `get-overview`.
- **2 have no documented external API equivalent**: `list-hosts` and
  `list-storages`. The bridge uses the internal UI paths `/inventory/hosts` and
  `/inventory/storages`, which work today but are not part of the published
  SANnav REST API and may change without notice.

All nine tools were confirmed to return live data with the read-only account,
but “available” here means the appliance's internal UI endpoints are callable,
not that every tool is a documented public SANnav REST API. Migrating to the
official endpoints should be done before treating this MCP as a supported
public-API integration.

## Live verification

At the time of onboarding:

- Login succeeded; the account has `allFabrics: true`.
- 12 fabrics, 26 switches, 556 hosts, 29 storages, 1621 host ports, and 436
  storage ports were returned.
- 2394 zones and 1921 host-to-storage connections were derived.

## Validation

```powershell
& 'C:\caddy-gateway\Test-BrocadeMcp.ps1'
& 'C:\caddy-gateway\Test-BrocadeMcpGuardrails.ps1'
```

## Residual risk in the source project

The old project at `C:\Code\CStorageDashboard\mcp-configs\Brocade` still has a
plaintext `.env` and a README with an embedded password. They were left
untouched because they are outside this gateway, but they should be removed or
redacted, and the service account password should be rotated, since it has been
stored in plaintext. Ask before doing either — rotating requires entering the
new password locally with masked input.
