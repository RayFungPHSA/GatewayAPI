# Vendor API coverage review

This document records the read-only MCP tool coverage check against each
vendor's official API documentation. It complements
[HPEGREENLAKE-MCP.md](HPEGREENLAKE-MCP.md) and the gateway startup
documentation.

Method:

1. Inventory the tools actually registered on the gateway via `tools/list` for
   an admin token and a read-only token.
2. Compare the named tools with the vendor's official API reference.
3. Probe candidate GET endpoints against the live tenant before registering
   them as named tools.
4. Re-run the read-only guardrail suites after any change.

Review date: 2026-11-24.

## Summary

| MCP | Official source | Registered tools (admin / read-only) | Read-only enforcement |
| --- | --- | --- | --- |
| Cohesity Helios | Cohesity Developer Portal, Helios REST API V2 | 39 / 37 | Explicit allowlist; all 37 exposed tools annotated `readOnlyHint` |
| HPE GreenLake | HPE Developer Portal, Storage Fleet public API | 136 / 136 | Manifest generated from official OpenAPI GET operations only |
| Lansweeper Classic | Lansweeper Classic docs | 5 / 5 | All tools registered read-only; same allowlist for both roles |
| vSphere | Broadcom vSphere Automation API 8.0.3 / latest | 20 / 20 | All tools read-only; same allowlist for both roles |
| 3PARLegacy | HPE 3PAR StoreServ WSAPI REST API (`/api/v1`) | 10 / 10 | GET-only named tools; all annotated read-only |
| HPEXP8 | HPE XP Performance Advisor 8.5 REST API (`/pa/api`) | 10 / 10 | GET-only named tools; all annotated read-only |
| Brocade | Brocade SANnav Management Portal (3.0.1x) | 9 / 9 callable | 4 documented REST equivalents, 5 derived; all annotated read-only |

Counts are from the live gateway's `tools/list` result. In every MCP the
read-only role receives no tool that the admin role does not also receive.

## Cohesity Helios

### Official documentation used

- API versions index: <https://developer.cohesity.com/apidocs/versions/>
- Helios API overview: <https://developer.cohesity.com/helios-api.html>
- Machine-readable endpoint index: <https://developers.cohesity.com/v1-helios-latest/llms.txt>
- Getting started: <https://developers.cohesity.com/v1-helios-latest/docs/getting-started.md>
- Representative operation pages:
  - <https://developers.cohesity.com/v1-helios-latest/reference/getprotectiongrouprun.md>
  - <https://developers.cohesity.com/v1-helios-latest/reference/getprotectionrunstats.md>
  - <https://developers.cohesity.com/v1-helios-latest/reference/getobjectsnapshots.md>
  - <https://developers.cohesity.com/v1-helios-latest/reference/getobjectruns.md>
  - <https://developers.cohesity.com/v1-helios-latest/reference/getdataprotectusage.md>
  - <https://developers.cohesity.com/v1-helios-latest/reference/getclustersinfo.md>
  - <https://developers.cohesity.com/v1-helios-latest/reference/getheliosalerts.md>
  - <https://developers.cohesity.com/v1-helios-latest/reference/getheliosalertssummary.md>
  - <https://developers.cohesity.com/v1-helios-latest/reference/getalerttypes.md>
  - <https://developers.cohesity.com/v1-helios-latest/reference/getprotectedobjects.md>
  - <https://developers.cohesity.com/v1-helios-latest/reference/getroles.md>
  - <https://developers.cohesity.com/v1-helios-latest/reference/getusers.md>
  - <https://developers.cohesity.com/v1-helios-latest/reference/getstorageDomains.md>
  - <https://developers.cohesity.com/v1-helios-latest/reference/getviews.md>
  - <https://developers.cohesity.com/v1-helios-latest/reference/getexternaltargets.md>

The accessible reference is the rolling `v1-helios-latest` snapshot (last
updated 2026-09-21). It contains both Helios REST API V2
(`https://helios.cohesity.com/v2`) and legacy V1 operations. A newer portal at
<https://cohesity.com/developers/reference/> returned HTTP 403 unauthenticated,
so it could not be verified.

