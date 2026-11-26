# AGENTS.md

## Stack & Architecture

- Native Caddy (`Caddyfile`): HTTP `:8081`, HTTPS `:8088`, loopback metrics `:9180`, admin `:2019`; routes for `/mcp/servers` and seven MCP bridges.
- Seven loopback Python bridges (`*-mcp/http_bridge.py`, ports `8400`-`8406`) validate `X-Gateway-Token` against the shared ACL and proxy to Python clients or Node MCP servers.
- Seven MCP servers: `cohesity`, `hpegreenlake`, `lansweeper`, `vsphere`, `3PARLegacy`, `HPEXP8`, `Brocade`.
- Auth: shared named-user ACL with `admin` / `read-only` roles; env `CADDY_GATEWAY_TOKEN`; deprecated alias `COHESITY_GATEWAY_TOKEN`.
- PowerShell orchestrates startup/shutdown, token/ACL management, DPAPI credentials, tests, and usage reports.
- Windows service `service\CaddyGatewayService.cs` / `.exe` wraps `Start-CaddyGateway.ps1` and `Stop-CaddyGateway.ps1`; runs as `PHSABC\Ray.Fung`.
- Key folders: `scripts\` (`GatewayDpapi.psm1`), `secrets\`, `logs\`, `analytics\`, `service\`, and seven `*-mcp\` directories.
- Node MCP servers use ESM, `@modelcontextprotocol/sdk`, Zod; Python adds DuckDB/Streamlit reporting.
- No IIS portal; Secret Server is the only gateway key distribution source.

## Build/Test/Lint Commands

Run from `C:\caddy-gateway`.

```powershell
.\Start-CaddyGateway.ps1
.\Stop-CaddyGateway.ps1
.\Install-CaddyGatewayService.ps1
.\Uninstall-CaddyGatewayService.ps1
Restart-Service CaddyGateway
$caddy = 'C:\Users\ray.fung\AppData\Local\Microsoft\WinGet\Packages\CaddyServer.Caddy_Microsoft.Winget.Source_8wekyb3d8bbwe\caddy.exe'
& $caddy validate --config .\Caddyfile
& $caddy reload --config .\Caddyfile
```

Tests:

```powershell
.\Run-GatewayTests.ps1
.\Run-GatewayTests.ps1 -Tests Test-McpDiscovery.ps1,Test-CohesityMcpGuardrails.ps1
.\Test-VSMonitoring-Curl.ps1
```

Syntax checks; no first-party lint/typecheck pipeline is configured:

```powershell
npm --prefix .\hpegreenlake-mcp run check
npm --prefix .\lansweeper-mcp run check
npm --prefix .\vsphere-mcp run check
Push-Location .\cohesity-mcp; python -m unittest test_usage_history.py; Pop-Location
git diff --check
```

`Run-GatewayTests.ps1` reads the restricted token distribution file, verifies fingerprints against the ACL, sets canonical test env vars, and never prints token values.

Service EXE builds only via `Install-CaddyGatewayService.ps1`; do not patch `service\CaddyGatewayService.exe`.

## Project Conventions

- PowerShell: PascalCase `Verb-Noun.ps1`; tests are `Test-*.ps1`; bridge folders are lowercase hyphenated `*-mcp`.
- PowerShell scripts use comment help, `[CmdletBinding()]`, `$ErrorActionPreference = 'Stop'`, `-LiteralPath`, `Join-Path`, and `throw`.
- Python: snake_case, uppercase constants, type hints, SHA-256 token fingerprints. Node: ESM and camelCase.
- Docs: uppercase root Markdown and per-server `*-MCP.md`; use fenced `powershell` examples.
- Tests print `Result: N passed, M failed`; the runner fails on non-zero exit or `FAIL|Exception|Error:`.
- Bridges fail closed on missing/unknown tokens, return HTTP 403 when unauthorized, and keep health endpoints token-free.
- JSON uses two-space indent; generated JSON/text files are UTF-8 without BOM.
- Never log raw tokens or vendor credentials; usage logs store fingerprint prefixes only.

## Guardrails

- Never manually edit `secrets\`; use `cohesity-mcp\New-CohesityGatewayToken.ps1`, `Set-CohesityGatewayRole.ps1`, `Remove-CohesityGatewayToken.ps1`, `Initialize-CohesityGatewayAcl.ps1`, and `Set-*GatewayCredential.ps1`.
- No credentials in `Caddyfile`, client configs, prompts, copied MCP folders, or plaintext `*-gateway.env` files.
- Preserve rollback artifacts: tag `pre-iis-token-portal-20261125` and `secrets\backups\pre-iis-token-portal-20261125\`.
- Do not hand-edit generated/runtime artifacts: `logs\`, `analytics\*.duckdb`, `analytics\snapshot.log`, `*.log`, `*.log.gz`, `bridge.pid`, `usage.jsonl`, `__pycache__\`, `*.pyc`, `node_modules\`, `.pythonlibs\`.
- Do not patch `service\CaddyGatewayService.exe`; rebuild via the installer. Do not hand-edit `hpegreenlake-mcp\src\greenlake-readonly-tools.json`; regenerate via `hpegreenlake-mcp\scripts\generate-readonly-manifest.mjs`.
- `Start-CaddyGateway.ps1` and `Stop-CaddyGateway.ps1` are the only gateway startup/shutdown entry points.
- Keep loopback-only endpoints private: `:9180/metrics`, Caddy admin `:2019`, Streamlit `:8501`.
- `*.env.example` and `mcp-config.example.json` are templates; never add real credentials or `.env` files to the repo.
- Never use real users' tokens for automated tests; use `gateway-test@phsa.ca` only.
