<#
.SYNOPSIS
    Return the server-side Brocade SANnav credential to the local bridge.

.DESCRIPTION
    Reads the DPAPI-protected credential and restricted endpoint file from
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
$CredentialFile = Join-Path $SecretsDir 'brocade.xml'
$ServerFile = Join-Path $SecretsDir 'brocade-servers.json'

if (-not (Test-Path -LiteralPath $CredentialFile) -or -not (Test-Path -LiteralPath $ServerFile)) {
    throw 'The protected Brocade credential record is not configured.'
}

try {
    $credential = Import-Clixml -LiteralPath $CredentialFile
    $server = Get-Content -LiteralPath $ServerFile -Raw -Encoding UTF8 | ConvertFrom-Json

    $username = [string]$credential.UserName
    $password = [string]$credential.GetNetworkCredential().Password
    $hostName = [string]$server.host
    $port = [int]$server.port

    if (-not $username -or -not $password -or -not $hostName -or $port -lt 1 -or $port -gt 65535) {
        throw 'The protected Brocade credential record is incomplete.'
    }

    $result = [pscustomobject]@{
        username = $username
        password = $password
        server   = [pscustomobject]@{
            name = [string]$server.name
            host = $hostName
            port = $port
            url  = "https://${hostName}:$port"
        }
    }

    [Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
    Write-Output ($result | ConvertTo-Json -Compress -Depth 6)
} catch {
    throw 'The protected Brocade credential record could not be loaded.'
}
