<#
.SYNOPSIS
    Stops the native Caddy gateway and all seven local MCP bridges.

.DESCRIPTION
    Idempotent companion to Start-CaddyGateway.ps1. It is used manually and by
    the CaddyGateway Windows Service when the service is stopped.

.EXAMPLE
    .\Stop-CaddyGateway.ps1

.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -File C:\caddy-gateway\Stop-CaddyGateway.ps1
#>
[CmdletBinding()]
param(
    [string]$RootDir = 'C:\caddy-gateway',
    [string]$LogPath = 'C:\caddy-gateway\logs\shutdown.log'
)

$ErrorActionPreference = 'Stop'

function Write-Step {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host ""
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Get-CaddyExecutable {
    $command = Get-Command caddy -CommandType Application -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }

    $candidates = @()
    $wingetRoot = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'
    if (Test-Path -LiteralPath $wingetRoot) {
        $candidates += Get-ChildItem -Path $wingetRoot -Directory -Filter 'CaddyServer.Caddy_*' -ErrorAction SilentlyContinue |
            ForEach-Object { Join-Path $_.FullName 'caddy.exe' }
    }
    $candidates += 'C:\Program Files\Caddy\caddy.exe'
    $candidates += 'C:\caddy\caddy.exe'

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) { return $candidate }
    }
    return $null
}

function Wait-PortClosed {
    param(
        [Parameter(Mandatory)][int]$Port,
        [int]$TimeoutSec = 10
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    do {
        if (-not (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)) { return }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    Write-Warning "TCP port $Port is still listening after ${TimeoutSec}s."
}

$transcriptStarted = $false
try {
    if ($LogPath) {
        $logDir = Split-Path -Parent $LogPath
        if ($logDir -and -not (Test-Path -LiteralPath $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }
        try {
            Start-Transcript -Path $LogPath -Append -ErrorAction Stop | Out-Null
            $transcriptStarted = $true
        } catch {
            Write-Warning "Could not start transcript at $LogPath : $($_.Exception.Message)"
        }
    }

    Write-Step "Stopping gateway processes under $RootDir"

    $stopScripts = @(
        'cohesity-mcp\Stop-CohesityMcpBridge.ps1'
        'hpegreenlake-mcp\Stop-HPEGreenLakeBridge.ps1'
        'lansweeper-mcp\Stop-LansweeperBridge.ps1'
        'vsphere-mcp\Stop-VsphereBridge.ps1'
        '3parlegacy-mcp\Stop-3PARLegacyBridge.ps1'
        'hpexp8-mcp\Stop-HPEXP8Bridge.ps1'
        'brocade-mcp\Stop-BrocadeBridge.ps1'
    )

    foreach ($relative in $stopScripts) {
        $path = Join-Path $RootDir $relative
        if (-not (Test-Path -LiteralPath $path)) {
            Write-Warning "Stop script not found: $path"
            continue
        }
        Write-Host "  Stopping $relative"
        & $path
    }

    Write-Step 'Stopping Caddy'
    $caddyExe = Get-CaddyExecutable
    if (-not $caddyExe) {
        Write-Warning 'Caddy executable not found; skipped caddy stop.'
    } else {
        $adminListener = Get-NetTCPConnection -LocalPort 2019 -State Listen -ErrorAction SilentlyContinue
        if ($adminListener) {
            & $caddyExe stop --config (Join-Path $RootDir 'Caddyfile')
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "caddy stop exited with code $LASTEXITCODE."
            }
        } else {
            Write-Host '  Caddy admin endpoint is not listening; Caddy is already stopped.'
        }
    }

    Write-Step 'Waiting for listeners to close'
    foreach ($port in @(8400, 8401, 8402, 8403, 8404, 8405, 8406, 2019, 8081, 8088, 9180)) {
        Wait-PortClosed -Port $port
    }

    Write-Step 'Gateway shutdown complete'
} finally {
    if ($transcriptStarted) { Stop-Transcript }
}
