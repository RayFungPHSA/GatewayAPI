<#
.SYNOPSIS
    End-to-end test for the Cohesity MCP route through the Caddy gateway.

    The caller's per-user gateway token must be in $env:COHESITY_GATEWAY_TOKEN.
    It is sent in the X-Gateway-Token header. The Cohesity API key is never
    sent by a client and is never written to a file by this script.

.EXAMPLE
    $env:COHESITY_GATEWAY_TOKEN = '<token issued to you>'
    .\Test-CohesityMcp.ps1

.EXAMPLE
    $env:COHESITY_GATEWAY_TOKEN = '<token issued to you>'
    .\Test-CohesityMcp.ps1 -BaseUrl https://10.53.19.120:8088 -AllowUntrustedCertificate
#>
[CmdletBinding()]
param(
    [string]$BaseUrl = 'http://10.53.19.120:8081',
    [switch]$AllowUntrustedCertificate
)

$ErrorActionPreference = 'Stop'
$BaseUrl = $BaseUrl.TrimEnd('/')
$script:Passed = 0
$script:Failed = 0

if (-not $env:COHESITY_GATEWAY_TOKEN) {
    throw 'Set $env:COHESITY_GATEWAY_TOKEN to your gateway token before running this test.'
}

if ($AllowUntrustedCertificate) {
    [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
}

function Invoke-McpJsonRpc {
    param(
        [Parameter(Mandatory)][int]$Id,
        [Parameter(Mandatory)][string]$Method,
        [hashtable]$Params = @{},
        [string]$Token = $env:COHESITY_GATEWAY_TOKEN
    )
    $payload = @{
        jsonrpc = '2.0'
        id      = $Id
        method  = $Method
        params  = $Params
    } | ConvertTo-Json -Depth 8 -Compress

    Invoke-RestMethod `
        -Uri "$BaseUrl/cohesity/mcp" `
        -Method Post `
        -Headers @{
            'X-Gateway-Token' = $Token
            'Accept'          = 'application/json, text/event-stream'
        } `
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

Write-Host "Cohesity MCP gateway test - $BaseUrl"
Write-Host

try {
    if ($BaseUrl -like 'https:*') {
        # PowerShell 5.1 can fail the first HTTPS GET against the local-CA
        # listener even with the validation callback set. curl.exe is reliable
        # here; no token or credential is involved in a health request.
        $healthTmp = [IO.Path]::GetTempFileName()
        try {
            $code = ((& curl.exe -sS -o $healthTmp -w '%{http_code}' --max-time 15 --ssl-no-revoke "$BaseUrl/cohesity/health") | Out-String).Trim()
            $health = Get-Content -LiteralPath $healthTmp -Raw | ConvertFrom-Json
            Assert-Test 'Bridge health endpoint' (([int]$code -eq 200) -and $health.ok -eq $true -and $health.auth -eq 'gateway_token') "(status $code)"
        } finally {
            Remove-Item -LiteralPath $healthTmp -Force -ErrorAction SilentlyContinue
        }
    } else {
        $health = Invoke-RestMethod -Uri "$BaseUrl/cohesity/health" -TimeoutSec 15
        Assert-Test 'Bridge health endpoint' ($health.ok -eq $true -and $health.auth -eq 'gateway_token')
    }
} catch {
    Assert-Test 'Bridge health endpoint' $false $_.Exception.Message
}

try {
    $init = Invoke-McpJsonRpc -Id 1 -Method 'initialize' -Params @{
        protocolVersion = '2025-06-18'
        capabilities    = @{}
        clientInfo      = @{ name = 'caddy-gateway-test'; version = '2.0' }
    }
    Assert-Test 'MCP initialize' ($init.result.serverInfo.name -eq 'cohesity-http-bridge')
} catch {
    Assert-Test 'MCP initialize' $false $_.Exception.Message
}

try {
    $tools = Invoke-McpJsonRpc -Id 2 -Method 'tools/list'
    $count = @($tools.result.tools).Count
    Assert-Test 'MCP tools/list' ($count -gt 0) "(returned $count tools)"
} catch {
    Assert-Test 'MCP tools/list' $false $_.Exception.Message
}

try {
    $call = Invoke-McpJsonRpc -Id 3 -Method 'tools/call' -Params @{
        name      = 'list_clusters'
        arguments = @{}
    }
    $isError = [bool]$call.result.isError
    Assert-Test 'MCP tools/call list_clusters' (-not $isError)
} catch {
    Assert-Test 'MCP tools/call list_clusters' $false $_.Exception.Message
}

try {
    Invoke-McpJsonRpc -Id 9 -Method 'tools/list' -Token '' -ErrorAction Stop | Out-Null
    Assert-Test 'Missing token is rejected' $false '(request unexpectedly succeeded)'
} catch {
    $code = [int]$_.Exception.Response.StatusCode
    Assert-Test 'Missing token is rejected' ($code -eq 401) "(status $code)"
}

try {
    Invoke-McpJsonRpc -Id 10 -Method 'tools/list' -Token 'not-a-real-token' -ErrorAction Stop | Out-Null
    Assert-Test 'Invalid token is rejected' $false '(request unexpectedly succeeded)'
} catch {
    $code = [int]$_.Exception.Response.StatusCode
    Assert-Test 'Invalid token is rejected' ($code -eq 403) "(status $code)"
}

Write-Host
Write-Host ("Result: {0} passed, {1} failed" -f $script:Passed, $script:Failed) -ForegroundColor Cyan
if ($script:Failed -gt 0) { exit 1 }
