<#
.SYNOPSIS
    Verify read-only vs admin guardrails on the Cohesity MCP endpoint.

    Uses two gateway tokens: one admin and one read-only. Tokens may be passed
    as parameters or set in $env:CADDY_GATEWAY_ADMIN_TOKEN and
    $env:CADDY_GATEWAY_READONLY_TOKEN. Values are never echoed.
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

function Invoke-Mcp {
    param(
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][int]$Id,
        [Parameter(Mandatory)][string]$Method,
        [hashtable]$Params = @{},
        [hashtable]$ExtraHeaders = @{}
    )
    $payload = @{
        jsonrpc = '2.0'
        id      = $Id
        method  = $Method
        params  = $Params
    } | ConvertTo-Json -Depth 8 -Compress

    $headers = @{
        'X-Gateway-Token' = $Token
        'Accept'          = 'application/json, text/event-stream'
    }
    foreach ($key in $ExtraHeaders.Keys) {
        $headers[$key] = $ExtraHeaders[$key]
    }

    Invoke-RestMethod `
        -Uri "$BaseUrl/cohesity/mcp" `
        -Method Post `
        -Headers $headers `
        -ContentType 'application/json' `
        -Body $payload `
        -TimeoutSec 180
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

function Get-CallText {
    param($Result)
    return (@($Result.result.content | ForEach-Object { $_.text }) -join ' ')
}

Write-Host "Cohesity MCP guardrail test - $BaseUrl"
Write-Host

$adminTools = $null
$roTools = $null

try {
    $adminTools = Invoke-Mcp -Token $AdminToken -Id 1 -Method 'tools/list'
    $names = @($adminTools.result.tools | ForEach-Object { $_.name })
    $ok = ($names -contains 'run_backup') -and ($names -contains 'collect_protection_group_usage')
    Assert-Test 'Admin sees admin-only tools' $ok
} catch {
    Assert-Test 'Admin sees admin-only tools' $false $_.Exception.Message
}

try {
    $roTools = Invoke-Mcp -Token $ReadOnlyToken -Id 2 -Method 'tools/list'
    $names = @($roTools.result.tools | ForEach-Object { $_.name })
    $leaked = @($names | Where-Object { $_ -in @('run_backup', 'collect_protection_group_usage') })
    Assert-Test 'Read-only tools/list hides admin tools' ($leaked.Count -eq 0) "(leaked: $($leaked -join ','))"
} catch {
    Assert-Test 'Read-only tools/list hides admin tools' $false $_.Exception.Message
}

try {
    $bad = @($roTools.result.tools | Where-Object {
        ([bool]$_.annotations.readOnlyHint -ne $true) -or ([bool]$_.annotations.destructiveHint -ne $false)
    })
    Assert-Test 'Read-only tools are annotated read-only' ($bad.Count -eq 0) "(bad: $(@($bad | ForEach-Object { $_.name }) -join ','))"
} catch {
    Assert-Test 'Read-only tools are annotated read-only' $false $_.Exception.Message
}

try {
    $apiTool = @($roTools.result.tools | Where-Object { $_.name -eq 'api_request' })[0]
    $enum = @($apiTool.inputSchema.properties.method.enum)
    Assert-Test 'Read-only api_request schema is GET-only' (($enum.Count -eq 1) -and ($enum[0] -eq 'GET')) "(enum: $($enum -join ','))"
} catch {
    Assert-Test 'Read-only api_request schema is GET-only' $false $_.Exception.Message
}

try {
    $r = Invoke-Mcp -Token $ReadOnlyToken -Id 3 -Method 'tools/call' -Params @{
        name = 'run_backup'; arguments = @{ group_id = 'guardrail-test' }
    }
    $text = Get-CallText $r
    Assert-Test 'Read-only run_backup is denied' ([bool]$r.result.isError -and $text -match 'admin-only') $text
} catch {
    Assert-Test 'Read-only run_backup is denied' $false $_.Exception.Message
}

try {
    $r = Invoke-Mcp -Token $ReadOnlyToken -Id 4 -Method 'tools/call' -Params @{
        name = 'collect_protection_group_usage'; arguments = @{ cluster_id = 'guardrail-test' }
    }
    $text = Get-CallText $r
    Assert-Test 'Read-only usage collection is denied' ([bool]$r.result.isError -and $text -match 'admin-only') $text
} catch {
    Assert-Test 'Read-only usage collection is denied' $false $_.Exception.Message
}

try {
    $r = Invoke-Mcp -Token $ReadOnlyToken -Id 5 -Method 'tools/call' -Params @{
        name = 'api_request'; arguments = @{ method = 'POST'; path = '/mcm/tenants'; body = @{} }
    }
    $text = Get-CallText $r
    Assert-Test 'Read-only api_request POST is denied' ([bool]$r.result.isError -and $text -match 'GET only') $text
} catch {
    Assert-Test 'Read-only api_request POST is denied' $false $_.Exception.Message
}

try {
    $r = Invoke-Mcp -Token $ReadOnlyToken -Id 6 -Method 'tools/call' -Params @{
        name = 'api_request'; arguments = @{ method = 'GET'; path = '/mcm/tenants' }
    }
    Assert-Test 'Read-only api_request GET is allowed' (-not [bool]$r.result.isError) (Get-CallText $r)
} catch {
    Assert-Test 'Read-only api_request GET is allowed' $false $_.Exception.Message
}

try {
    $r = Invoke-Mcp -Token $AdminToken -Id 7 -Method 'tools/call' -Params @{
        name = 'api_request'; arguments = @{ method = 'GET'; path = '/mcm/tenants' }
    }
    Assert-Test 'Admin api_request GET is allowed' (-not [bool]$r.result.isError) (Get-CallText $r)
} catch {
    Assert-Test 'Admin api_request GET is allowed' $false $_.Exception.Message
}

try {
    Invoke-Mcp -Token $ReadOnlyToken -Id 8 -Method 'tools/list' -ExtraHeaders @{ 'X-Cohesity-Api-Key' = 'client-supplied-value' } -ErrorAction Stop | Out-Null
    Assert-Test 'Client-supplied key is rejected' $false '(request unexpectedly succeeded)'
} catch {
    $code = [int]$_.Exception.Response.StatusCode
    Assert-Test 'Client-supplied key is rejected' ($code -eq 400) "(status $code)"
}

Write-Host
Write-Host ("Result: {0} passed, {1} failed" -f $script:Passed, $script:Failed) -ForegroundColor Cyan
if ($script:Failed -gt 0) { exit 1 }
