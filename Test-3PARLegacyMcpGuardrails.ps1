<#
.SYNOPSIS
    Verify 3PARLegacy gateway-token and read-only guardrails.

    Uses the same two gateway tokens as the other guardrail tests. Values are
    never echoed.

.EXAMPLE
    $env:CADDY_GATEWAY_ADMIN_TOKEN = '<admin token>'
    $env:CADDY_GATEWAY_READONLY_TOKEN = '<read-only token>'
    .\Test-3PARLegacyMcpGuardrails.ps1
#>
[CmdletBinding()]
param(
    [string]$BaseUrl = 'http://10.53.19.120:8081',
    [string]$AdminToken = ($env:CADDY_GATEWAY_ADMIN_TOKEN, $env:COHESITY_GATEWAY_ADMIN_TOKEN | Where-Object { $_ } | Select-Object -First 1),
    [string]$ReadOnlyToken = ($env:CADDY_GATEWAY_READONLY_TOKEN, $env:COHESITY_GATEWAY_READONLY_TOKEN | Where-Object { $_ } | Select-Object -First 1),
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

if (-not $AdminToken) { throw 'Set -AdminToken or $env:CADDY_GATEWAY_ADMIN_TOKEN.' }
if (-not $ReadOnlyToken) { throw 'Set -ReadOnlyToken or $env:CADDY_GATEWAY_READONLY_TOKEN.' }

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
        [string]$Token,
        [Parameter(Mandatory)][int]$Id,
        [Parameter(Mandatory)][string]$Method,
        [hashtable]$Params = @{},
        [hashtable]$ExtraHeaders = @{},
        [switch]$NoToken
    )
    $payload = @{
        jsonrpc = '2.0'
        id      = $Id
        method  = $Method
        params  = $Params
    } | ConvertTo-Json -Depth 8 -Compress

    $headers = @{ 'Accept' = 'application/json, text/event-stream' }
    if (-not $NoToken) { $headers['X-Gateway-Token'] = $Token }
    foreach ($key in $ExtraHeaders.Keys) { $headers[$key] = $ExtraHeaders[$key] }

    Invoke-RestMethod `
        -Uri "$BaseUrl/3parlegacy/mcp" `
        -Method Post `
        -Headers $headers `
        -ContentType 'application/json' `
        -Body $payload `
        -TimeoutSec 180
}

function Get-HttpStatus {
    param(
        [string]$Token,
        [hashtable]$ExtraHeaders = @{},
        [switch]$NoToken
    )
    $payload = @{
        jsonrpc = '2.0'
        id      = 99
        method  = 'tools/list'
        params  = @{}
    } | ConvertTo-Json -Depth 8 -Compress

    $headers = @{ 'Accept' = 'application/json, text/event-stream' }
    if (-not $NoToken) { $headers['X-Gateway-Token'] = $Token }
    foreach ($key in $ExtraHeaders.Keys) { $headers[$key] = $ExtraHeaders[$key] }

    try {
        Invoke-RestMethod `
            -Uri "$BaseUrl/3parlegacy/mcp" `
            -Method Post `
            -Headers $headers `
            -ContentType 'application/json' `
            -Body $payload `
            -TimeoutSec 60 | Out-Null
        return 200
    } catch {
        $response = $_.Exception.Response
        if ($response) { return [int]$response.StatusCode }
        return 0
    }
}

function Get-CallText {
    param($Result)
    return (@($Result.result.content | ForEach-Object { $_.text }) -join ' ')
}

Write-Host "3PARLegacy MCP guardrail test - $BaseUrl"
Write-Host

try {
    $adminTools = Invoke-Mcp -Token $AdminToken -Id 1 -Method 'tools/list'
    $names = @($adminTools.result.tools | ForEach-Object { $_.name })
    $missing = @($ExpectedTools | Where-Object { $_ -notin $names })
    Assert-Test 'Admin sees all 3PARLegacy tools' ($missing.Count -eq 0) "(missing: $($missing -join ','))"
} catch {
    Assert-Test 'Admin sees all 3PARLegacy tools' $false $_.Exception.Message
}

try {
    $readOnlyTools = Invoke-Mcp -Token $ReadOnlyToken -Id 2 -Method 'tools/list'
    $names = @($readOnlyTools.result.tools | ForEach-Object { $_.name })
    $unexpected = @($names | Where-Object { $_ -notin $ExpectedTools })
    Assert-Test 'Read-only sees only allowlisted tools' ($unexpected.Count -eq 0) "(unexpected: $($unexpected -join ','))"
    $bad = @($readOnlyTools.result.tools | Where-Object {
        ([bool]$_.annotations.readOnlyHint -ne $true) -or
        ([bool]$_.annotations.destructiveHint -ne $false)
    })
    Assert-Test 'Read-only tools are annotated read-only' ($bad.Count -eq 0) "(bad: $(@($bad | ForEach-Object { $_.name }) -join ','))"
} catch {
    Assert-Test 'Read-only sees only allowlisted tools' $false $_.Exception.Message
}

try {
    $response = Invoke-Mcp -Token $ReadOnlyToken -Id 3 -Method 'tools/call' -Params @{
        name      = 'not_a_real_tool'
        arguments = @{}
    }
    $text = Get-CallText $response
    Assert-Test 'Read-only unknown tool is denied' ([bool]$response.result.isError -and $text -match 'not available') $text
} catch {
    Assert-Test 'Read-only unknown tool is denied' $false $_.Exception.Message
}

Assert-Test 'Missing gateway token is rejected' ((Get-HttpStatus -NoToken) -eq 401)
Assert-Test 'Unknown gateway token is rejected' ((Get-HttpStatus -Token 'not-a-real-token') -eq 403)
Assert-Test 'Client-supplied 3PAR credential is rejected' (
    (Get-HttpStatus -Token $AdminToken -ExtraHeaders @{ 'X-3PAR-Password' = 'probe-value' }) -eq 400
)

try {
    $response = Invoke-Mcp -Token $ReadOnlyToken -Id 4 -Method 'tools/call' -Params @{
        name      = 'threepar_connection_status'
        arguments = @{}
    }
    $result = $response.result
    $payload = $result.structuredContent
    if (-not $payload) {
        $payload = (Get-CallText $response) | ConvertFrom-Json
    }
    $payloadJson = $payload | ConvertTo-Json -Depth 12 -Compress
    Assert-Test 'Read-only connection status is allowed' (
        (-not [bool]$result.isError) -and ($payload.configuredArrays -eq 2)
    )
    Assert-Test 'Both configured arrays are present, rolled-back arrays are not' (
        $payloadJson -match 'JPN3PAR01' -and
        $payloadJson -match 'cw3par02\.phsabc\.ehcnet\.ca' -and
        $payloadJson -notmatch 'CWALLETRA01|SMHALLETRA01|10\.1\.63\.165|172\.19\.240\.194'
    )
} catch {
    Assert-Test 'Read-only connection status is allowed' $false $_.Exception.Message
}

Write-Host
Write-Host ("Result: {0} passed, {1} failed" -f $script:Passed, $script:Failed)
if ($script:Failed -gt 0) { exit 1 }
