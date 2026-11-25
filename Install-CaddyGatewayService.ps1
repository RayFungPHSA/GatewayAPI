<#
.SYNOPSIS
    Installs the CaddyGateway Windows Service using the Ray.Fung account.

.DESCRIPTION
    Must be run from an elevated PowerShell window. It:

      1. Compiles service\CaddyGatewayService.cs if the EXE is missing/stale.
      2. Grants the account the "Log on as a service" right.
      3. Prompts locally for that account's Windows password and configures the
         service to run as it. The password is never written to a project file
         and is not echoed.
      4. Creates the service as Automatic (Delayed Start), enables recovery,
         and starts it.

    The service calls the existing Start-CaddyGateway.ps1 and
    Stop-CaddyGateway.ps1 scripts, so the manual scripts remain the source of
    truth and can still be run by hand.

.EXAMPLE
    # Run from an elevated PowerShell prompt:
    .\Install-CaddyGatewayService.ps1
#>
[CmdletBinding()]
param(
    [string]$RootDir = 'C:\caddy-gateway',
    [string]$ServiceName = 'CaddyGateway',
    [string]$Account = 'PHSABC\Ray.Fung'
)

$ErrorActionPreference = 'Stop'

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this script from an elevated PowerShell window (Run as Administrator).'
}

$serviceExe = Join-Path $RootDir 'service\CaddyGatewayService.exe'
$serviceSource = Join-Path $RootDir 'service\CaddyGatewayService.cs'
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'

if (-not (Test-Path -LiteralPath $serviceSource)) {
    throw "Service source not found: $serviceSource"
}
if (-not (Test-Path -LiteralPath $serviceExe) -or
    (Get-Item $serviceSource).LastWriteTimeUtc -gt (Get-Item $serviceExe).LastWriteTimeUtc) {
    if (-not (Test-Path -LiteralPath $csc)) {
        throw "C# compiler not found: $csc"
    }
    Write-Host '==> Compiling CaddyGatewayService.exe'
    & $csc /nologo /target:winexe /out:$serviceExe /r:System.dll /r:System.Core.dll /r:System.ServiceProcess.dll $serviceSource
    if ($LASTEXITCODE -ne 0) { throw "Service compilation failed with exit code $LASTEXITCODE." }
}

$accountSid = $null
try {
    $ntAccount = New-Object System.Security.Principal.NTAccount($Account)
    $accountSid = $ntAccount.Translate([Security.Principal.SecurityIdentifier]).Value
} catch {
    throw "Could not resolve account '$Account': $($_.Exception.Message)"
}
$sidEntry = '*' + $accountSid
Write-Host "==> Service account: $Account ($accountSid)"

function Grant-ServiceLogonRight {
    param(
        [Parameter(Mandatory)][string]$SidEntry,
        [Parameter(Mandatory)][string]$UserName
    )

    $tempDir = Join-Path $env:TEMP ('caddy-service-rights-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    # $env:TEMP can contain an 8.3 short path with '~'. Resolve it to the long
    # path so Remove-Item -LiteralPath works reliably on PowerShell 5.1.
    $tempDir = (Get-Item -LiteralPath $tempDir).FullName
    $export = Join-Path $tempDir 'before.inf'
    $modified = Join-Path $tempDir 'after.inf'
    $database = Join-Path $tempDir 'policy.sdb'

    try {
        & secedit.exe /export /cfg $export /areas USER_RIGHTS /quiet
        if ($LASTEXITCODE -ne 0) { throw "secedit export failed with exit code $LASTEXITCODE." }

        $lines = Get-Content -LiteralPath $export -Encoding Unicode
        $rightLine = $lines | Where-Object { $_ -match '^\s*SeServiceLogonRight\s*=' } | Select-Object -First 1
        if (-not $rightLine) {
            throw 'SeServiceLogonRight entry was not found in the exported security policy.'
        }

        if ($rightLine -match [regex]::Escape($SidEntry)) {
            Write-Host '==> Log on as a service right already present'
        } else {
            $updated = $rightLine.TrimEnd() + ',' + $SidEntry
            $lines = $lines | ForEach-Object {
                if ($_ -eq $rightLine) { $updated } else { $_ }
            }
            Set-Content -LiteralPath $modified -Value $lines -Encoding Unicode
            & secedit.exe /configure /db $database /cfg $modified /areas USER_RIGHTS /quiet
            if ($LASTEXITCODE -ne 0) { throw "secedit configure failed with exit code $LASTEXITCODE." }
            Write-Host "==> Granted 'Log on as a service' to $UserName"
        }
    } finally {
        Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Grant-ServiceLogonRight -SidEntry $sidEntry -UserName $Account

$existing = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($existing) {
    Write-Host "==> Removing existing service '$ServiceName'"
    if ($existing.Status -ne 'Stopped') {
        Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
    }
    & sc.exe delete $ServiceName | Out-Null
    for ($i = 0; $i -lt 30; $i++) {
        if (-not (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue)) { break }
        Start-Sleep -Milliseconds 500
    }
    if (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue) {
        throw "Could not remove existing service '$ServiceName'."
    }
}

Write-Host "==> Prompting for the Windows password for $Account"
Write-Host '    (masked input; the value is used only by Windows Service Control Manager)'
$securePassword = Read-Host -AsSecureString "Password for $Account"
if (-not $securePassword -or $securePassword.Length -eq 0) {
    throw 'A non-empty password is required for the service account.'
}
$credential = New-Object System.Management.Automation.PSCredential($Account, $securePassword)

$binaryPath = '"' + $serviceExe + '"'
Write-Host "==> Creating service '$ServiceName'"
New-Service `
    -Name $ServiceName `
    -BinaryPathName $binaryPath `
    -DisplayName 'Caddy API Gateway' `
    -Description 'Native Caddy gateway and seven loopback MCP bridges' `
    -StartupType Automatic `
    -Credential $credential | Out-Null

& sc.exe config $ServiceName 'start=' 'delayed-auto'
if ($LASTEXITCODE -ne 0) { throw "Failed to set delayed automatic start (exit $LASTEXITCODE)." }

& sc.exe failure $ServiceName reset= 86400 actions= restart/60000/restart/60000/restart/60000
if ($LASTEXITCODE -ne 0) { throw "Failed to configure service recovery (exit $LASTEXITCODE)." }

Write-Host "==> Starting service '$ServiceName'"
Start-Service -Name $ServiceName
Start-Sleep -Seconds 2
$service = Get-Service -Name $ServiceName
Write-Host "Service: $($service.Name) | Status: $($service.Status) | StartType: $($service.StartType)"

if ($service.Status -ne 'Running') {
    throw "Service '$ServiceName' did not enter the Running state. Check C:\caddy-gateway\logs\service.log."
}

Write-Host ''
Write-Host 'Installation complete.'
Write-Host '  Service log:       C:\caddy-gateway\logs\service.log'
Write-Host '  Startup log:       C:\caddy-gateway\logs\startup.log'
Write-Host '  Manual start:      C:\caddy-gateway\Start-CaddyGateway.ps1'
Write-Host '  Manual stop:       C:\caddy-gateway\Stop-CaddyGateway.ps1'
