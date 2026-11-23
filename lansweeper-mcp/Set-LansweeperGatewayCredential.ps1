<#
.SYNOPSIS
    Set or rotate the DPAPI-protected Lansweeper AD password.

.DESCRIPTION
    Prompts locally for the Lansweeper Windows/AD password. Non-secret settings
    are preserved from the existing DPAPI record. Run
    Initialize-LansweeperSharedKey.ps1 first if no record exists.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$BridgeDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = Split-Path -Parent $BridgeDir
$SecretsDir = Join-Path $RootDir 'secrets'
$CredentialFile = Join-Path $SecretsDir 'lansweeper-gateway.xml'
$ModulePath = Join-Path $RootDir 'scripts\GatewayDpapi.psm1'
$AclHelper = Join-Path $BridgeDir 'Set-RestrictedSecretAcl.ps1'

Import-Module $ModulePath -Force

if (-not (Test-Path -LiteralPath $CredentialFile)) {
    throw 'No protected Lansweeper record exists. Run Initialize-LansweeperSharedKey.ps1 -Force first.'
}

$config = ConvertTo-GatewayHashtable (Get-GatewayDpapiRecord -Path $CredentialFile)

Write-Host 'Lansweeper MCP server-side credential setup' -ForegroundColor Cyan
Write-Host 'The AD password is masked and protected with Windows DPAPI.' -ForegroundColor Yellow
Write-Host 'Do not paste the password into chat or any client configuration.'
Write-Host ''

$securePassword = Read-Host 'Lansweeper AD password' -AsSecureString
$plainPassword = Read-GatewaySecureString -SecureString $securePassword

try {
    if ([string]::IsNullOrWhiteSpace($plainPassword)) {
        throw 'A password is required.'
    }
    $config['LANSWEEPER_PASSWORD'] = $plainPassword

    New-GatewayDpapiRecord -Path $CredentialFile -Config $config -Label 'lansweeper-gateway'
    & $AclHelper -Path $SecretsDir -Directory
    & $AclHelper -Path $CredentialFile

    Write-Host ''
    Write-Host "Stored protected credential in $CredentialFile"
    Write-Host 'Credential value was not displayed.'
    Write-Host 'Restart the bridge with Stop-LansweeperBridge.ps1 and Start-LansweeperBridge.ps1.'
} catch {
    throw 'The Lansweeper credential could not be stored.'
} finally {
    $plainPassword = $null
}
