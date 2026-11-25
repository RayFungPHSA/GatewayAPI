<#
.SYNOPSIS
    Configure or rotate the server-side HPE XP Performance Advisor credential.

.DESCRIPTION
    By default this imports the existing DPAPI-protected credential from the
    old CStorageDashboard hpe-xppa project into the gateway's restricted
    secrets directory. Use -PromptPassword to rotate it locally with masked
    input instead.

    The password is never accepted from chat, client configs, prompts, Caddy,
    or MCP request headers. The array list is stored separately and contains
    only the two XP Performance Advisor base URLs.

    Run on the gateway host as the same Windows account that starts
    Start-HPEXP8Bridge.ps1. DPAPI records cannot be decrypted by another
    Windows account.
#>
[CmdletBinding()]
param(
    [string]$SourceCredentialFile = 'C:\Code\CStorageDashboard\credentials\xppa.xml',
    [string]$Username = 'administrator',
    [switch]$PromptPassword
)

$ErrorActionPreference = 'Stop'

$BridgeDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = Split-Path -Parent $BridgeDir
$SecretsDir = Join-Path $RootDir 'secrets'
$CredentialFile = Join-Path $SecretsDir 'hpexp8.xml'
$ServerFile = Join-Path $SecretsDir 'hpexp8-servers.json'
$AclHelper = Join-Path $BridgeDir 'Set-RestrictedSecretAcl.ps1'

$Servers = @(
    [pscustomobject]@{ name = 'spapphpxp001.healthbc.org'; url = 'http://spapphpxp001.healthbc.org/pa' }
    [pscustomobject]@{ name = 'spapphpxp003.fraserhealth.org'; url = 'http://spapphpxp003.fraserhealth.org/pa' }
)

Write-Host 'HPEXP8 MCP server-side credential setup' -ForegroundColor Cyan

if ($PromptPassword -or -not (Test-Path -LiteralPath $SourceCredentialFile)) {
    if (-not $PromptPassword) {
        Write-Warning "Source credential not found: $SourceCredentialFile. Prompting for a password instead."
    }
    if ([string]::IsNullOrWhiteSpace($Username)) {
        throw 'A username is required when prompting for a password.'
    }
    Write-Host "Username: $Username" -ForegroundColor Yellow
    Write-Host 'The password is masked and protected with Windows DPAPI.' -ForegroundColor Yellow
    Write-Host 'Do not paste the password into chat or any client configuration.'
    $securePassword = Read-Host "Password for XP Performance Advisor user '$Username'" -AsSecureString
    if ($securePassword.Length -eq 0) { throw 'A password is required.' }
    $credential = New-Object PSCredential($Username, $securePassword)
} else {
    Write-Host 'Importing the protected credential from the existing hpe-xppa record.'
    $credential = Import-Clixml -LiteralPath $SourceCredentialFile
    if (-not $credential.UserName) { throw 'The source credential record is incomplete.' }
    Write-Host "Imported user: $($credential.UserName)"
}

New-Item -ItemType Directory -Path $SecretsDir -Force | Out-Null

$credential | Export-Clixml -LiteralPath $CredentialFile -Force
ConvertTo-Json -InputObject $Servers -Depth 4 | Set-Content -LiteralPath $ServerFile -Encoding UTF8

& $AclHelper -Path $SecretsDir -Directory
& $AclHelper -Path $CredentialFile
& $AclHelper -Path $ServerFile

Write-Host ''
Write-Host "Stored protected credential in $CredentialFile"
Write-Host "Stored server list in $ServerFile"
Write-Host 'Credential values were not displayed.'
Write-Host 'Restart the bridge with Stop-HPEXP8Bridge.ps1 and Start-HPEXP8Bridge.ps1.'
