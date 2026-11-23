<#
.SYNOPSIS
    Return the server-only HPE GreenLake credential to the local Python bridge.

.DESCRIPTION
    Reads the DPAPI-protected credential record from C:\caddy-gateway\secrets
    and emits one compact JSON line on stdout. Errors are generic so the client
    secret can never be disclosed through MCP results or logs.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$BridgeDir = Split-Path -Parent $PSScriptRoot
$RootDir = Split-Path -Parent $BridgeDir
$ModulePath = Join-Path $RootDir 'scripts\GatewayDpapi.psm1'
$CredentialFile = Join-Path $RootDir 'secrets\hpegreenlake-gateway.xml'
$AllowedNames = @(
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
$RequiredNames = @('AUTH_URL', 'CLIENT_ID', 'CLIENT_SECRET')

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
    throw 'The protected HPEGreenLake credential record could not be loaded.'
}
