<#
.SYNOPSIS
    Start the Streamlit usage dashboard for the Caddy gateway.

    Binds to loopback by default. The dashboard reads C:\caddy-gateway\logs
    and the gateway ACL directly. Open http://127.0.0.1:8501 in a browser.

.EXAMPLE
    .\Start-GatewayUsageDashboard.ps1

.EXAMPLE
    .\Start-GatewayUsageDashboard.ps1 -Port 8600
#>
[CmdletBinding()]
param(
    [int]$Port = 8501,
    [string]$Address = '127.0.0.1'
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$app = Join-Path $root 'usage_dashboard.py'
if (-not (Test-Path -LiteralPath $app)) {
    throw "Dashboard script not found: $app"
}
if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
    throw 'Python was not found on PATH.'
}

$streamlitCheck = & python -c 'import streamlit' 2>&1
if ($LASTEXITCODE -ne 0) {
    throw 'Streamlit is not installed. Run: python -m pip install streamlit'
}

$previousEncoding = $env:PYTHONIOENCODING
try {
    $env:PYTHONIOENCODING = 'utf-8'
    Write-Host "Starting gateway usage dashboard at http://${Address}:${Port}"
    Write-Host 'Press Ctrl+C to stop.'
    Write-Host "Open http://${Address}:${Port} in your browser."
    & python -m streamlit run $app `
        --server.address $Address `
        --server.port $Port `
        --server.headless true `
        --browser.gatherUsageStats false `
        --client.toolbarMode minimal
}
finally {
    if ($null -eq $previousEncoding) {
        Remove-Item Env:PYTHONIOENCODING -ErrorAction SilentlyContinue
    }
    else {
        $env:PYTHONIOENCODING = $previousEncoding
    }
}
