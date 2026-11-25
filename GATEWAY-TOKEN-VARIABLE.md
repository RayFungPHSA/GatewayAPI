# Gateway token environment variable

## Names

| Purpose | Variable |
|---|---|
| Canonical, preferred | `CADDY_GATEWAY_TOKEN` |
| Deprecated alias, still accepted | `COHESITY_GATEWAY_TOKEN` |
| Canonical admin-only test variable | `CADDY_GATEWAY_ADMIN_TOKEN` |
| Canonical read-only test variable | `CADDY_GATEWAY_READONLY_TOKEN` |

The old `COHESITY_GATEWAY_*` names are still accepted by the local test scripts and helper tooling. The HTTP header and ACL are unchanged: clients still send `X-Gateway-Token`, and the gateway maps the token fingerprint to a named user and role.

No token value, ACL entry, DPAPI record, Caddy route, or MCP tool changed. Tokens do **not** need to be reissued.

## Why the name changed

`COHESITY_GATEWAY_TOKEN` made it look like the token was specific to Cohesity. It is not. One shared named-user token set is used across all catalog servers:

- Cohesity
- HPEGreenLake
- Lansweeper
- vSphere
- 3PARLegacy
- HPEXP8
- Brocade

The gateway itself is referred to as the **Caddy API Gateway**; the MCP-facing part is the **Caddy MCP gateway**. `CADDY_GATEWAY_TOKEN` matches that identity.

## Migrate clients

1. From a normal, non-elevated PowerShell session, run:

   ```powershell
   & 'C:\caddy-gateway\Set-GatewayTokenAlias.ps1'
   ```

   This copies the existing legacy value into `CADDY_GATEWAY_TOKEN` for new processes and the current process. It never prints the token.

   If you only want the current shell changed, add `-ProcessOnly`.

2. In each MCP client configuration, replace the placeholder:

   ```json
   { "X-Gateway-Token": "{env:COHESITY_GATEWAY_TOKEN}" }
   ```

   with:

   ```json
   { "X-Gateway-Token": "{env:CADDY_GATEWAY_TOKEN}" }
   ```

3. Restart the MCP client so it rereads the environment. For OpenCode:

   ```powershell
   opencode service restart
   ```

Clients using the legacy variable continue to work during the transition. There is no forced cutover date.

## Rollback

Rollback is intentionally low risk.

### Client rollback

1. Run:

   ```powershell
   & 'C:\caddy-gateway\Set-GatewayTokenAlias.ps1' -Revert
   ```

   This removes the canonical variable from the User environment and current process. The legacy `COHESITY_GATEWAY_TOKEN` value is never modified or removed.

2. Change client placeholders back to:

   ```json
   { "X-Gateway-Token": "{env:COHESITY_GATEWAY_TOKEN}" }
   ```

3. Restart the MCP client.

No gateway service restart, Caddy reload, token rotation, or credential re-encryption is required for this rollback.

### Source rollback

The compatibility migration is its own Git commit. To undo the code and documentation changes:

```powershell
git -C 'C:\caddy-gateway' revert <migration-commit-sha>
git -C 'C:\caddy-gateway' push origin main
```

Because the migration never removes the legacy alias, reverting the commit cannot invalidate existing tokens.

## Validation

The test scripts accept either variable name. They prefer `CADDY_GATEWAY_TOKEN` and fall back to `COHESITY_GATEWAY_TOKEN` when the canonical variable is absent.

```powershell
& 'C:\caddy-gateway\Test-McpDiscovery.ps1'
& 'C:\caddy-gateway\Test-BrocadeMcpGuardrails.ps1'
```
