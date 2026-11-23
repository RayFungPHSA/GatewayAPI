$ErrorActionPreference = 'Stop'

$BridgeDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = Split-Path -Parent $BridgeDir
$SecretsDir = Join-Path $RootDir 'secrets'
$CredentialFile = Join-Path $SecretsDir 'vsphere.xml'
$ServerFile = Join-Path $SecretsDir 'vsphere-server.txt'
$CaFile = Join-Path $SecretsDir 'vsphere-ca.pem'
$AclFile = Join-Path $SecretsDir 'cohesity-gateway-acl.json'
$Script = Join-Path $BridgeDir 'http_bridge.py'
$CredentialScript = Join-Path $BridgeDir 'scripts\Get-VsphereGatewayCredential.ps1'
$PidFile = Join-Path $BridgeDir 'bridge.pid'
$LogFile = Join-Path $BridgeDir 'bridge.log'
$ErrFile = Join-Path $BridgeDir 'bridge.err.log'
$UsageLog = Join-Path $BridgeDir 'usage.jsonl'
$Port = 8403

foreach ($path in @($CredentialFile, $ServerFile)) {
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Missing protected vSphere credential file: $path. Run Initialize-VsphereSharedKey.ps1 or Set-VsphereGatewayCredential.ps1 first."
    }
}

# The Node child decrypts the DPAPI record itself through this restricted
# helper. No username or password is loaded into the bridge process.
$nodeCommand = Get-Command node -ErrorAction Stop
$env:VSPHERE_NODE = $nodeCommand.Source
$env:VSPHERE_GATEWAY_ACL = $AclFile
$env:VSPHERE_USAGE_LOG = $UsageLog
$env:VSPHERE_CREDENTIAL_FILE = $CredentialFile
$env:VSPHERE_SERVER_FILE = $ServerFile
$env:VSPHERE_CREDENTIAL_SCRIPT = $CredentialScript
$env:VSPHERE_BRIDGE_HOST = '127.0.0.1'
$env:VSPHERE_BRIDGE_PORT = "$Port"

if (Test-Path -LiteralPath $CaFile) {
    $env:VSPHERE_CA_FILE = $CaFile
} else {
    Remove-Item -Path 'Env:VSPHERE_CA_FILE' -ErrorAction SilentlyContinue
}

if (-not (Test-Path -LiteralPath $AclFile)) {
    Write-Warning "Shared ACL file not found: $AclFile. All MCP requests will be denied until a token is issued."
}

$existing = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
if ($existing) {
    Write-Host "vSphere MCP bridge is already listening on 127.0.0.1:$Port (PID $($existing[0].OwningProcess))."
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

Write-Host "vSphere MCP bridge started on http://127.0.0.1:$Port/mcp (PID $($proc.Id))."
Write-Host "Auth: shared gateway-token ACL; ACL users: $($health.acl_users)"
Write-Host "Credential: DPAPI-protected files in $SecretsDir (values not loaded into the bridge)."
Write-Host "Logs: $LogFile"
Write-Host "Errors: $ErrFile"
