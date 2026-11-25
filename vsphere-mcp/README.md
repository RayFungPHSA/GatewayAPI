# vSphere MCP (gateway copy)

Read-only MCP server for VMware vCenter inventory and monitoring. It uses the
official vSphere REST API and exposes no mutating tools.

This copy is exposed through the Caddy gateway at `/vsphere/mcp`. See
`C:\caddy-gateway\VSPHERE-MCP.md` for gateway setup, token/ACL details, and
credential rotation.

## Credentials

On the gateway host, run `Set-VsphereGatewayCredential.ps1` from this folder to
set or rotate the server-side domain credential, or
`Initialize-VsphereSharedKey.ps1` to copy the existing DPAPI-protected
CStorageDashboard credential. The password is protected by Windows DPAPI for the
current Windows user. Credentials and vSphere session IDs are never returned by
MCP tools or browser APIs and are never accepted from MCP clients.

## Read-only tools

- `vsphere_connection_status`
- `vsphere_inventory_summary`
- `vsphere_list_vms`
- `vsphere_get_vm`
- `vsphere_list_hosts`
- `vsphere_list_clusters`
- `vsphere_list_datastores`
- `vsphere_list_networks`
- `vsphere_list_datacenters`
- `vsphere_list_resource_pools`
- `vsphere_get_resource_pool`
- `vsphere_list_folders`
- `vsphere_get_vm_guest_network_interfaces`
- `vsphere_get_vm_guest_identity`
- `vsphere_get_vm_ethernet`
- `vsphere_get_vm_storage_policy`
- `vsphere_get_datastore_default_policy`
- `vsphere_list_content_libraries`
- `vsphere_list_tag_categories`
- `vsphere_list_tags`

The server has no generic request tool and accepts no arbitrary API path, HTTP
method, or command. Every upstream request is a fixed GET except session login.

## Start and test

`npm run check`

`npm run smoke`

`node server.mjs`

If vCenter uses a private CA that Node does not trust, set `VSPHERE_CA_FILE` to a
PEM certificate chain on the backend host. Do not disable TLS verification.
