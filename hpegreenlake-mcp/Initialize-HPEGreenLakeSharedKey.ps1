<#
.SYNOPSIS
    Creates the DPAPI-protected server-only HPEGreenLake credential record.

.DESCRIPTION
    Reuses approved GreenLake OAuth variables from a local KEY=VALUE source
    (by default the source project's .env). Values are written only to
    C:\caddy-gateway\secrets\hpegreenlake-gateway.xml as a DPAPI-protected
    PSCredential with an NTFS ACL restricted to the current user, SYSTEM, and
    Administrators. No plain-text env file is created and values are not
    displayed.
#>
[CmdletBinding()]
param(
    [string]$FromPath = 'C:\Code\CStorageDashboard\mcp-configs\hpe-fleet\.env',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$BridgeDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = Split-Path -Parent $BridgeDir
$SecretsDir = Join-Path $RootDir 'secrets'
$CredentialFile = Join-Path $SecretsDir 'hpegreenlake-gateway.xml'
$ModulePath = Join-Path $RootDir 'scripts\GatewayDpapi.psm1'
$AclHelper = Join-Path $BridgeDir 'Set-RestrictedSecretAcl.ps1'

if (-not (Test-Path -LiteralPath $FromPath)) {
    throw "Source credential file not found: $FromPath"
}

if ((Test-Path -LiteralPath $CredentialFile) -and -not $Force) {
    throw "$CredentialFile already exists. Use -Force to replace it."
}

Import-Module $ModulePath -Force

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
$values = @{}

foreach ($line in Get-Content -LiteralPath $FromPath) {
    if ($line -match '^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$') {
        $name = $Matches[1]
        if ($AllowedNames -notcontains $name) { continue }

        $value = $Matches[2].Trim()
        $value = ($value -replace '\s+#.*$', '').Trim()
        if (($value.StartsWith('"') -and $value.EndsWith('"')) -or
            ($value.StartsWith("'") -and $value.EndsWith("'"))) {
            $value = $value.Substring(1, $value.Length - 2)
        }
        if ($value.StartsWith('${') -or $value.StartsWith('{env:')) {
            throw "$name in $FromPath is still an unexpanded placeholder, not a real credential."
        }
        $values[$name] = $value
    }
}

foreach ($name in $RequiredNames) {
    if (-not $values.ContainsKey($name) -or [string]::IsNullOrWhiteSpace($values[$name])) {
        throw "$name was not found or is empty in $FromPath."
    }
}

if ($values.ContainsKey('AUTH_METHOD') -and $values['AUTH_METHOD'] -ieq 'password') {
    foreach ($name in @('USERNAME', 'PASSWORD')) {
        if (-not $values.ContainsKey($name) -or [string]::IsNullOrWhiteSpace($values[$name])) {
            throw "$name is required when AUTH_METHOD=password."
        }
    }
}

$copiedNames = @($AllowedNames | Where-Object { $values.ContainsKey($_) })

try {
    New-Item -ItemType Directory -Path $SecretsDir -Force | Out-Null
    New-GatewayDpapiRecord -Path $CredentialFile -Config $values -Label 'hpegreenlake-gateway'
    & $AclHelper -Path $SecretsDir -Directory
    & $AclHelper -Path $CredentialFile
} catch {
    throw 'The HPEGreenLake credential could not be stored.'
} finally {
    $values.Clear()
}

Write-Host "Created $CredentialFile"
Write-Host "Copied credential variables: $($copiedNames -join ', ')"
Write-Host 'Credential values were not displayed and no plain-text env file was written.'
