<#
.SYNOPSIS
    End-to-end test for the HPEGreenLake MCP route through the Caddy gateway.

    The same per-user gateway token used for Cohesity is reused here. Keep it in
    $env:COHESITY_GATEWAY_TOKEN. The script never echoes or writes the token.

.EXAMPLE
    $env:COHESITY_GATEWAY_TOKEN = '<token issued to you>'
    .\Test-HPEGreenLakeMcp.ps1

.EXAMPLE
    $env:COHESITY_GATEWAY_TOKEN = '<token issued to you>'
    .\Test-HPEGreenLakeMcp.ps1 -BaseUrl https://10.53.19.120:8088 -AllowUntrustedCertificate
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

$ManifestPath = Join-Path $PSScriptRoot 'hpegreenlake-mcp\src\greenlake-readonly-tools.json'
$Manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
$ExpectedToolCount = 6 + @($Manifest.endpoints).Count

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
        -Uri "$BaseUrl/hpegreenlake/mcp" `
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

Write-Host "HPEGreenLake MCP gateway test - $BaseUrl"
Write-Host

try {
    if ($BaseUrl -like 'https:*') {
        # PowerShell 5.1 can fail the first HTTPS GET against the local-CA
        # listener even with the validation callback set. curl.exe is reliable
        # here; no token or credential is involved in a health request.
        $healthTmp = [IO.Path]::GetTempFileName()
        try {
            $code = ((& curl.exe -sS -o $healthTmp -w '%{http_code}' --max-time 15 --ssl-no-revoke "$BaseUrl/hpegreenlake/health") | Out-String).Trim()
            $health = Get-Content -LiteralPath $healthTmp -Raw | ConvertFrom-Json
            Assert-Test 'Bridge health endpoint' (([int]$code -eq 200) -and $health.ok -eq $true -and $health.auth -eq 'gateway_token' -and $health.server -eq 'hpegreenlake') "(status $code)"
        } finally {
            Remove-Item -LiteralPath $healthTmp -Force -ErrorAction SilentlyContinue
        }
    } else {
        $health = Invoke-RestMethod -Uri "$BaseUrl/hpegreenlake/health" -TimeoutSec 15
        Assert-Test 'Bridge health endpoint' ($health.ok -eq $true -and $health.auth -eq 'gateway_token' -and $health.server -eq 'hpegreenlake')
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
    Assert-Test 'MCP initialize' ($init.result.serverInfo.name -eq 'hpegreenlake-http-bridge')
} catch {
    Assert-Test 'MCP initialize' $false $_.Exception.Message
}

try {
    $tools = Invoke-McpJsonRpc -Id 2 -Method 'tools/list'
    $count = @($tools.result.tools).Count
    Assert-Test 'MCP tools/list' ($count -eq $ExpectedToolCount) "(returned $count tools, expected $ExpectedToolCount)"
} catch {
    Assert-Test 'MCP tools/list' $false $_.Exception.Message
}

try {
    $call = Invoke-McpJsonRpc -Id 3 -Method 'tools/call' -Params @{
        name      = 'greenlake_auth_status'
        arguments = @{ refresh = $false }
    }
    $text = (@($call.result.content | ForEach-Object { $_.text }) -join ' ')
    Assert-Test 'MCP tools/call greenlake_auth_status' ((-not [bool]$call.result.isError) -and ($text -match 'authenticated')) $text
} catch {
    Assert-Test 'MCP tools/call greenlake_auth_status' $false $_.Exception.Message
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
