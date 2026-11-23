<#
.SYNOPSIS
    Return the server-only Cohesity credential to the local Python bridge.

.DESCRIPTION
    Reads the DPAPI-protected credential record from C:\caddy-gateway\secrets
    and emits one compact JSON line on stdout. Errors are generic so the API key
    can never be disclosed through MCP results or logs.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$BridgeDir = Split-Path -Parent $PSScriptRoot
$RootDir = Split-Path -Parent $BridgeDir
$ModulePath = Join-Path $RootDir 'scripts\GatewayDpapi.psm1'
$CredentialFile = Join-Path $RootDir 'secrets\cohesity-gateway.xml'
$AllowedNames = @('COHESITY_API_KEY')

Import-Module $ModulePath -Force

try {
    $record = Get-GatewayDpapiRecord -Path $CredentialFile
    $result = [ordered]@{}
    foreach ($name in $AllowedNames) {
        if ($record.PSObject.Properties.Name -contains $name) {
            $result[$name] = [string]$record.$name
        }
    }
    if (-not $result['COHESITY_API_KEY']) {
        throw 'Incomplete record'
    }
    [Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
    Write-Output ($result | ConvertTo-Json -Compress -Depth 10)
} catch {
    throw 'The protected Cohesity credential record could not be loaded.'
}
