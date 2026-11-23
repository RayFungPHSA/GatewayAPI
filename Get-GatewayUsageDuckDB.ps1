<#
.SYNOPSIS
    Usage report for the Caddy gateway, backed by DuckDB.

    Summarizes MCP request volume, daily trends, hashed-token callers and
    status/latency from the JSON access log. Health checks and scanner probes
    are counted separately so they do not distort usage numbers.

    Requires Python 3 and DuckDB (python -m pip install duckdb).

.EXAMPLE
    .\Get-GatewayUsageDuckDB.ps1

.EXAMPLE
    .\Get-GatewayUsageDuckDB.ps1 -Days 30 -Top 25 -CsvPath C:\caddy-gateway\logs\usage.csv

.EXAMPLE
    .\Get-GatewayUsageDuckDB.ps1 -Days 0 -IncludeHealthChecks
#>
[CmdletBinding()]
param(
    [string]$LogPath = 'C:\caddy-gateway\logs\access*.log',
    [int]$Days = 7,
    [int]$Top = 15,
    [string]$CsvPath,
    [string]$AclPath = 'C:\caddy-gateway\secrets\cohesity-gateway-acl.json',
    [switch]$IncludeHealthChecks
)

$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$reportScript = Join-Path $scriptRoot 'gateway_usage_report.py'
if (-not (Test-Path -LiteralPath $reportScript)) {
    throw "Report script not found: $reportScript"
}
if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
    throw 'Python was not found on PATH. Install Python 3 or run gateway_usage_report.py directly.'
}

$pyArgs = @($reportScript, '--log-path', $LogPath, '--days', $Days, '--top', $Top)
if ($CsvPath) { $pyArgs += @('--csv', $CsvPath) }
if ($AclPath) { $pyArgs += @('--acl', $AclPath) }
if ($IncludeHealthChecks) { $pyArgs += '--include-health' }

# DuckDB's table renderer uses Unicode box characters; force UTF-8 on Windows consoles.
$previousEncoding = $env:PYTHONIOENCODING
try {
    $env:PYTHONIOENCODING = 'utf-8'
    & python @pyArgs
    if ($LASTEXITCODE -ne 0) {
        throw "Usage report failed with exit code $LASTEXITCODE"
    }
}
finally {
    if ($null -eq $previousEncoding) {
        Remove-Item Env:PYTHONIOENCODING -ErrorAction SilentlyContinue
    }
    else {
        $env:PYTHONIOENCODING = $previousEncoding
    }
}