### Coverage

Every major read-only family has at least one dedicated named tool: clusters,
protection groups and runs, policies, alerts, protected objects and search,
recoveries, audit logs, sources, tenants, encryption, and usage history.

This review added thirteen dedicated GET tools after checking both the official
reference and the live tenant:

- `get_data_protect_usage` — `GET /mcm/data-protect/usage-stats`
- `get_alert_summary` — `GET /mcm/stats/alerts-summary`
- `get_alert_types` — `GET /alert-types`
- `get_cluster_storage_stats` — `GET /stats/cluster-storage`
- `get_protection_group_run` — `GET /data-protect/protection-groups/{id}/runs/{runId}`
- `get_protection_run_stats` — `GET /data-protect/runs/{runId}/stats`
- `get_object_snapshots` — `GET /data-protect/objects/{id}/snapshots`
- `get_object_runs` — `GET /data-protect/objects/{id}/runs`
- `list_storage_domains`, `list_file_views`, `list_external_targets`,
  `list_users`, `list_roles` — `GET /storage-domains`, `/file-services/views`,
  `/data-protect/external-targets`, `/users`, `/roles`

Parameter names in three existing tools were corrected to match the current
official contract: `list_protection_groups` now uses plural `environments`,
`list_alerts` uses `alertTypeList`/`alertStateList`/`alertSeverityList` and
`startDateUsecs`/`endDateUsecs`, and `list_protected_objects` uses the
documented `/mcm/data-protect/protected-objects` path with local filtering.

### Limits

- `api_request` gives read-only users GET access to any path on the fixed V2
  base, with no request body. It does **not** reach the separate V1,
  Reporting, or Licensing bases, cannot set arbitrary headers, and cannot
  invoke operations that are officially POST even when they are read-like.
- Official families observed in the reference but not registered as named
  tools include reports (`/public/reports`), licensing (`/usage/products`),
  data-retention policies (`/mcm/data-retention/policies`), certificate
  inventory (`/cert-manager/cert-inventory`), and service health
  (`/helios/health/services`). These endpoints returned HTTP 500 on this
  tenant during validation, so they were left to `api_request` instead of
  being exposed as tools that would fail.
- Some object-level endpoints (`/data-protect/objects/{id}/snapshots`,
  `/data-protect/objects/{id}/runs`, `/data-protect/objects/last-run`) are
  documented but returned tenant/index errors during probing. The tools are
  registered because the paths are official and correct; failures are
  surfaced as ordinary API errors rather than hidden.

### Mutating tools

`run_backup` issues `POST /data-protect/protection-groups/{id}/runs` and
`collect_protection_group_usage` writes a local SQLite snapshot. Both remain
admin-only and are hidden from read-only users. `api_request` is GET-only for
read-only users by both schema and runtime enforcement.

## HPE GreenLake

The HPE MCP was already generated from the official Storage Fleet OpenAPI
description. Only HTTP GET operations are emitted into
`hpegreenlake-mcp/src/greenlake-readonly-tools.json` by
`hpegreenlake-mcp/scripts/generate-readonly-manifest.mjs`. Both roles see the
same 136 read-only tools. No change was needed in this review.

## Lansweeper

### Official documentation used

- Classic home: <https://docs.lansweeper.com/classic/>
- What is Lansweeper Classic: <https://docs.lansweeper.com/classic/docs/what-is-lansweeper-classic.md>
- Web console: <https://docs.lansweeper.com/classic/docs/access-the-web-console.md>
- Database documentation: <https://docs.lansweeper.com/classic/docs/access-lansweeper-database-documentation.md>
- Reporting: <https://docs.lansweeper.com/classic/docs/reporting.md>
- Link Classic to Platform: <https://docs.lansweeper.com/classic/docs/link-lansweeper-classic-with-lansweeper-platform.md>
- Data API: <https://developer.lansweeper.com/docs/data-api/get-started/welcome/>
- Data API endpoint and auth: <https://developer.lansweeper.com/docs/data-api/get-started/endpoint>, <https://developer.lansweeper.com/docs/data-api/get-started/quickstart>
- Official Lansweeper MCP server: <https://docs.lansweeper.com/docs/explore-lansweeper-mcp-server.md>

