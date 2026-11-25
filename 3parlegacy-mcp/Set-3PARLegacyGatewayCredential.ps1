<#
.SYNOPSIS
    Configure or rotate the server-side 3PAR credential used by 3PARLegacy MCP.

.DESCRIPTION
    Prompts locally for the 3PAR password. The username defaults to 'metrics'
    and the password is masked. The password is stored only in a
    DPAPI-protected XML file restricted to the current Windows user, SYSTEM,
    and Administrators. It is never accepted from chat, client configs,
    prompts, Caddy, or MCP request headers.

    The array list is stored in a separate restricted JSON file. This MCP is
    scoped to the legacy arrays JPN3PAR01 and cw3par02.phsabc.ehcnet.ca. Other
    arrays are served by the HPEGreenLake MCP and are not registered here.

    Run this on the gateway host as the same Windows account that starts
    Start-3PARLegacyBridge.ps1. DPAPI records cannot be decrypted by a
    different Windows account.
#>
[CmdletBinding()]
param(
    [string]$Username = 'metrics'
)

$ErrorActionPreference = 'Stop'

$BridgeDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = Split-Path -Parent $BridgeDir
$SecretsDir = Join-Path $RootDir 'secrets'
$CredentialFile = Join-Path $SecretsDir '3parlegacy.xml'
$ServerFile = Join-Path $SecretsDir '3parlegacy-servers.json'
$AclHelper = Join-Path $BridgeDir 'Set-RestrictedSecretAcl.ps1'

$Servers = @(
    [pscustomobject]@{ name = 'JPN3PAR01'; url = 'https://142.71.40.232' }
    [pscustomobject]@{ name = 'cw3par02.phsabc.ehcnet.ca'; url = 'https://cw3par02.phsabc.ehcnet.ca:8080' }
)

Write-Host '3PARLegacy MCP server-side credential setup' -ForegroundColor Cyan
Write-Host "Username: $Username" -ForegroundColor Yellow
Write-Host 'The password is masked and protected with Windows DPAPI.' -ForegroundColor Yellow
Write-Host 'Do not paste the password into chat or any client configuration.'
Write-Host ''

$securePassword = Read-Host "Password for 3PAR user '$Username'" -AsSecureString
if ([string]::IsNullOrWhiteSpace($Username) -or $securePassword.Length -eq 0) {
    throw 'A username and password are required.'
}
if ($Servers.Count -eq 0) {
    throw 'At least one 3PAR array is required.'
}

$credential = New-Object PSCredential($Username, $securePassword)

New-Item -ItemType Directory -Path $SecretsDir -Force | Out-Null

$credential | Export-Clixml -LiteralPath $CredentialFile -Force
ConvertTo-Json -InputObject $Servers -Depth 4 | Set-Content -LiteralPath $ServerFile -Encoding UTF8

& $AclHelper -Path $SecretsDir -Directory
& $AclHelper -Path $CredentialFile
& $AclHelper -Path $ServerFile

Write-Host ''
Write-Host "Stored protected credential in $CredentialFile"
Write-Host "Stored array list in $ServerFile"
Write-Host 'Credential values were not displayed.'
Write-Host 'Restart the bridge with Stop-3PARLegacyBridge.ps1 and Start-3PARLegacyBridge.ps1.'
