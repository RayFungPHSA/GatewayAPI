$ErrorActionPreference = 'Stop'

$BridgeDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = Split-Path -Parent $BridgeDir
$SecretsDir = Join-Path $RootDir 'secrets'
$CredentialFile = Join-Path $SecretsDir 'hpegreenlake-gateway.xml'
$CredentialScript = Join-Path $BridgeDir 'scripts\Get-HPEGreenLakeGatewayCredential.ps1'
$AclFile = Join-Path $SecretsDir 'cohesity-gateway-acl.json'
$Script = Join-Path $BridgeDir 'http_bridge.py'
$PidFile = Join-Path $BridgeDir 'bridge.pid'
$LogFile = Join-Path $BridgeDir 'bridge.log'
$ErrFile = Join-Path $BridgeDir 'bridge.err.log'
$UsageLog = Join-Path $BridgeDir 'usage.jsonl'
$Port = 8401

if (-not (Test-Path -LiteralPath $CredentialScript)) {
    throw "Missing protected credential helper: $CredentialScript. Run Set-HPEGreenLakeGatewayCredential.ps1 first."
}

if (-not (Test-Path -LiteralPath $CredentialFile)) {
    throw "Missing protected credential record: $CredentialFile. Run Initialize-HPEGreenLakeSharedKey.ps1 -Force first."
}

# Pass only the helper path to Python. The bridge decrypts the DPAPI record
# itself; no secret value is placed in this process environment.
$env:HPEGREENLAKE_CREDENTIAL_SCRIPT = $CredentialScript
foreach ($name in @('AUTH_URL', 'AUTH_METHOD', 'CLIENT_ID', 'CLIENT_SECRET', 'SCOPE', 'API_BASE_URL', 'USERNAME', 'PASSWORD', 'OPENAPI_SPEC_URL', 'SERVER_NAME')) {
    Remove-Item -Path "Env:$name" -ErrorAction SilentlyContinue
}
Remove-Item -Path 'Env:HPEGREENLAKE_ENV_FILE' -ErrorAction SilentlyContinue

$nodeCommand = Get-Command node -ErrorAction Stop
$env:HPEGREENLAKE_NODE = $nodeCommand.Source
$env:HPEGREENLAKE_GATEWAY_ACL = $AclFile
$env:HPEGREENLAKE_USAGE_LOG = $UsageLog
$env:HPEGREENLAKE_BRIDGE_HOST = '127.0.0.1'
$env:HPEGREENLAKE_BRIDGE_PORT = "$Port"

if (-not (Test-Path -LiteralPath $AclFile)) {
    Write-Warning "Shared ACL file not found: $AclFile. All MCP requests will be denied until a token is issued."
}

$existing = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
if ($existing) {
    Write-Host "HPEGreenLake MCP bridge is already listening on 127.0.0.1:$Port (PID $($existing[0].OwningProcess))."
    exit 0
}

$proc = Start-Process -FilePath 'python' `
    -ArgumentList @('"' + $Script + '"') `
    -WorkingDirectory $BridgeDir `
    -WindowStyle Hidden `
    -RedirectStandardOutput $LogFile `
    -RedirectStandardError $ErrFile `
    -PassThru

Set-Content -LiteralPath $PidFile -Value $proc.Id

$ready = $false
$health = $null
for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Milliseconds 500
    try {
        $health = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/health" -TimeoutSec 2
        if ($health.ok) { $ready = $true; break }
    } catch { }
}

if (-not $ready) {
    Write-Error "Bridge did not become ready. Check $LogFile and $ErrFile."
    exit 1
}

Write-Host "HPEGreenLake MCP bridge started on http://127.0.0.1:$Port/mcp (PID $($proc.Id))."
Write-Host "Auth: shared gateway-token ACL; ACL users: $($health.acl_users)"
Write-Host "Logs: $LogFile"
Write-Host "Errors: $ErrFile"
