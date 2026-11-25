<#
.SYNOPSIS
    Verify the MCP catalog endpoint and that every listed server is usable.

    Requires $env:CADDY_GATEWAY_TOKEN for the tools/list checks. The token is
    never echoed or written to disk.

.EXAMPLE
    $env:CADDY_GATEWAY_TOKEN = '<token issued to you>'
    .\Test-McpDiscovery.ps1
#>
[CmdletBinding()]
param(
    [string]$BaseUrl = 'http://10.53.19.120:8081'
)

$ErrorActionPreference = 'Stop'

# Legacy gateway-token environment variable aliases remain supported for rollback.
if (-not $env:CADDY_GATEWAY_TOKEN -and $env:COHESITY_GATEWAY_TOKEN) {
    $env:CADDY_GATEWAY_TOKEN = $env:COHESITY_GATEWAY_TOKEN
}
if (-not $env:CADDY_GATEWAY_ADMIN_TOKEN -and $env:COHESITY_GATEWAY_ADMIN_TOKEN) {
    $env:CADDY_GATEWAY_ADMIN_TOKEN = $env:COHESITY_GATEWAY_ADMIN_TOKEN
}
if (-not $env:CADDY_GATEWAY_READONLY_TOKEN -and $env:COHESITY_GATEWAY_READONLY_TOKEN) {
    $env:CADDY_GATEWAY_READONLY_TOKEN = $env:COHESITY_GATEWAY_READONLY_TOKEN
}
$BaseUrl = $BaseUrl.TrimEnd('/')
$script:Passed = 0
$script:Failed = 0

if (-not $env:CADDY_GATEWAY_TOKEN) {
    throw 'Set $env:CADDY_GATEWAY_TOKEN before running this test.'
}

function Assert-Test {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][bool]$Condition,
        [string]$Detail = ''
    )
    if ($Condition) {
        Write-Host ("  PASS  {0}" -f $Name) -ForegroundColor Green
        $script:Passed++
    } else {
        Write-Host ("  FAIL  {0} {1}" -f $Name, $Detail) -ForegroundColor Red
        $script:Failed++
    }
}

Write-Host "MCP catalog/discovery test - $BaseUrl"
Write-Host

$catalog = $null
try {
    $catalog = Invoke-RestMethod -Uri "$BaseUrl/mcp/servers" -TimeoutSec 15
    Assert-Test 'MCP catalog endpoint' ($catalog.version -eq 1 -and @($catalog.servers).Count -gt 0)
} catch {
    Assert-Test 'MCP catalog endpoint' $false $_.Exception.Message
}

if ($catalog) {
    $names = @($catalog.servers | ForEach-Object { $_.name })
    $expected = @('cohesity', 'hpegreenlake', 'lansweeper', 'vsphere')
    $missing = @($expected | Where-Object { $_ -notin $names })
    Assert-Test 'Catalog lists expected servers' ($missing.Count -eq 0) "(found: $($names -join ','); missing: $($missing -join ','))"

    foreach ($server in $catalog.servers) {
        try {
            $health = Invoke-RestMethod -Uri $server.health_http_url -TimeoutSec 15
            Assert-Test "$($server.name) health" ($health.ok -eq $true -and $health.auth -eq 'gateway_token')
        } catch {
            Assert-Test "$($server.name) health" $false $_.Exception.Message
        }

        try {
            $payload = @{
                jsonrpc = '2.0'
                id      = 1
                method  = 'tools/list'
                params  = @{}
            } | ConvertTo-Json -Depth 6 -Compress
            $tools = Invoke-RestMethod `
                -Uri $server.http_url `
                -Method Post `
                -Headers @{
                    'X-Gateway-Token' = ($env:CADDY_GATEWAY_TOKEN, $env:COHESITY_GATEWAY_TOKEN | Where-Object { $_ } | Select-Object -First 1)
                    'Accept'          = 'application/json, text/event-stream'
                } `
                -ContentType 'application/json' `
                -Body $payload `
                -TimeoutSec 180
            Assert-Test "$($server.name) tools/list" (@($tools.result.tools).Count -gt 0)
        } catch {
            Assert-Test "$($server.name) tools/list" $false $_.Exception.Message
        }
    }
} else {
    Assert-Test 'Catalog lists expected servers' $false '(no catalog data)'
}

Write-Host
Write-Host ("Result: {0} passed, {1} failed" -f $script:Passed, $script:Failed) -ForegroundColor Cyan
if ($script:Failed -gt 0) { exit 1 }