### Coverage

The configured target `https://ls.healthbc.org` is a Lansweeper Classic web
console. Official Lansweeper documentation does not describe a general
read-only REST/GraphQL API for Classic; it documents the web console, SQL
database, and reports. The Platform Data API and the official Lansweeper MCP
server require a linked Platform site and API client/OAuth credentials, which
are not configured here.

The gateway therefore exposes five read-oriented console tools: connection
status, auth status, endpoint discovery, an asset report, and generic
authenticated page fetch. These provide broad but brittle access; they are
not equivalent to a typed official read API. Web-console internals such as
`/ReportJson.aspx` and the report key `web50repassetsmenu` cannot be verified
from official docs and are installation/version specific.

Official Data API families that remain uncovered unless Classic is linked to
Platform include sites/scope, asset detail/groups/states, software,
vulnerabilities, users, services, report catalog/status/export, scanning
tasks/exclusions, and webhooks.

### Change made

`lansweeper_fetch_page` and `lansweeper_discover_endpoints` accept caller
supplied paths. Previously `new URL(requestPath, baseUrl)` allowed an absolute
or protocol-relative URL to point at another origin while carrying the
authenticated console cookie. `src/server.js` now enforces the configured
console origin for every request, including redirects. The guardrail suite
includes a cross-origin rejection assertion.

Two tools use POST for read-oriented purposes: the console login and
`ReportJson.aspx`. Neither exposes a Lansweeper write operation, GraphQL
mutation, scan trigger, or configuration change.

## vSphere

### Official documentation used

- vSphere Automation API index: <https://developer.broadcom.com/xapis/vsphere-automation-api/latest/>
- vCenter API: <https://developer.broadcom.com/xapis/vsphere-automation-api/8.0.3/vcenter/>
- Guest networking interfaces: <https://developer.broadcom.com/xapis/vsphere-automation-api/8.0.3/vcenter/api/vcenter/vm/vm/guest/networking/interfaces/get/>
- Appliance health: <https://developer.broadcom.com/xapis/vsphere-automation-api/8.0.3/appliance/api/appliance/health/system/get/>
- VMware alternative reference: <https://developer.vmware.com/apis/vsphere-automation/latest/vcenter/>

The official reference currently shows `9.1.1 (Latest)` and also lists 8.0.3
and 7.x versions. Operations were checked against 8.0.3 where available. No
Broadcom login was required for the API reference pages; the older VMware
REST Programming Guide pages returned a TechDocs login placeholder and were
not used as primary evidence.

### Coverage and changes

The original nine tools covered VMs, hosts, clusters, datastores, networks,
datacenters, inventory summary, and appliance version. The following
read-only tools were added after confirming the official paths and live
responses:

- `vsphere_list_resource_pools` — `GET /api/vcenter/resource-pool`
- `vsphere_get_resource_pool` — `GET /api/vcenter/resource-pool/{resourcePool}`
- `vsphere_list_folders` — `GET /api/vcenter/folder`
- `vsphere_get_vm_guest_network_interfaces` — `GET /api/vcenter/vm/{vm}/guest/networking/interfaces`
- `vsphere_get_vm_guest_identity` — `GET /api/vcenter/vm/{vm}/guest/identity`
- `vsphere_get_vm_ethernet` — `GET /api/vcenter/vm/{vm}/hardware/ethernet`
- `vsphere_get_vm_storage_policy` — `GET /api/vcenter/vm/{vm}/storage/policy`
- `vsphere_get_datastore_default_policy` — `GET /api/vcenter/datastore/{datastore}/default-policy`
- `vsphere_list_content_libraries` — `GET /api/content/library`
- `vsphere_list_tag_categories` — `GET /api/cis/tagging/category`
- `vsphere_list_tags` — `GET /api/cis/tagging/tag`

