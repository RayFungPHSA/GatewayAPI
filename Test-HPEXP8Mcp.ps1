<#
.SYNOPSIS
    Validate the HPEXP8 MCP through the native Caddy gateway.

    Confirms discovery, health, read-only tool annotations, both configured
    servers, and structured per-server results. While spapphpxp003 is blocked,
    connection/auth status is expected to report onlineServers=1 with a
    structured failure for that server.

.EXAMPLE
    $env:CADDY_GATEWAY_TOKEN = '<your token>'
    .\Test-HPEXP8Mcp.ps1
#>
[CmdletBinding()]
param(
    [string]$BaseUrl = 'http://10.53.19.120:8081',
    [string]$Token = ($env:CADDY_GATEWAY_TOKEN, $env:COHESITY_GATEWAY_TOKEN | Where-Object { $_ } | Select-Object -First 1),
    [switch]$AllowUntrustedCertificate
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

if (-not $Token) { throw 'Set -Token or $env:CADDY_GATEWAY_TOKEN.' }

if ($AllowUntrustedCertificate) {
    [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
}

$ExpectedTools = @(
    'xppa_connection_status'
    'xppa_auth_status'
    'xppa_list_arrays'
    'xppa_array_details'
    'xppa_array_capacity'
    'xppa_array_components'
    'xppa_array_ldevs'
    'xppa_array_replication'
    'xppa_database_summary'
    'xppa_event_history'
)
$Servers = @('spapphpxp001.healthbc.org', 'spapphpxp003.fraserhealth.org')

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
        -Uri "$BaseUrl/hpexp8/mcp" `
        -Method Post `
        -Headers @{
            'X-Gateway-Token' = $Token
            'Accept'          = 'application/json, text/event-stream'
        } `
        -ContentType 'application/json' `
        -Body $payload `
        -TimeoutSec 180
}

function Get-Payload {
    param($Result)
    if ($Result.structuredContent) { return $Result.structuredContent }
    $text = (@($Result.content | ForEach-Object { $_.text }) -join ' ')
    return ($text | ConvertFrom-Json)
}

Write-Host "HPEXP8 MCP test - $BaseUrl"
Write-Host

try {
    $catalog = Invoke-RestMethod -Uri "$BaseUrl/mcp/servers" -TimeoutSec 30
    $entries = @($catalog.servers | Where-Object { $_.name -eq 'HPEXP8' })
    Assert-Test 'Catalog has exactly one HPEXP8 entry' ($entries.Count -eq 1)
    if ($entries.Count -eq 1) {
        Assert-Test 'Catalog MCP URL uses the gateway route' ($entries[0].http_url -match '/hpexp8/mcp$')
        Assert-Test 'Catalog health URL uses the gateway route' ($entries[0].health_http_url -match '/hpexp8/health$')
    }
} catch {
    Assert-Test 'Catalog has exactly one HPEXP8 entry' $false $_.Exception.Message
}

try {
    $health = Invoke-RestMethod -Uri "$BaseUrl/hpexp8/health" -TimeoutSec 30
    Assert-Test 'Health endpoint is healthy' ([bool]$health.ok)
    Assert-Test 'Health reports DPAPI credential store' ($health.credential_store -eq 'dpapi')
    Assert-Test 'Health reports two servers' (@($health.servers).Count -eq 2)
    Assert-Test 'Health includes both configured servers' (
        (@($health.servers) -contains $Servers[0]) -and (@($health.servers) -contains $Servers[1])
    )
    Assert-Test 'Health reports HTTP upstream transport' ($health.transport -eq 'http')
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
        name      = 'xppa_connection_status'
        arguments = @{}
    }
    $result = $response.result
    $payload = Get-Payload $result
    Assert-Test 'Connection status returns a normal result' (-not [bool]$result.isError)
    Assert-Test 'Connection status is scoped to two servers' ($payload.configuredServers -eq 2 -and $payload.selectedServers -eq 2)
    $onlineNames = @($payload.servers | ForEach-Object { $_.server })
    $failureNames = @($payload.failures | ForEach-Object { $_.server })
    Assert-Test 'spapphpxp001 is reachable' ($onlineNames -contains $Servers[0])
    if ($payload.onlineServers -eq 2) {
        Assert-Test 'spapphpxp003 is reachable after firewall opening' ($onlineNames -contains $Servers[1])
    } else {
        Assert-Test 'Blocked spapphpxp003 is reported as a structured failure' (
            $payload.onlineServers -eq 1 -and
            $failureNames -contains $Servers[1] -and
            @($payload.failures | Where-Object {
                $_.server -eq $Servers[1] -and -not [string]::IsNullOrWhiteSpace($_.error)
            }).Count -eq 1
        )
    }
} catch {
    Assert-Test 'Connection status returns a normal result' $false $_.Exception.Message
}

try {
    $response = Invoke-Mcp -Id 3 -Method 'tools/call' -Params @{
        name      = 'xppa_auth_status'
        arguments = @{}
    }
    $result = $response.result
    $payload = Get-Payload $result
    $online = @($payload.servers | Where-Object { $_.server -eq $Servers[0] } | Select-Object -First 1)
    Assert-Test 'Auth status returns a normal result' (-not [bool]$result.isError)
    Assert-Test 'spapphpxp001 authenticates' ($online.Count -eq 1 -and [bool]$online[0].data.authenticated)
    Assert-Test 'Auth status reports plaintext upstream transport' ([bool]$online[0].data.transportEncrypted -eq $false)
} catch {
    Assert-Test 'Auth status returns a normal result' $false $_.Exception.Message
}

try {
    $response = Invoke-Mcp -Id 4 -Method 'tools/call' -Params @{
        name      = 'xppa_list_arrays'
        arguments = @{ server = $Servers[0] }
    }
    $result = $response.result
    $payload = Get-Payload $result
    $online = @($payload.servers | Where-Object { $_.server -eq $Servers[0] } | Select-Object -First 1)
    $arrays = @($online[0].data)
    Assert-Test 'Array list returns a normal result' (-not [bool]$result.isError)
    Assert-Test 'KDCXP01 is discovered on spapphpxp001' (@($arrays | Where-Object { $_.name -eq 'KDCXP01' -or $_.serial -eq 'KDCXP01' }).Count -ge 1)
} catch {
    Assert-Test 'Array list returns a normal result' $false $_.Exception.Message
}

Write-Host
Write-Host ("Result: {0} passed, {1} failed" -f $script:Passed, $script:Failed)
if ($script:Failed -gt 0) { exit 1 }
