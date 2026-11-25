<#
.SYNOPSIS
    Validate the 3PARLegacy MCP through the native Caddy gateway.

    The test confirms discovery, health, read-only tool annotations, and that
    only JPN3PAR01 is registered. While TCP/443 is firewall-pending, the
    connection-status tool is expected to report onlineArrays=0 with a
    structured failure rather than a tool error.

.EXAMPLE
    $env:COHESITY_GATEWAY_TOKEN = '<your token>'
    .\Test-3PARLegacyMcp.ps1
#>
[CmdletBinding()]
param(
    [string]$BaseUrl = 'http://10.53.19.120:8081',
    [string]$Token = $env:COHESITY_GATEWAY_TOKEN,
    [switch]$AllowUntrustedCertificate
)

$ErrorActionPreference = 'Stop'
$BaseUrl = $BaseUrl.TrimEnd('/')
$script:Passed = 0
$script:Failed = 0

if (-not $Token) { throw 'Set -Token or $env:COHESITY_GATEWAY_TOKEN.' }

if ($AllowUntrustedCertificate) {
    [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
}

$ExpectedTools = @(
    'threepar_connection_status'
    'threepar_inventory_summary'
    'threepar_list_cpgs'
    'threepar_list_volumes'
    'threepar_list_volume_sets'
    'threepar_list_hosts'
    'threepar_list_host_sets'
    'threepar_list_ports'
    'threepar_list_users'
    'threepar_capacity_summary'
)

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

function Invoke-Mcp {
    param(
        [Parameter(Mandatory)][int]$Id,
        [Parameter(Mandatory)][string]$Method,
        [hashtable]$Params = @{}
    )
    $payload = @{
        jsonrpc = '2.0'
        id      = $Id
        method  = $Method
        params  = $Params
    } | ConvertTo-Json -Depth 8 -Compress

    Invoke-RestMethod `
        -Uri "$BaseUrl/3parlegacy/mcp" `
        -Method Post `
        -Headers @{
            'X-Gateway-Token' = $Token
            'Accept'          = 'application/json, text/event-stream'
        } `
        -ContentType 'application/json' `
        -Body $payload `
        -TimeoutSec 180
}

Write-Host "3PARLegacy MCP test - $BaseUrl"
Write-Host

try {
    $catalog = Invoke-RestMethod -Uri "$BaseUrl/mcp/servers" -TimeoutSec 30
    $entries = @($catalog.servers | Where-Object { $_.name -eq '3PARLegacy' })
    Assert-Test 'Catalog has exactly one 3PARLegacy entry' ($entries.Count -eq 1)
    if ($entries.Count -eq 1) {
        Assert-Test 'Catalog MCP URL uses the gateway route' ($entries[0].http_url -match '/3parlegacy/mcp$')
        Assert-Test 'Catalog health URL uses the gateway route' ($entries[0].health_http_url -match '/3parlegacy/health$')
    }
} catch {
    Assert-Test 'Catalog has exactly one 3PARLegacy entry' $false $_.Exception.Message
}

try {
    $health = Invoke-RestMethod -Uri "$BaseUrl/3parlegacy/health" -TimeoutSec 30
    Assert-Test 'Health endpoint is healthy' ([bool]$health.ok)
    Assert-Test 'Health reports DPAPI credential store' ($health.credential_store -eq 'dpapi')
    Assert-Test 'Health reports exactly two arrays' (@($health.arrays).Count -eq 2)
    Assert-Test 'Health includes JPN3PAR01' (@($health.arrays) -contains 'JPN3PAR01')
    Assert-Test 'Health includes cw3par02.phsabc.ehcnet.ca' (@($health.arrays) -contains 'cw3par02.phsabc.ehcnet.ca')
    Assert-Test 'Health does not echo a username' (-not $health.PSObject.Properties['username'])
    Assert-Test 'Health reports all tools' ($health.tool_count -eq $ExpectedTools.Count)
} catch {
    Assert-Test 'Health endpoint is healthy' $false $_.Exception.Message
}

try {
    $toolsResponse = Invoke-Mcp -Id 1 -Method 'tools/list'
    $tools = @($toolsResponse.result.tools)
    $names = @($tools | ForEach-Object { $_.name })
    $missing = @($ExpectedTools | Where-Object { $_ -notin $names })
    Assert-Test 'All expected tools are listed' ($tools.Count -eq $ExpectedTools.Count -and $missing.Count -eq 0) "(missing: $($missing -join ','))"
    $bad = @($tools | Where-Object {
        ([bool]$_.annotations.readOnlyHint -ne $true) -or
        ([bool]$_.annotations.destructiveHint -ne $false)
    })
    Assert-Test 'Every tool is annotated read-only' ($bad.Count -eq 0) "(bad: $(@($bad | ForEach-Object { $_.name }) -join ','))"
} catch {
    Assert-Test 'All expected tools are listed' $false $_.Exception.Message
}

try {
    $response = Invoke-Mcp -Id 2 -Method 'tools/call' -Params @{
        name      = 'threepar_connection_status'
        arguments = @{}
    }
    $result = $response.result
    $payload = $result.structuredContent
    if (-not $payload) {
        $text = (@($result.content | ForEach-Object { $_.text }) -join ' ')
        $payload = $text | ConvertFrom-Json
    }
    Assert-Test 'Connection status returns a normal result' (-not [bool]$result.isError)
    Assert-Test 'Connection status is scoped to two arrays' ($payload.configuredArrays -eq 2 -and $payload.selectedArrays -eq 2)
    $payloadJson = $payload | ConvertTo-Json -Depth 12 -Compress
    Assert-Test 'Connection status contains no rolled-back array names' (
        $payloadJson -notmatch 'CWALLETRA01|SMHALLETRA01|10\.1\.63\.165|172\.19\.240\.194'
    )
    $onlineNames = @($payload.arrays | ForEach-Object { $_.array })
    $failureNames = @($payload.failures | ForEach-Object { $_.array })
    Assert-Test 'cw3par02.phsabc.ehcnet.ca is online' ($onlineNames -contains 'cw3par02.phsabc.ehcnet.ca')
    if ($payload.onlineArrays -eq 2) {
        Assert-Test 'JPN3PAR01 is online after firewall opening' ($onlineNames -contains 'JPN3PAR01')
    } else {
        Assert-Test 'Firewall-pending JPN3PAR01 is reported as a structured failure' (
            $payload.onlineArrays -eq 1 -and
            $failureNames -contains 'JPN3PAR01' -and
            @($payload.failures | Where-Object {
                $_.array -eq 'JPN3PAR01' -and -not [string]::IsNullOrWhiteSpace($_.error)
            }).Count -eq 1
        )
    }
} catch {
    Assert-Test 'Connection status returns a normal result' $false $_.Exception.Message
}

Write-Host
Write-Host ("Result: {0} passed, {1} failed" -f $script:Passed, $script:Failed)
if ($script:Failed -gt 0) { exit 1 }
