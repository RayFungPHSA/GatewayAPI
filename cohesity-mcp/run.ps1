# Windows PowerShell / pwsh runner for the Cohesity stdio MCP server (local debugging only).
$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = Split-Path -Parent $ScriptDir
$ModulePath = Join-Path $RootDir 'scripts\GatewayDpapi.psm1'
$CredentialFile = Join-Path $RootDir 'secrets\cohesity-gateway.xml'

if (-not (Test-Path -LiteralPath $CredentialFile)) {
    throw "Missing protected credential record: $CredentialFile. Run Initialize-CohesitySharedKey.ps1 -Force first."
}

Import-Module $ModulePath -Force
try {
    $record = Get-GatewayDpapiRecord -Path $CredentialFile
} catch {
    throw 'The protected Cohesity credential could not be loaded.'
}

$apiKey = [string]$record.COHESITY_API_KEY
if ([string]::IsNullOrWhiteSpace($apiKey)) {
    throw 'The protected Cohesity credential is incomplete.'
}

$env:COHESITY_API_KEY = $apiKey
$env:COHESITY_NO_DOTENV = 'true'
Remove-Item -Path 'Env:HELIOS_API_KEY' -ErrorAction SilentlyContinue

python "$ScriptDir/cohesity_mcp.py"
