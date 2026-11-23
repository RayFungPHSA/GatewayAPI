<#
.SYNOPSIS
    Set or rotate the DPAPI-protected Cohesity/Helios API key.

.DESCRIPTION
    Prompts locally for the API key. The value is wrapped in a PSCredential and
    written with Export-Clixml to C:\caddy-gateway\secrets\cohesity-gateway.xml.
    The password is never accepted as a parameter, echoed, or written to a
    plain-text file. Run as the same Windows account that starts the bridge.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$BridgeDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = Split-Path -Parent $BridgeDir
$SecretsDir = Join-Path $RootDir 'secrets'
$CredentialFile = Join-Path $SecretsDir 'cohesity-gateway.xml'
$ModulePath = Join-Path $RootDir 'scripts\GatewayDpapi.psm1'
$AclHelper = Join-Path $BridgeDir 'Set-RestrictedSecretAcl.ps1'

Import-Module $ModulePath -Force

$config = @{}
if (Test-Path -LiteralPath $CredentialFile) {
    try { $config = ConvertTo-GatewayHashtable (Get-GatewayDpapiRecord -Path $CredentialFile) } catch { $config = @{} }
}

Write-Host 'Cohesity MCP server-side credential setup' -ForegroundColor Cyan
Write-Host 'The API key is masked and protected with Windows DPAPI.' -ForegroundColor Yellow
Write-Host 'Do not paste the key into chat or any client configuration.'
Write-Host ''

$secureKey = Read-Host 'Cohesity/Helios API key' -AsSecureString
$plainKey = Read-GatewaySecureString -SecureString $secureKey

try {
    if ([string]::IsNullOrWhiteSpace($plainKey)) {
        throw 'An API key is required.'
    }
    $config['COHESITY_API_KEY'] = $plainKey

    New-Item -ItemType Directory -Path $SecretsDir -Force | Out-Null
    New-GatewayDpapiRecord -Path $CredentialFile -Config $config -Label 'cohesity-gateway'
    & $AclHelper -Path $SecretsDir -Directory
    & $AclHelper -Path $CredentialFile

    Write-Host ''
    Write-Host "Stored protected credential in $CredentialFile"
    Write-Host 'Credential value was not displayed.'
    Write-Host 'Restart the bridge with Stop-CohesityMcpBridge.ps1 and Start-CohesityMcpBridge.ps1.'
} catch {
    throw 'The Cohesity credential could not be stored.'
} finally {
    $plainKey = $null
}
