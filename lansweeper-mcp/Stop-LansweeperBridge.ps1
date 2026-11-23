$ErrorActionPreference = 'Stop'

$BridgeDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$PidFile = Join-Path $BridgeDir 'bridge.pid'
$Port = 8402

if (Test-Path -LiteralPath $PidFile) {
    $bridgePid = (Get-Content -LiteralPath $PidFile -Raw).Trim()
    if ($bridgePid -match '^\d+$') {
        # Kill the Python process and any Node stdio child processes it spawned.
        & taskkill.exe /PID $bridgePid /T /F 2>$null | Out-Null
        Remove-Item -LiteralPath $PidFile -Force
        Write-Host "Stopped Lansweeper MCP bridge PID $bridgePid."
    }
} else {
    $listeners = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    if ($listeners) {
        foreach ($procId in ($listeners.OwningProcess | Select-Object -Unique)) {
            & taskkill.exe /PID $procId /T /F 2>$null | Out-Null
            Write-Host "Stopped listener PID $procId on port $Port."
        }
    } else {
        Write-Host 'Lansweeper MCP bridge is not running.'
    }
}
