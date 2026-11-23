<#
.SYNOPSIS
    Rebuild the incremental DuckDB usage snapshot from Caddy access logs.

    Intended for Task Scheduler. Writes a small rotating log to analytics\snapshot.log.

.EXAMPLE
    .\Update-GatewayUsageSnapshot.ps1

.EXAMPLE
    .\Update-GatewayUsageSnapshot.ps1 -RootDir C:\caddy-gateway
#>
[CmdletBinding()]
param(
    [string]$RootDir = 'C:\caddy-gateway',
    [string]$PythonExe = 'C:\Python314\python.exe'
)

$ErrorActionPreference = 'Stop'

$script = Join-Path $RootDir 'build_usage_snapshot.py'
$logDir = Join-Path $RootDir 'analytics'
$logFile = Join-Path $logDir 'snapshot.log'
$stdoutFile = Join-Path $logDir 'snapshot.stdout.tmp'
$stderrFile = Join-Path $logDir 'snapshot.stderr.tmp'

if (-not (Test-Path -LiteralPath $script)) {
    throw "Snapshot builder not found: $script"
}
if (-not (Test-Path -LiteralPath $PythonExe)) {
    $found = Get-Command python -ErrorAction SilentlyContinue
    if ($found) { $PythonExe = $found.Source }
    else { throw 'Python was not found.' }
}
New-Item -ItemType Directory -Force -Path $logDir | Out-Null

function Write-SnapshotLog([string]$Message) {
    Add-Content -LiteralPath $logFile -Value ("[{0}] {1}" -f (Get-Date -Format 'o'), $Message)
}

$previousEncoding = $env:PYTHONIOENCODING
$previousPythonPath = $env:PYTHONPATH
$pythonLibs = Join-Path $RootDir '.pythonlibs'
try {
    Write-SnapshotLog 'Starting usage snapshot'
    $env:PYTHONIOENCODING = 'utf-8'
    if (Test-Path -LiteralPath $pythonLibs) {
        if ($env:PYTHONPATH) {
            $env:PYTHONPATH = $pythonLibs + [IO.Path]::PathSeparator + $env:PYTHONPATH
        }
        else {
            $env:PYTHONPATH = $pythonLibs
        }
    }
    Remove-Item -LiteralPath $stdoutFile, $stderrFile -ErrorAction SilentlyContinue

    $proc = Start-Process `
        -FilePath $PythonExe `
        -ArgumentList ('"' + $script + '"') `
        -WorkingDirectory $RootDir `
        -NoNewWindow -Wait -PassThru `
        -RedirectStandardOutput $stdoutFile `
        -RedirectStandardError $stderrFile

    if (Test-Path -LiteralPath $stdoutFile) {
        Get-Content -LiteralPath $stdoutFile | ForEach-Object { Write-SnapshotLog $_ }
    }
    if (Test-Path -LiteralPath $stderrFile) {
        Get-Content -LiteralPath $stderrFile | ForEach-Object { Write-SnapshotLog "PYERR: $_" }
    }

    $exitCode = $proc.ExitCode
    if ($exitCode -ne 0) {
        Write-SnapshotLog "FAILED with exit code $exitCode"
        exit $exitCode
    }
    Write-SnapshotLog 'Usage snapshot completed'
}
catch {
    Write-SnapshotLog "ERROR: $($_.Exception.Message)"
    throw
}
finally {
    Remove-Item -LiteralPath $stdoutFile, $stderrFile -ErrorAction SilentlyContinue
    if ($null -eq $previousEncoding) {
        Remove-Item Env:PYTHONIOENCODING -ErrorAction SilentlyContinue
    }
    else {
        $env:PYTHONIOENCODING = $previousEncoding
    }
    if ($null -eq $previousPythonPath) {
        Remove-Item Env:PYTHONPATH -ErrorAction SilentlyContinue
    }
    else {
        $env:PYTHONPATH = $previousPythonPath
    }
}
