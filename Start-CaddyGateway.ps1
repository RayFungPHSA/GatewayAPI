<#
.SYNOPSIS
    Starts the local MCP bridges and the native Caddy gateway.

.DESCRIPTION
    Run this after a computer reboot as the Windows account that owns the DPAPI
    credential records (`ray.fung` by default). It:

      1. Starts or verifies the seven loopback MCP bridges on 8400-8406.
      2. Validates C:\caddy-gateway\Caddyfile.
      3. Starts Caddy in the background, or reloads it if it is already running.
      4. Verifies the local listeners and the token-free gateway routes.

    The script is idempotent: bridges that are already listening are left alone,
    and an already-running Caddy is reloaded rather than stopped.

.EXAMPLE
    .\Start-CaddyGateway.ps1

.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -File C:\caddy-gateway\Start-CaddyGateway.ps1

.EXAMPLE
    .\Start-CaddyGateway.ps1 -NoVerify -LogPath ''
#>
[CmdletBinding()]
param(
    [string]$RootDir = 'C:\caddy-gateway',
    [string]$ExpectedUser = 'ray.fung',
    [switch]$AllowOtherUser,
    [switch]$NoVerify,
    [string]$LogPath = 'C:\caddy-gateway\logs\startup.log'
)

$ErrorActionPreference = 'Stop'

