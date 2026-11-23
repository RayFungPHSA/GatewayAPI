<#
.SYNOPSIS
    Return the server-side vSphere credential to the local Node MCP process.

.DESCRIPTION
    Reads the DPAPI-protected credential file and server list from
    C:\caddy-gateway\secrets. Output is JSON on stdout and is consumed only by
    src\credentials.mjs. Errors are deliberately generic so the username,
    password, or file contents can never be exposed in MCP tool results or logs.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$BridgeDir = Split-Path -Parent $PSScriptRoot
$RootDir = Split-Path -Parent $BridgeDir
$SecretsDir = Join-Path $RootDir 'secrets'
$CredentialFile = Join-Path $SecretsDir 'vsphere.xml'
$ServerFile = Join-Path $SecretsDir 'vsphere-server.txt'

if (-not (Test-Path -LiteralPath $CredentialFile) -or -not (Test-Path -LiteralPath $ServerFile)) {
    throw 'The protected vSphere credential record is not configured.'
}

try {
    $credential = Import-Clixml -LiteralPath $CredentialFile
    $servers = @(Get-Content -LiteralPath $ServerFile |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ })

    $username = [string]$credential.UserName
    $password = [string]$credential.GetNetworkCredential().Password

    if (-not $username -or -not $password -or $servers.Count -eq 0) {
        throw 'The protected vSphere credential record is incomplete.'
    }

    $result = [pscustomobject]@{
        server  = $servers[0]
        servers = $servers
        username = $username
        password = $password
    }

    # Write through the PowerShell pipeline so callers can capture the JSON and
    # so a failed parse cannot leak it to an interactive console by accident.
    [Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
    Write-Output ($result | ConvertTo-Json -Compress -Depth 4)
} catch {
    throw 'The protected vSphere credential record could not be loaded.'
}
