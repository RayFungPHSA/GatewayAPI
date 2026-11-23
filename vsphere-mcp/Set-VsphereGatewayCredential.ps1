<#
.SYNOPSIS
    Configure or rotate the server-side domain credential used by vSphere MCP.

.DESCRIPTION
    Prompts locally for the vCenter/domain username and password. The password
    is masked and stored only in a DPAPI-protected XML file restricted to the
    current Windows user, SYSTEM, and Administrators. It is never accepted from
    chat, client configs, prompts, Caddy, or MCP request headers.

    Run this on the gateway host as the same Windows account that starts
    Start-VsphereBridge.ps1. DPAPI records cannot be decrypted by a different
    Windows account.
#>
[CmdletBinding()]
param(
    [string[]]$Servers = @(
        'https://vapvc101.healthbc.org'
        'https://vapvc401.healthbc.org'
        'https://vapvc501.healthbc.org'
        'https://vapvc701.healthbc.org'
        'https://vapvc703.healthbc.org'
        'https://vapvcvd702.healthbc.org'
    )
)

$ErrorActionPreference = 'Stop'

$BridgeDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = Split-Path -Parent $BridgeDir
$SecretsDir = Join-Path $RootDir 'secrets'
$CredentialFile = Join-Path $SecretsDir 'vsphere.xml'
$ServerFile = Join-Path $SecretsDir 'vsphere-server.txt'
$AclHelper = Join-Path $BridgeDir 'Set-RestrictedSecretAcl.ps1'

Write-Host 'vSphere MCP server-side credential setup' -ForegroundColor Cyan
Write-Host 'The password is masked and protected with Windows DPAPI.' -ForegroundColor Yellow
Write-Host 'Do not paste the password into chat or any client configuration.'
Write-Host ''

$username = Read-Host 'vSphere domain username (DOMAIN\user or user@domain)'
$securePassword = Read-Host 'vSphere password' -AsSecureString

if ([string]::IsNullOrWhiteSpace($username) -or $securePassword.Length -eq 0) {
    throw 'A username and password are required.'
}
if (@($Servers | Where-Object { $_ }).Count -eq 0) {
    throw 'At least one vCenter server URL is required.'
}

$credential = New-Object PSCredential($username, $securePassword)

New-Item -ItemType Directory -Path $SecretsDir -Force | Out-Null

$credential | Export-Clixml -LiteralPath $CredentialFile -Force
$Servers | Set-Content -LiteralPath $ServerFile -Encoding UTF8

& $AclHelper -Path $SecretsDir -Directory
& $AclHelper -Path $CredentialFile
& $AclHelper -Path $ServerFile

Write-Host ''
Write-Host "Stored protected credential in $CredentialFile"
Write-Host "Stored server list in $ServerFile"
Write-Host 'Credential values were not displayed.'
Write-Host 'Restart the bridge with Stop-VsphereBridge.ps1 and Start-VsphereBridge.ps1.'
