<#
.SYNOPSIS
    Copies the existing DPAPI-protected vSphere credential into the gateway secrets folder.

.DESCRIPTION
    Reuses the Windows domain credential already configured for
    CStorageDashboard. Only the two protected files are copied; the username
    and password are not displayed or written to any new plain-text file.

    The destination files are NTFS-restricted to the current user, SYSTEM, and
    Administrators. Run Start-VsphereBridge.ps1 as the same Windows user that
    created the source DPAPI record.
#>
[CmdletBinding()]
param(
    [string]$CredentialPath = 'C:\Code\CStorageDashboard\credentials\vsphere.xml',
    [string]$ServerPath = 'C:\Code\CStorageDashboard\credentials\vsphere-server.txt',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$BridgeDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = Split-Path -Parent $BridgeDir
$SecretsDir = Join-Path $RootDir 'secrets'
$CredentialFile = Join-Path $SecretsDir 'vsphere.xml'
$ServerFile = Join-Path $SecretsDir 'vsphere-server.txt'
$AclHelper = Join-Path $BridgeDir 'Set-RestrictedSecretAcl.ps1'

foreach ($source in @($CredentialPath, $ServerPath)) {
    if (-not (Test-Path -LiteralPath $source)) {
        throw "Source credential file not found: $source"
    }
}

if (((Test-Path -LiteralPath $CredentialFile) -or (Test-Path -LiteralPath $ServerFile)) -and -not $Force) {
    throw "Gateway vSphere credential files already exist. Use -Force to replace them."
}

New-Item -ItemType Directory -Path $SecretsDir -Force | Out-Null

Copy-Item -LiteralPath $CredentialPath -Destination $CredentialFile -Force
Copy-Item -LiteralPath $ServerPath -Destination $ServerFile -Force

& $AclHelper -Path $SecretsDir -Directory
& $AclHelper -Path $CredentialFile
& $AclHelper -Path $ServerFile

Write-Host "Created $CredentialFile"
Write-Host "Created $ServerFile"
Write-Host 'Protected credential files were copied; credential values were not displayed.'
