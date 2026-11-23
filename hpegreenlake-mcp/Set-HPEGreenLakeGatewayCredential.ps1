<#
.SYNOPSIS
    Set or rotate the DPAPI-protected HPE GreenLake client secret.

.DESCRIPTION
    Prompts locally for the GreenLake client secret (and password grant password
    when applicable). Non-secret settings are preserved from the existing DPAPI
    record. Run Initialize-HPEGreenLakeSharedKey.ps1 first if no record exists.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$BridgeDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = Split-Path -Parent $BridgeDir
$SecretsDir = Join-Path $RootDir 'secrets'
$CredentialFile = Join-Path $SecretsDir 'hpegreenlake-gateway.xml'
$ModulePath = Join-Path $RootDir 'scripts\GatewayDpapi.psm1'
$AclHelper = Join-Path $BridgeDir 'Set-RestrictedSecretAcl.ps1'

Import-Module $ModulePath -Force

if (-not (Test-Path -LiteralPath $CredentialFile)) {
    throw 'No protected HPEGreenLake record exists. Run Initialize-HPEGreenLakeSharedKey.ps1 -Force first.'
}

$config = ConvertTo-GatewayHashtable (Get-GatewayDpapiRecord -Path $CredentialFile)

Write-Host 'HPEGreenLake MCP server-side credential setup' -ForegroundColor Cyan
Write-Host 'The client secret is masked and protected with Windows DPAPI.' -ForegroundColor Yellow
Write-Host 'Do not paste secrets into chat or any client configuration.'
Write-Host ''

$secureSecret = Read-Host 'GreenLake client secret' -AsSecureString
$plainSecret = Read-GatewaySecureString -SecureString $secureSecret
$plainPassword = $null

try {
    if ([string]::IsNullOrWhiteSpace($plainSecret)) {
        throw 'A client secret is required.'
    }
    $config['CLIENT_SECRET'] = $plainSecret

    if ($config.ContainsKey('AUTH_METHOD') -and $config['AUTH_METHOD'] -ieq 'password') {
        if (-not $config['USERNAME']) {
            $config['USERNAME'] = Read-Host 'GreenLake password-grant username'
        }
        $securePassword = Read-Host 'GreenLake password-grant password' -AsSecureString
        $plainPassword = Read-GatewaySecureString -SecureString $securePassword
        if ([string]::IsNullOrWhiteSpace($plainPassword)) {
            throw 'A password-grant password is required.'
        }
        $config['PASSWORD'] = $plainPassword
    }

    New-GatewayDpapiRecord -Path $CredentialFile -Config $config -Label 'hpegreenlake-gateway'
    & $AclHelper -Path $SecretsDir -Directory
    & $AclHelper -Path $CredentialFile

    Write-Host ''
    Write-Host "Stored protected credential in $CredentialFile"
    Write-Host 'Credential values were not displayed.'
    Write-Host 'Restart the bridge with Stop-HPEGreenLakeBridge.ps1 and Start-HPEGreenLakeBridge.ps1.'
} catch {
    throw 'The HPEGreenLake credential could not be stored.'
} finally {
    $plainSecret = $null
    $plainPassword = $null
}
