<#
.SYNOPSIS
    Return the server-side 3PAR credential to the local 3PARLegacy MCP process.

.DESCRIPTION
    Reads the DPAPI-protected credential file and restricted array list from
    C:\caddy-gateway\secrets. Output is JSON on stdout and is consumed only by
    the local Python MCP process. Errors are deliberately generic so the
    username, password, or file contents can never be exposed in MCP tool
    results or logs.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$BridgeDir = Split-Path -Parent $PSScriptRoot
$RootDir = Split-Path -Parent $BridgeDir
$SecretsDir = Join-Path $RootDir 'secrets'
$CredentialFile = Join-Path $SecretsDir '3parlegacy.xml'
$ServerFile = Join-Path $SecretsDir '3parlegacy-servers.json'

if (-not (Test-Path -LiteralPath $CredentialFile) -or -not (Test-Path -LiteralPath $ServerFile)) {
    throw 'The protected 3PARLegacy credential record is not configured.'
}

try {
    $credential = Import-Clixml -LiteralPath $CredentialFile
    $parsedServers = Get-Content -LiteralPath $ServerFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $servers = @()
    foreach ($server in $parsedServers) { $servers += $server }

    $username = [string]$credential.UserName
    $password = [string]$credential.GetNetworkCredential().Password

    if (-not $username -or -not $password -or $servers.Count -eq 0) {
        throw 'The protected 3PARLegacy credential record is incomplete.'
    }

    $result = [pscustomobject]@{
        username = $username
        password = $password
        servers  = $servers
    }

    [Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
    Write-Output ($result | ConvertTo-Json -Compress -Depth 6)
} catch {
    throw 'The protected 3PARLegacy credential record could not be loaded.'
}
