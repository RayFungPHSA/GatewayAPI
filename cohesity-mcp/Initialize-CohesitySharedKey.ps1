<#
.SYNOPSIS
    Creates the DPAPI-protected server-only Cohesity key record.

.DESCRIPTION
    Reuses the existing key from a local KEY=VALUE source (by default the source
    project's .env). The value is written only to
    C:\caddy-gateway\secrets\cohesity-gateway.xml as a DPAPI-protected
    PSCredential with an NTFS ACL restricted to the current user, SYSTEM, and
    Administrators. No plain-text env file is created and values are not
    displayed.
#>
[CmdletBinding()]
param(
    [string]$FromPath = 'C:\Code\CStorageDashboard\mcp-configs\cohesity\.env',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$BridgeDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = Split-Path -Parent $BridgeDir
$SecretsDir = Join-Path $RootDir 'secrets'
$CredentialFile = Join-Path $SecretsDir 'cohesity-gateway.xml'
$ModulePath = Join-Path $RootDir 'scripts\GatewayDpapi.psm1'
$AclHelper = Join-Path $BridgeDir 'Set-RestrictedSecretAcl.ps1'

if (-not (Test-Path -LiteralPath $FromPath)) {
    throw "Source credential file not found: $FromPath"
}

if ((Test-Path -LiteralPath $CredentialFile) -and -not $Force) {
    throw "$CredentialFile already exists. Use -Force to replace it."
}

Import-Module $ModulePath -Force

$key = $null
foreach ($line in Get-Content -LiteralPath $FromPath) {
    if ($line -match '^\s*(?:export\s+)?COHESITY_API_KEY\s*=\s*(.*?)\s*$') {
        $key = $Matches[1]
        break
    }
}

if (-not $key) {
    throw "COHESITY_API_KEY was not found in $FromPath"
}

if (($key.StartsWith('"') -and $key.EndsWith('"')) -or
    ($key.StartsWith("'") -and $key.EndsWith("'"))) {
    $key = $key.Substring(1, $key.Length - 2)
}

if ($key.StartsWith('${') -or $key.StartsWith('{env:')) {
    throw "$FromPath still contains an unexpanded placeholder, not a real key."
}

try {
    New-Item -ItemType Directory -Path $SecretsDir -Force | Out-Null
    New-GatewayDpapiRecord -Path $CredentialFile -Config @{ COHESITY_API_KEY = $key } -Label 'cohesity-gateway'
    & $AclHelper -Path $SecretsDir -Directory
    & $AclHelper -Path $CredentialFile
} catch {
    throw 'The Cohesity credential could not be stored.'
} finally {
    $key = $null
}

Write-Host "Created $CredentialFile"
Write-Host 'The key was not displayed and no plain-text env file was written.'
