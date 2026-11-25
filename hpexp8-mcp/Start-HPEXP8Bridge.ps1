$ErrorActionPreference = 'Stop'

$BridgeDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = Split-Path -Parent $BridgeDir
$SecretsDir = Join-Path $RootDir 'secrets'
$CredentialFile = Join-Path $SecretsDir 'hpexp8.xml'
$ServerFile = Join-Path $SecretsDir 'hpexp8-servers.json'
$CredentialScript = Join-Path $BridgeDir 'scripts\Get-HPEXP8GatewayCredential.ps1'
$AclFile = Join-Path $SecretsDir 'cohesity-gateway-acl.json'
$Script = Join-Path $BridgeDir 'http_bridge.py'
$PidFile = Join-Path $BridgeDir 'bridge.pid'
$LogFile = Join-Path $BridgeDir 'bridge.log'
$ErrFile = Join-Path $BridgeDir 'bridge.err.log'
$UsageLog = Join-Path $BridgeDir 'usage.jsonl'
$Port = 8405

foreach ($path in @($CredentialScript, $CredentialFile, $ServerFile)) {
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Missing protected HPEXP8 file: $path. Run Set-HPEXP8GatewayCredential.ps1 first."
    }
}

# Pass only the helper path to Python. The bridge decrypts the DPAPI record
# itself; no secret value is placed in this process environment.
$env:HPEXP8_CREDENTIAL_SCRIPT = $CredentialScript
foreach ($name in @(
    'XPPA_USERNAME', 'XPPA_PASSWORD', 'XPPA_SERVER', 'XPPA_SERVERS',
    'HPEXP8_USERNAME', 'HPEXP8_PASSWORD', 'HPEXP8_SERVER', 'USERNAME', 'PASSWORD'
)) {
    Remove-Item -Path "Env:$name" -ErrorAction SilentlyContinue
}
Remove-Item -Path 'Env:HPEXP8_ENV_FILE' -ErrorAction SilentlyContinue

$env:HPEXP8_GATEWAY_ACL = $AclFile
$env:HPEXP8_USAGE_LOG = $UsageLog
$env:HPEXP8_BRIDGE_HOST = '127.0.0.1'
$env:HPEXP8_BRIDGE_PORT = "$Port"

if (-not (Test-Path -LiteralPath $AclFile)) {
    Write-Warning "Shared ACL file not found: $AclFile. All MCP requests will be denied until a token is issued."
}

$existing = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
if ($existing) {
    Write-Host "HPEXP8 MCP bridge is already listening on 127.0.0.1:$Port (PID $($existing[0].OwningProcess))."
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

Write-Host "HPEXP8 MCP bridge started on http://127.0.0.1:$Port/mcp (PID $($proc.Id))."
Write-Host "Auth: shared gateway-token ACL; ACL users: $($health.acl_users)"
Write-Host "Servers: $($health.servers -join ', ')"
Write-Host 'Credential: loaded from DPAPI at startup; never accepted from clients or placed in environment variables.'
Write-Host "Logs: $LogFile"
Write-Host "Errors: $ErrFile"
