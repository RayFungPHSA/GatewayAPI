<#
.SYNOPSIS
    Restrict a secrets file/folder to the current user, SYSTEM, and Administrators.

    Uses icacls with *SID syntax so domain account names do not need to resolve.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Path,
    [switch]$Directory
)

$ErrorActionPreference = 'Stop'

$currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$systemSid = 'S-1-5-18'
$adminsSid = 'S-1-5-32-544'
$permission = if ($Directory) { '(OI)(CI)(F)' } else { '(F)' }

& icacls $Path /inheritance:r /grant:r `
    "*${currentSid}:${permission}" `
    "*${systemSid}:${permission}" `
    "*${adminsSid}:${permission}" 2>&1 | Out-Null

if ($LASTEXITCODE -ne 0) {
    throw "Failed to restrict ACL on $Path"
}
