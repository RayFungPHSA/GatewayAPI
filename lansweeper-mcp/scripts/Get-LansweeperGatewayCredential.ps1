<#
.SYNOPSIS
    Return the server-only Lansweeper credential to the local Python bridge.

.DESCRIPTION
    Reads the DPAPI-protected credential record from C:\caddy-gateway\secrets
    and emits one compact JSON line on stdout. Errors are generic so the AD
    password can never be disclosed through MCP results or logs.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$BridgeDir = Split-Path -Parent $PSScriptRoot
$RootDir = Split-Path -Parent $BridgeDir
$ModulePath = Join-Path $RootDir 'scripts\GatewayDpapi.psm1'
$CredentialFile = Join-Path $RootDir 'secrets\lansweeper-gateway.xml'
$AllowedNames = @(
    'LANSWEEPER_URL'
    'LANSWEEPER_USERNAME'
    'LANSWEEPER_PASSWORD'
    'LANSWEEPER_ALLOW_INVALID_CERT'
    'LANSWEEPER_TIMEOUT_MS'
    'LANSWEEPER_ASSET_PATHS'
)
$RequiredNames = @('LANSWEEPER_URL', 'LANSWEEPER_USERNAME', 'LANSWEEPER_PASSWORD')

Import-Module $ModulePath -Force

try {
    $record = Get-GatewayDpapiRecord -Path $CredentialFile
    $result = [ordered]@{}
    foreach ($name in $AllowedNames) {
        if ($record.PSObject.Properties.Name -contains $name) {
            $result[$name] = [string]$record.$name
        }
    }
    foreach ($name in $RequiredNames) {
        if (-not $result[$name]) { throw 'Incomplete record' }
    }
    [Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
    Write-Output ($result | ConvertTo-Json -Compress -Depth 10)
} catch {
    throw 'The protected Lansweeper credential record could not be loaded.'
}