Every tool fans out across all six configured vCenters by default and attaches
the owning vCenter to the results. Live validation of the new list tools
reported `configuredVCenters=6 onlineVCenters=6`.

Official read families not registered because the tenant returned HTTP 403,
404, or 500 during probing: storage policies (`/api/vcenter/storage/policies`),
appliance health (`/api/appliance/health/*`), uptime
(`/api/appliance/system/uptime`), vCenter services (`/api/vcenter/services`),
and capacity usage (`/api/vcenter/capacity/usage`). They are likely blocked by
vCenter privileges or version, not by missing official documentation.

No vSphere tool mutates the environment. The only POST is the internal
session login `POST /rest/com/vmware/cis/session`, which is not exposed as an
MCP tool.

## 3PARLegacy

### Official documentation and live verification

- HPE 3PAR WSAPI uses `POST /api/v1/credentials` for sessions and returns a
  session key used in the `X-HP3PAR-WSAPI-SessionKey` header.
- Read operations are GETs under `/api/v1`, including `system`, `cpgs`,
  `volumes`, `volumesets`, `hosts`, `hostsets`, `ports`, `users`, and `capacity`.
- Live authenticated calls confirmed `cw3par02.phsabc.ehcnet.ca` (HTTPS/8080,
  HP_3PAR 7400, WSAPI 3.2.2.709). `JPN3PAR01` resolves and pings but TCP/443 is
  firewall-pending; the bridge reports it per-array in `failures`.

### Coverage and changes

Ten named read-only tools are registered for both roles. Every tool fans out
across both configured arrays by default and labels each result with its owning
array. The only POST is the internal session-key request, which is never exposed
as an MCP tool. Client-supplied 3PAR credentials and session keys are rejected.

## HPEXP8

### Official documentation and live verification

- Built from the project-local `CStorageDashboard\\mcp-configs\\hpe-xppa` server,
  which targets HPE XP Performance Advisor 8.5.
- Authentication uses `POST /pa/api/auth/login` and returns a session ID passed
  in the `auth` header. All operational calls are GETs under `/pa/api`, including
  `index/arrayfilter`, `arraydashboardservice/*`, `database/dbsummary`, and
  `eventlog/getevent`.
- Live authenticated calls confirmed `spapphpxp001.healthbc.org` (HTTP/80,
  `/pa`, one array `KDCXP01`). `spapphpxp003.fraserhealth.org` resolves but
  TCP/80 times out; the bridge reports it per-server in `failures`.

### Coverage and changes

Ten named read-only tools are registered for both roles. Every tool fans out
across both configured servers by default and labels each result with its owning
server. The only POST is the internal login request, which is never exposed as
an MCP tool. Client-supplied XP credentials and session headers are rejected.
The gateway-to-XP hop is plaintext HTTP because XP PA 8.5 listens on port 80
only; this is reported by `transportEncrypted: false` in auth status.

## Brocade

### Official documentation and live verification