function Write-Step {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host ""
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-Ok {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "    OK: $Message" -ForegroundColor Green
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

    throw 'Caddy executable not found. Install Caddy or pass the full path by adding it to PATH.'
}

function Wait-PortListening {
    param(
        [Parameter(Mandatory)][int]$Port,
        [int]$TimeoutSec = 20
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    do {
        if (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue) { return }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)
    throw "Timed out after ${TimeoutSec}s waiting for TCP port $Port to listen."
}

function Assert-LocalRoute {
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$Port = 8081
    )
    $uri = "http://127.0.0.1:$Port$Path"
    $response = Invoke-WebRequest -Uri $uri -UseBasicParsing -TimeoutSec 10
    if ([int]$response.StatusCode -ne 200) {
        throw "Local route check failed: $uri returned HTTP $($response.StatusCode)."
    }
    Write-Ok "$Path -> HTTP $($response.StatusCode)"
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

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    Write-Step "Starting Caddy gateway as $identity"
    if (-not $AllowOtherUser -and $env:USERNAME -ne $ExpectedUser) {
        throw "Expected Windows user '$ExpectedUser' but current user is '$env:USERNAME'. DPAPI credential records are account-bound. Re-run as $ExpectedUser, or use -AllowOtherUser if the records were recreated for this account."
    }

    if (-not (Test-Path -LiteralPath (Join-Path $RootDir 'Caddyfile'))) {
        throw "Caddyfile not found under $RootDir."
    }

    $powerShellExe = (Get-Command powershell.exe -ErrorAction SilentlyContinue).Source
    if (-not $powerShellExe) { $powerShellExe = Join-Path $PSHOME 'powershell.exe' }
    if (-not (Test-Path -LiteralPath $powerShellExe)) {
        throw 'Could not find powershell.exe to launch the bridge scripts.'
    }

    $bridges = @(
        [pscustomobject]@{
            Name = 'Cohesity'
            Script = Join-Path $RootDir 'cohesity-mcp\Start-CohesityMcpBridge.ps1'
            Port = 8400
            HealthUri = 'http://127.0.0.1:8400/health'
        }
        [pscustomobject]@{
            Name = 'HPEGreenLake'
            Script = Join-Path $RootDir 'hpegreenlake-mcp\Start-HPEGreenLakeBridge.ps1'
            Port = 8401
            HealthUri = 'http://127.0.0.1:8401/health'
        }
        [pscustomobject]@{
            Name = 'Lansweeper'
            Script = Join-Path $RootDir 'lansweeper-mcp\Start-LansweeperBridge.ps1'
            Port = 8402
            HealthUri = 'http://127.0.0.1:8402/health'
        }
        [pscustomobject]@{
            Name = 'vSphere'
            Script = Join-Path $RootDir 'vsphere-mcp\Start-VsphereBridge.ps1'
            Port = 8403
            HealthUri = 'http://127.0.0.1:8403/health'
        }
        [pscustomobject]@{
            Name = '3PARLegacy'
            Script = Join-Path $RootDir '3parlegacy-mcp\Start-3PARLegacyBridge.ps1'
            Port = 8404
            HealthUri = 'http://127.0.0.1:8404/health'
        }
        [pscustomobject]@{
            Name = 'HPEXP8'
            Script = Join-Path $RootDir 'hpexp8-mcp\Start-HPEXP8Bridge.ps1'
            Port = 8405
            HealthUri = 'http://127.0.0.1:8405/health'
        }
        [pscustomobject]@{
            Name = 'Brocade'
            Script = Join-Path $RootDir 'brocade-mcp\Start-BrocadeBridge.ps1'
            Port = 8406
            HealthUri = 'http://127.0.0.1:8406/health'
        }
    )

    foreach ($bridge in $bridges) {
        Write-Step "Starting/verifying $($bridge.Name) MCP bridge (port $($bridge.Port))"
        if (-not (Test-Path -LiteralPath $bridge.Script)) {
            throw "Bridge starter not found: $($bridge.Script)"
        }

        # Each bridge gets its own PowerShell process so its environment-variable
        # setup cannot leak into the next bridge or into this launcher.
        & $powerShellExe -NoProfile -ExecutionPolicy Bypass -File $bridge.Script
        if ($LASTEXITCODE -ne 0) {
            throw "$($bridge.Name) bridge starter failed with exit code $LASTEXITCODE."
        }

        Wait-PortListening -Port $bridge.Port -TimeoutSec 20
        $health = Invoke-RestMethod -Uri $bridge.HealthUri -TimeoutSec 5
        if (-not $health -or -not $health.ok) {
            throw "$($bridge.Name) bridge is listening but did not report a healthy /health response."
        }
        Write-Ok "$($bridge.Name) bridge is ready on 127.0.0.1:$($bridge.Port)"
    }

    $caddyExe = Get-CaddyExecutable
    $caddyFile = Join-Path $RootDir 'Caddyfile'

    Write-Step "Validating Caddy configuration"
    & $caddyExe validate --config $caddyFile
    if ($LASTEXITCODE -ne 0) {
        throw "Caddy configuration validation failed with exit code $LASTEXITCODE."
    }
    Write-Ok 'Caddyfile is valid'

    $adminListener = Get-NetTCPConnection -LocalPort 2019 -State Listen -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($adminListener) {
        $owner = Get-Process -Id $adminListener.OwningProcess -ErrorAction SilentlyContinue
        if ($owner -and $owner.ProcessName -ne 'caddy') {
            Write-Warning "Port 2019 is owned by $($owner.ProcessName) rather than caddy; attempting reload anyway."
        }
        Write-Step 'Caddy is already running; reloading configuration'
        & $caddyExe reload --config $caddyFile
    } else {
        Write-Step 'Starting Caddy in the background'
        & $caddyExe start --config $caddyFile
    }
    if ($LASTEXITCODE -ne 0) {
        throw "Caddy start/reload failed with exit code $LASTEXITCODE."
    }

    Write-Step 'Waiting for gateway listeners'
    foreach ($port in @(2019, 8081, 8088, 9180)) {
        Wait-PortListening -Port $port -TimeoutSec 20
        Write-Ok "TCP $port is listening"
    }

    if (-not $NoVerify) {
        Write-Step 'Verifying local gateway routes'
        foreach ($path in @(
            '/mcp/servers',
            '/cohesity/health',
            '/hpegreenlake/health',
            '/lansweeper/health',
            '/vsphere/health',
            '/3parlegacy/health',
            '/hpexp8/health',
            '/brocade/health'
        )) {
            Assert-LocalRoute -Path $path
        }
    } else {
        Write-Warning 'Route verification skipped (-NoVerify).'
    }

    Write-Step 'Gateway startup complete'
    Write-Host '  HTTP:  http://10.53.19.120:8081'
    Write-Host '  HTTPS: https://10.53.19.120:8088'
    Write-Host '  Metrics: http://127.0.0.1:9180/metrics'
    if ($LogPath -and $transcriptStarted) {
        Write-Host "  Startup log: $LogPath"
    }
}
finally {
    if ($transcriptStarted) { Stop-Transcript }
}
