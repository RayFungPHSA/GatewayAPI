$ErrorActionPreference = 'Stop'

$BridgeDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$PidFile = Join-Path $BridgeDir 'bridge.pid'
$Port = 8405

$pidValue = $null
if (Test-Path -LiteralPath $PidFile) {
    $pidValue = (Get-Content -LiteralPath $PidFile -Raw).Trim()
}

$connection = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
if (-not $connection -and [string]::IsNullOrWhiteSpace($pidValue)) {
    Write-Host "HPEXP8 MCP bridge is not running."
    exit 0
}

$targetPids = @()
if ($connection) { $targetPids += $connection.OwningProcess }
if (-not [string]::IsNullOrWhiteSpace($pidValue)) { $targetPids += [int]$pidValue }
$targetPids = $targetPids | Select-Object -Unique

foreach ($processId in $targetPids) {
    $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
    if ($process) {
        Stop-Process -Id $processId -Force
        Write-Host "Stopped HPEXP8 MCP bridge PID $processId."
    }
}

Remove-Item -LiteralPath $PidFile -ErrorAction SilentlyContinue
