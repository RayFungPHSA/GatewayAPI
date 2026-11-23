<#
.SYNOPSIS
    Run the Lansweeper stdio MCP server directly for local debugging.

.DESCRIPTION
    Loads the server-only credential from the DPAPI-protected record, then
    launches src\server.js with Node. This is not needed for normal gateway
    use; Start-LansweeperBridge.ps1 is the server entry point.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$BridgeDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = Split-Path -Parent $BridgeDir
$ModulePath = Join-Path $RootDir 'scripts\GatewayDpapi.psm1'
$CredentialFile = Join-Path $RootDir 'secrets\lansweeper-gateway.xml'
$Script = Join-Path $BridgeDir 'src\server.js'

if (-not (Test-Path -LiteralPath $CredentialFile)) {
    throw "Missing protected credential record: $CredentialFile. Run Initialize-LansweeperSharedKey.ps1 -Force first."
}

Import-Module $ModulePath -Force
try {
    $record = Get-GatewayDpapiRecord -Path $CredentialFile
} catch {
    throw 'The protected Lansweeper credential could not be loaded.'
}

$names = @(
    'LANSWEEPER_URL'
    'LANSWEEPER_USERNAME'
    'LANSWEEPER_PASSWORD'
    'LANSWEEPER_ALLOW_INVALID_CERT'
    'LANSWEEPER_TIMEOUT_MS'
    'LANSWEEPER_ASSET_PATHS'
)
foreach ($name in $names) {
    Remove-Item -Path "Env:$name" -ErrorAction SilentlyContinue
    if ($record.PSObject.Properties.Name -contains $name) {
        Set-Item -Path "Env:$name" -Value ([string]$record.$name)
    }
}
Remove-Item -Path 'Env:LANSWEEPER_ENV_FILE' -ErrorAction SilentlyContinue

$nodeCommand = Get-Command node -ErrorAction Stop
& $nodeCommand.Source $Script
exit $LASTEXITCODE
