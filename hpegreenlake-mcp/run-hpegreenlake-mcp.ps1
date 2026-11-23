<#
.SYNOPSIS
    Run the HPEGreenLake stdio MCP server directly for local debugging.

.DESCRIPTION
    Loads the server-only credential from the DPAPI-protected record, then
    launches src\server.mjs with Node. This is not needed for normal gateway
    use; Start-HPEGreenLakeBridge.ps1 is the server entry point.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$BridgeDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = Split-Path -Parent $BridgeDir
$ModulePath = Join-Path $RootDir 'scripts\GatewayDpapi.psm1'
$CredentialFile = Join-Path $RootDir 'secrets\hpegreenlake-gateway.xml'
$Script = Join-Path $BridgeDir 'src\server.mjs'

if (-not (Test-Path -LiteralPath $CredentialFile)) {
    throw "Missing protected credential record: $CredentialFile. Run Initialize-HPEGreenLakeSharedKey.ps1 -Force first."
}

Import-Module $ModulePath -Force
try {
    $record = Get-GatewayDpapiRecord -Path $CredentialFile
} catch {
    throw 'The protected HPEGreenLake credential could not be loaded.'
}

$names = @(
    'AUTH_URL'
    'AUTH_METHOD'
    'CLIENT_ID'
    'CLIENT_SECRET'
    'SCOPE'
    'API_BASE_URL'
    'USERNAME'
    'PASSWORD'
    'OPENAPI_SPEC_URL'
    'SERVER_NAME'
)
foreach ($name in $names) {
    Remove-Item -Path "Env:$name" -ErrorAction SilentlyContinue
    if ($record.PSObject.Properties.Name -contains $name) {
        Set-Item -Path "Env:$name" -Value ([string]$record.$name)
    }
}
Remove-Item -Path 'Env:HPEGREENLAKE_ENV_FILE' -ErrorAction SilentlyContinue
$env:HPEGREENLAKE_NO_DOTENV = 'true'

$nodeCommand = Get-Command node -ErrorAction Stop
& $nodeCommand.Source $Script
exit $LASTEXITCODE
