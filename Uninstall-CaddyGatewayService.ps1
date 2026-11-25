<#
.SYNOPSIS
    Removes the CaddyGateway Windows Service.

.DESCRIPTION
    Must be run from an elevated PowerShell window. It stops and deletes the
    service but leaves all gateway files, logs, credential records, scripts,
    and scheduled tasks untouched. The "Log on as a service" right is not
    revoked because other services may rely on it.

.EXAMPLE
    # Run from an elevated PowerShell prompt:
    .\Uninstall-CaddyGatewayService.ps1
#>
[CmdletBinding()]
param(
    [string]$ServiceName = 'CaddyGateway',
    [switch]$StopGateways
)

$ErrorActionPreference = 'Stop'

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this script from an elevated PowerShell window (Run as Administrator).'
}

$service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if (-not $service) {
    Write-Host "Service '$ServiceName' is not installed. Nothing to do."
} else {
    if ($service.Status -ne 'Stopped') {
        Write-Host "==> Stopping service '$ServiceName'"
        Stop-Service -Name $ServiceName -Force
    }
    Write-Host "==> Deleting service '$ServiceName'"
    & sc.exe delete $ServiceName | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "sc.exe delete failed with exit code $LASTEXITCODE." }
}

if ($StopGateways) {
    Write-Host '==> Stopping gateway processes'
    & 'C:\caddy-gateway\Stop-CaddyGateway.ps1'
}

Write-Host 'Service uninstall complete. Gateway files were not removed.'
