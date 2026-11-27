# Brocade MCP

`Brocade` is a read-only MCP for the Brocade SANnav Management Portal. It was
brought over from `CStorageDashboard\mcp-configs\Brocade`, converted from a stdio
server with a plaintext `.env` into a gateway HTTP bridge that uses the shared
gateway-token ACL. Its nine tools are live against the upgraded SANnav 3.0.1x
API and are backed only by documented external REST calls or data derived from
them; see [Official API coverage](#official-api-coverage).

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

| Tool | Official SANnav REST source used by this bridge | Purpose |
|---|---|---|
| `list-fabrics` | `GET /external-api/v1/inventory/fabrics/` | Fabrics with health and inventory counts |
| `list-switches` | `GET /external-api/v1/inventory/switches/` | Switches with model, firmware, IP, fabric |
| `list-hosts` | Derived from `GET /external-api/v1/inventory/deviceports/?type=host` | Hosts connected to the SAN |
| `list-host-ports` | `GET /external-api/v1/inventory/deviceports/?type=host` | Host-side FC ports and connectivity |
| `list-storages` | Derived from `GET /external-api/v1/inventory/deviceports/?type=storage` | Storage arrays |
| `list-storage-ports` | `GET /external-api/v1/inventory/deviceports/?type=storage` | Storage-side FC target ports |
| `list-zones` | Derived from `deviceports` `activeZones`/`zoneAlias` | Active zones and members |
| `get-connectivity-map` | Derived from host and storage `deviceports` | Host-to-storage paths through switches |
| `get-overview` | Derived from fabrics, switches, and device ports | Counts and health summary |

Filters match the original server: `fabric`, `health`, `search`, `host`,
`storage`, and `portRole` where applicable. `get-overview` is deliberately
bounded to counts and health distributions, so it does not return large raw
inventories.

Authentication uses documented session-less HTTP Basic auth on the
`/external-api/v1` API. There is no login POST, no `sessionId`, and no internal
UI endpoint. Collection calls use `startIndex`/`numOfRecords` pagination with a
5000-record page size. Client-supplied SANnav credentials are still rejected by
the gateway bridge.

`/inventory/connections` returns HTTP 403 for the read-only service account, so
it is not used by any tool.

## Official API coverage

Checked against the official Broadcom guides for the upgraded appliance:

- [SANnav 3.0.1x Management Portal REST API Reference](https://techdocs.broadcom.com/us/en/fibre-channel-networking/sannav/management-portal-rest-api/3-0-1x.html)
- [SANnav Management Portal v3.0.1 Release Notes](https://docs.broadcom.com/doc/sannav-management-portal-v3.0.1-release-notes)
- [About SANnav](https://techdocs.broadcom.com/us/en/fibre-channel-networking/sannav/management-portal-rest-api/3-0-1x/Resources-REST-API/about-sannav-module.html)

The live appliance currently reports version `3.0.0.1` (build 11) from
`GET /external-api/v1/about/`, so it is treated as the 3.0.1x API family. The
official guide documents GET endpoints for fabrics, switches, switch ports,
device ports (with `type=host` and `type=storage` filters), discovery, FCR
topology, chassis, enclosures, about, and license details. It also documents
`POST /external-api/v1/fos/rest/` as a read-only proxy for two Fabric OS zone
GETs, but that call requires the **Element Manager - Product Administration**
privilege. `POST /external-api/v1/healthsummary/healthsummarydetails/`
likewise requires Health Score Configuration read/write permission, so neither
is available to this read-only account.

Result for the nine registered tools:

- **4 have direct documented equivalents**: `list-fabrics`, `list-switches`,
  `list-host-ports`, `list-storage-ports`.
- **5 are derived from documented data**: `list-hosts`, `list-storages`,
  `list-zones`, `get-connectivity-map`, `get-overview`. There is no public
  hosts/storages collection endpoint, so hosts and storages are grouped from
  device ports.
- **0 rely on undocumented internal UI endpoints** after this migration.

SANnav 3.0.1 added four REST interfaces. The two GETs are not exposed here:
`GET /external-api/v1/license/active/` returns HTTP 403 for this account, and
`GET /external-api/v1/zoning/snapshots` returns HTTP 405 (`Invalid payload`)
even with the documented `fabricName` parameter and session. The two PUTs,
`PUT /external-api/v1/usermgmt/users/credentials` and
`PUT /external-api/v1/inventory/chassis/credentials`, change passwords and are
intentionally not exposed through MCP.

## Live verification

After migration to the official API:

- `GET /external-api/v1/about/` reports version `3.0.0.1`, build 11.
- Basic-auth probes succeeded for fabrics, switches, and both device-port
  collections; the same calls returned HTTP 401 with the legacy UI session.
- 12 fabrics, 38 switches, 1647 host ports, and 436 storage ports were returned.
- 1024 hosts and 50 storages were derived from device-port names.
- 2394 zones and 1917 host-to-storage connections were derived.

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
