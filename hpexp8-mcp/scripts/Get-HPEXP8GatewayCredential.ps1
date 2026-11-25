<#
.SYNOPSIS
    Return the server-side XP Performance Advisor credential to the local bridge.

.DESCRIPTION
    Reads the DPAPI-protected credential and restricted server list from
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
$CredentialFile = Join-Path $SecretsDir 'hpexp8.xml'
$ServerFile = Join-Path $SecretsDir 'hpexp8-servers.json'

if (-not (Test-Path -LiteralPath $CredentialFile) -or -not (Test-Path -LiteralPath $ServerFile)) {
    throw 'The protected HPEXP8 credential record is not configured.'
}

try {
    $credential = Import-Clixml -LiteralPath $CredentialFile
    $parsedServers = Get-Content -LiteralPath $ServerFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $servers = @()
    foreach ($server in $parsedServers) { $servers += $server }

    $username = [string]$credential.UserName
    $password = [string]$credential.GetNetworkCredential().Password

    if (-not $username -or -not $password -or $servers.Count -eq 0) {
        throw 'The protected HPEXP8 credential record is incomplete.'
    }

    $result = [pscustomobject]@{
        username = $username
        password = $password
        servers  = $servers
    }

    [Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
    Write-Output ($result | ConvertTo-Json -Compress -Depth 6)
} catch {
    throw 'The protected HPEXP8 credential record could not be loaded.'
}