- Built from the project-local `CStorageDashboard\mcp-configs\Brocade` server.
- The upgraded appliance reports `3.0.0.1` (build 11) from
  `GET /external-api/v1/about/`, so it is treated as the 3.0.1x API family:
  [SANnav 3.0.1x Management Portal REST API Reference](https://techdocs.broadcom.com/us/en/fibre-channel-networking/sannav/management-portal-rest-api/3-0-1x.html)
  and [release notes](https://docs.broadcom.com/doc/sannav-management-portal-v3.0.1-release-notes).
- The bridge uses documented session-less HTTP Basic auth on
  `/external-api/v1`. There is no login POST, no session ID, and no internal UI
  endpoint. The legacy `POST /auth/login` session now returns HTTP 401 on
  external API calls.
- Live authenticated calls confirmed `https://10.254.22.251:443`: 12 fabrics,
  38 switches, 1647 host ports, and 436 storage ports. Hosts (1024) and storages
  (50) are derived from device-port names. `/inventory/connections` returns 403
  for this read-only account and is not exposed as a tool.

### Official API coverage of the nine tools

| Tool | Official 3.0.1x REST API status |
|---|---|
| `list-fabrics` | Documented: `GET /external-api/v1/inventory/fabrics/` |
| `list-switches` | Documented: `GET /external-api/v1/inventory/switches/` (includes `firmwareVersion`) |
| `list-hosts` | Derived from documented `GET /external-api/v1/inventory/deviceports/?type=host`; no public hosts collection |
| `list-host-ports` | Documented: `GET /external-api/v1/inventory/deviceports/?type=host` |
| `list-storages` | Derived from documented `GET /external-api/v1/inventory/deviceports/?type=storage`; no public storages collection |
| `list-storage-ports` | Documented: `GET /external-api/v1/inventory/deviceports/?type=storage` |
| `list-zones` | No named zones GET; derived from `deviceports` `activeZones`/`zoneAlias`. FOS proxy zone GETs require admin privilege and returned 403 for this account. |
| `get-connectivity-map` | No named endpoint; derived from host and storage `deviceports` |
| `get-overview` | No read-only overview endpoint; derived from documented fabrics, switches, and device ports |

**Conclusion:** all nine tools are callable with the read-only account, four
have direct documented external REST equivalents, five are derived from
documented data, and none rely on undocumented internal UI endpoints after the
3.0.1 migration.

SANnav 3.0.1 added four REST interfaces. The read-only candidates are
`GET /external-api/v1/license/active/` (HTTP 403 for this account) and
`GET /external-api/v1/zoning/snapshots` (HTTP 405 `Invalid payload` even with
the documented `fabricName` parameter). The mutating
`PUT /external-api/v1/usermgmt/users/credentials` and
`PUT /external-api/v1/inventory/chassis/credentials` endpoints change passwords
and are intentionally not exposed through MCP.

### Coverage and changes

Nine named read-only tools are registered for both roles, matching the source
server's tool surface. All upstream requests are documented GETs with
session-less Basic auth; no POST or session state is used. Client-supplied
SANnav credentials and Basic auth headers are rejected. SANnav uses a
self-signed certificate, so TLS verification is disabled only for the single
configured HTTPS endpoint. The credential was imported locally from the old
plaintext `.env` into a DPAPI-protected record; no plaintext credential file was
copied into the gateway.

## Read-only user verification

Read-only users are restricted in three layers:

1. The gateway ACL maps the token to the `read-only` role.
2. Each bridge hides and rejects tools outside its read-only allowlist
   (Cohesity explicitly hides `run_backup` and
   `collect_protection_group_usage`; other MCPs contain only read tools).
3. Tools expose MCP `readOnlyHint=true` and `destructiveHint=false`, and
   Cohesity's generic `api_request` is additionally constrained to GET with
   no body.

Final guardrail results:

| Suite | Result |
| --- | --- |
| `Test-CohesityMcpGuardrails.ps1` | 10 passed, 0 failed |
| `Test-HPEGreenLakeMcpGuardrails.ps1` | 6 passed, 0 failed |
| `Test-LansweeperMcpGuardrails.ps1` | 7 passed, 0 failed |
| `Test-VsphereMcpGuardrails.ps1` | 6 passed, 0 failed |
| `Test-3PARLegacyMcpGuardrails.ps1` | 9 passed, 0 failed |
| `Test-HPEXP8McpGuardrails.ps1` | 9 passed, 0 failed |
| `Test-BrocadeMcpGuardrails.ps1` | 10 passed, 0 failed |

## Caveats

- Official documentation versions do not necessarily match the exact tenant
  software versions. Endpoints were live-probed before registration where
  practical.
- A vendor endpoint returning an error on this tenant is not treated as a
  read-only regression; the error is returned to the caller.
- No secrets, API keys, gateway tokens, or passwords are recorded here.
