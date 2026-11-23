<#
.SYNOPSIS
    Immediately refresh gateway usage data and restart the Streamlit dashboard.

    By default this runs the snapshot builder synchronously, then stops any
    existing usage-dashboard process and starts a fresh one. Use
    -UseScheduledTask to refresh through the SYSTEM scheduled task instead.

.EXAMPLE
    .\Refresh-GatewayUsageDashboard.ps1

.EXAMPLE
    .\Refresh-GatewayUsageDashboard.ps1 -UseScheduledTask -Port 8600
#>
[CmdletBinding()]
param(
    [int]$Port = 8501,
    [string]$Address = '127.0.0.1',
    [switch]$UseScheduledTask,
    [switch]$NoBrowser
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location -LiteralPath $root

$refreshScript = Join-Path $root 'Update-GatewayUsageSnapshot.ps1'
$launcher = Join-Path $root 'Start-GatewayUsageDashboard.ps1'
$snapshotLog = Join-Path $root 'analytics\snapshot.log'
$taskName = 'Caddy Gateway Usage Snapshot'

foreach ($file in @($refreshScript, $launcher)) {
    if (-not (Test-Path -LiteralPath $file)) {
        throw "Required script not found: $file"
    }
}

function Write-Step([string]$Message) {
    Write-Host "[refresh] $Message" -ForegroundColor Cyan
}

function Update-Snapshot {
    if ($UseScheduledTask) {
        Write-Step 'Refreshing snapshot via SYSTEM scheduled task...'
        $before = if (Test-Path -LiteralPath $snapshotLog) {
            (Get-Item -LiteralPath $snapshotLog).LastWriteTime
        }
        else {
            [datetime]::MinValue
        }

        Start-ScheduledTask -TaskName $taskName

        $deadline = (Get-Date).AddSeconds(45)
        do {
            Start-Sleep -Seconds 2
            $logUpdated = (Test-Path -LiteralPath $snapshotLog) -and
                          ((Get-Item -LiteralPath $snapshotLog).LastWriteTime -gt $before)
            $info = Get-ScheduledTaskInfo -TaskName $taskName
        } until ($logUpdated -or (Get-Date) -gt $deadline)

        if (-not $logUpdated) {
            throw "Scheduled task '$taskName' did not write a new log entry within 45 seconds."
        }
        if ($info.LastTaskResult -ne 0) {
            throw "Scheduled task '$taskName' failed with result $($info.LastTaskResult)."
        }
        Get-Content -LiteralPath $snapshotLog -Tail 4 | ForEach-Object { Write-Host "  $_" }
    }
    else {
        Write-Step 'Refreshing snapshot directly...'
        $global:LASTEXITCODE = 0
        & $refreshScript
        if ($LASTEXITCODE -ne 0) {
            throw "Snapshot refresh failed with exit code $LASTEXITCODE."
        }
        Get-Content -LiteralPath $snapshotLog -Tail 4 | ForEach-Object { Write-Host "  $_" }
    }
}

function Restart-Dashboard {
    $running = @(
        Get-CimInstance Win32_Process |
            Where-Object {
                ($_.Name -eq 'python.exe' -or $_.Name -eq 'pythonw.exe') -and
                $_.CommandLine -like '*usage_dashboard.py*'
            }
    )

    foreach ($proc in $running) {
        Write-Step "Stopping dashboard process $($proc.ProcessId)"
        Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue
    }
    if ($running.Count -gt 0) {
        Start-Sleep -Seconds 2
    }

    Write-Step "Starting dashboard at http://${Address}:${Port}"
    $launcherArgs = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', ('"' + $launcher + '"'),
        '-Port', "$Port",
        '-Address', $Address
    )
    Start-Process -FilePath 'powershell.exe' -ArgumentList $launcherArgs -WorkingDirectory $root | Out-Null

    $url = "http://${Address}:${Port}"
    $deadline = (Get-Date).AddSeconds(25)
    $up = $false
    do {
        Start-Sleep -Milliseconds 750
        try {
            $response = Invoke-WebRequest -Uri "$url/_stcore/health" -UseBasicParsing -TimeoutSec 2
            $up = ($response.StatusCode -eq 200)
        }
        catch {
            $up = $false
        }
    } until ($up -or (Get-Date) -gt $deadline)

    if (-not $up) {
        Write-Warning "Dashboard did not answer at $url within 25 seconds. Check the new terminal window."
        return
    }

    Write-Step 'Dashboard is ready.'
    if (-not $NoBrowser) {
        Start-Process $url
    }
}

Update-Snapshot
Restart-Dashboard
