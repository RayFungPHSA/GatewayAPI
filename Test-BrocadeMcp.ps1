<#
.SYNOPSIS
    Validate the Brocade SANnav MCP through the native Caddy gateway.

    Confirms discovery, health, read-only tool annotations, and live read-only
    results for all nine tools. Counts are compared for consistency rather than
    pinned, because the SAN inventory changes over time.

.EXAMPLE
    $env:CADDY_GATEWAY_TOKEN = '<your token>'
    .\Test-BrocadeMcp.ps1
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
    'list-fabrics'
    'list-switches'
    'list-hosts'
    'list-host-ports'
    'list-storages'
    'list-storage-ports'
    'list-zones'
    'get-connectivity-map'
    'get-overview'
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
        -Uri "$BaseUrl/brocade/mcp" `
        -Method Post `
        -Headers @{
            'X-Gateway-Token' = $Token
            'Accept'          = 'application/json, text/event-stream'
        } `
        -ContentType 'application/json' `
        -Body $payload `
        -TimeoutSec 300
}

function Get-Payload {
    param($Result)
    if ($Result.structuredContent) { return $Result.structuredContent }
    $text = (@($Result.content | ForEach-Object { $_.text }) -join ' ')
    return ($text | ConvertFrom-Json)
}

function Invoke-Tool {
    param(
        [Parameter(Mandatory)][int]$Id,
        [Parameter(Mandatory)][string]$Name,
        [hashtable]$Arguments = @{}
    )
    $response = Invoke-Mcp -Id $Id -Method 'tools/call' -Params @{
        name      = $Name
        arguments = $Arguments
    }
    $result = $response.result
    $payload = Get-Payload $result
    $data = @($payload.servers | Select-Object -First 1)[0].data
    return [pscustomobject]@{ Result = $result; Payload = $payload; Data = $data }
}

Write-Host "Brocade SANnav MCP test - $BaseUrl"
Write-Host

try {
    $catalog = Invoke-RestMethod -Uri "$BaseUrl/mcp/servers" -TimeoutSec 30
    $entries = @($catalog.servers | Where-Object { $_.name -eq 'Brocade' })
    Assert-Test 'Catalog has exactly one Brocade entry' ($entries.Count -eq 1)
    if ($entries.Count -eq 1) {
        Assert-Test 'Catalog MCP URL uses the gateway route' ($entries[0].http_url -match '/brocade/mcp$')
        Assert-Test 'Catalog health URL uses the gateway route' ($entries[0].health_http_url -match '/brocade/health$')
    }
} catch {
    Assert-Test 'Catalog has exactly one Brocade entry' $false $_.Exception.Message
}

try {
    $health = Invoke-RestMethod -Uri "$BaseUrl/brocade/health" -TimeoutSec 30
    Assert-Test 'Health endpoint is healthy' ([bool]$health.ok)
    Assert-Test 'Health reports DPAPI credential store' ($health.credential_store -eq 'dpapi')
    Assert-Test 'Health reports HTTPS upstream transport' ($health.transport -eq 'https')
    Assert-Test 'Health reports all nine tools' ($health.tool_count -eq $ExpectedTools.Count)
    Assert-Test 'Health does not echo a username' (-not $health.PSObject.Properties['username'])
    Assert-Test 'Health does not echo a password' (-not $health.PSObject.Properties['password'])
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
    $overview = Invoke-Tool -Id 2 -Name 'get-overview'
    Assert-Test 'get-overview returns a normal result' (-not [bool]$overview.Result.isError)
    Assert-Test 'get-overview reports the SANnav server' ($overview.Payload.onlineServers -eq 1 -and $overview.Payload.configuredServers -eq 1)
    Assert-Test 'get-overview finds fabrics and switches' (
        [int]$overview.Data.fabrics.total -gt 0 -and [int]$overview.Data.switches.total -gt 0
    )
    Assert-Test 'get-overview finds hosts and storages' (
        [int]$overview.Data.hosts.total -gt 0 -and [int]$overview.Data.storages.total -gt 0
    )
} catch {
    Assert-Test 'get-overview returns a normal result' $false $_.Exception.Message
}

$listChecks = @(
    @{ Id = 3; Name = 'list-fabrics';       Key = 'fabrics';       Count = 'total' }
    @{ Id = 4; Name = 'list-switches';      Key = 'switches';      Count = 'total' }
    @{ Id = 5; Name = 'list-hosts';         Key = 'hosts';         Count = 'total' }
    @{ Id = 6; Name = 'list-storages';      Key = 'storages';      Count = 'total' }
    @{ Id = 7; Name = 'list-host-ports';    Key = 'ports';         Count = 'total' }
    @{ Id = 8; Name = 'list-storage-ports'; Key = 'ports';         Count = 'total' }
    @{ Id = 9; Name = 'list-zones';         Key = 'zones';         Count = 'totalZones' }
    @{ Id = 10; Name = 'get-connectivity-map'; Key = 'connections'; Count = 'totalConnections' }
)
foreach ($check in $listChecks) {
    try {
        $response = Invoke-Tool -Id $check.Id -Name $check.Name
        $rows = @($response.Data.($check.Key))
        $total = [int]$response.Data.($check.Count)
        Assert-Test "$($check.Name) returns a normal result" (-not [bool]$response.Result.isError)
        Assert-Test "$($check.Name) row count matches total" ($total -eq $rows.Count -and $total -gt 0) "(total=$total rows=$($rows.Count))"
    } catch {
        Assert-Test "$($check.Name) returns a normal result" $false $_.Exception.Message
    }
}

try {
    $filtered = Invoke-Tool -Id 11 -Name 'list-hosts' -Arguments @{ search = 'zzz-no-such-host-zzz' }
    Assert-Test 'list-hosts search filter returns zero rows' (
        (-not [bool]$filtered.Result.isError) -and [int]$filtered.Data.total -eq 0
    )
} catch {
    Assert-Test 'list-hosts search filter returns zero rows' $false $_.Exception.Message
}

Write-Host
Write-Host ("Result: {0} passed, {1} failed" -f $script:Passed, $script:Failed)
if ($script:Failed -gt 0) { exit 1 }
