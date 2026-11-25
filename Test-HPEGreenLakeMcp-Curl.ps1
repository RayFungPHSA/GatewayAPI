<#
.SYNOPSIS
    curl.exe end-to-end test for the HPEGreenLake MCP route through the gateway.

    Reuses $env:CADDY_GATEWAY_TOKEN. The token is sent only in the
    X-Gateway-Token header and is never echoed or written to disk.

.EXAMPLE
    $env:CADDY_GATEWAY_TOKEN = '<token issued to you>'
    .\Test-HPEGreenLakeMcp-Curl.ps1

.EXAMPLE
    $env:CADDY_GATEWAY_TOKEN = '<token issued to you>'
    .\Test-HPEGreenLakeMcp-Curl.ps1 -BaseUrl https://10.53.19.120:8088 -CurlArgs '--ssl-no-revoke'
#>
[CmdletBinding()]
param(
    [string]$BaseUrl = 'http://10.53.19.120:8081',
    [string[]]$CurlArgs = @()
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
    throw 'Set $env:CADDY_GATEWAY_TOKEN to your gateway token before running this test.'
}

$ManifestPath = Join-Path $PSScriptRoot 'hpegreenlake-mcp\src\greenlake-readonly-tools.json'
$Manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
$ExpectedToolCount = 6 + @($Manifest.endpoints).Count

function Invoke-CurlJsonRpc {
    param(
        [Parameter(Mandatory)][int]$Id,
        [Parameter(Mandatory)][string]$Method,
        [string]$ParamsJson = '{}',
        [string]$Token = ($env:CADDY_GATEWAY_TOKEN, $env:COHESITY_GATEWAY_TOKEN | Where-Object { $_ } | Select-Object -First 1),
        [hashtable]$ExtraHeaders = @{}
    )
    $bodyTmp = [IO.Path]::GetTempFileName()
    $outTmp = [IO.Path]::GetTempFileName()
    try {
        $json = '{{"jsonrpc":"2.0","id":{0},"method":"{1}","params":{2}}}' -f $Id, $Method, $ParamsJson
        Set-Content -LiteralPath $bodyTmp -Value $json -NoNewline

        $curlParams = @('-sS', '-o', $outTmp, '-w', '%{http_code}', '--max-time', '180') + $CurlArgs
        if ($Token) {
            $curlParams += @('-H', "X-Gateway-Token: $Token")
        }
        foreach ($key in $ExtraHeaders.Keys) {
            $curlParams += @('-H', "$key`: $($ExtraHeaders[$key])")
        }
        $curlParams += @(
            '-H', 'Accept: application/json, text/event-stream',
            '-H', 'Content-Type: application/json',
            '--data-binary', "@$bodyTmp",
            "$BaseUrl/hpegreenlake/mcp"
        )

        $code = ((& curl.exe @curlParams) | Out-String).Trim()
        $text = Get-Content -LiteralPath $outTmp -Raw -ErrorAction SilentlyContinue
        return [pscustomobject]@{ Status = [int]$code; Json = ($text | ConvertFrom-Json -ErrorAction SilentlyContinue) }
    } finally {
        Remove-Item -LiteralPath $bodyTmp, $outTmp -Force -ErrorAction SilentlyContinue
    }
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

Write-Host "HPEGreenLake MCP curl test - $BaseUrl"
Write-Host

try {
    $healthTmp = [IO.Path]::GetTempFileName()
    $healthArgs = @('-sS', '-o', $healthTmp, '-w', '%{http_code}', '--max-time', '15') + $CurlArgs + "$BaseUrl/hpegreenlake/health"
    $code = ((& curl.exe @healthArgs) | Out-String).Trim()
    $health = (Get-Content -LiteralPath $healthTmp -Raw | ConvertFrom-Json)
    Assert-Test 'Bridge health endpoint' (([int]$code -eq 200) -and ($health.ok -eq $true) -and ($health.auth -eq 'gateway_token')) "(status $code)"
    Remove-Item -LiteralPath $healthTmp -Force -ErrorAction SilentlyContinue
} catch {
    Assert-Test 'Bridge health endpoint' $false $_.Exception.Message
}

try {
    $initParams = '{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"caddy-gateway-curl-test","version":"2.0"}}'
    $r = Invoke-CurlJsonRpc -Id 1 -Method 'initialize' -ParamsJson $initParams
    Assert-Test 'MCP initialize' (($r.Status -eq 200) -and ($r.Json.result.serverInfo.name -eq 'hpegreenlake-http-bridge')) "(status $($r.Status))"
} catch {
    Assert-Test 'MCP initialize' $false $_.Exception.Message
}

try {
    $r = Invoke-CurlJsonRpc -Id 2 -Method 'tools/list'
    $count = @($r.Json.result.tools).Count
    Assert-Test 'MCP tools/list' (($r.Status -eq 200) -and ($count -eq $ExpectedToolCount)) "(status $($r.Status), $count tools, expected $ExpectedToolCount)"
} catch {
    Assert-Test 'MCP tools/list' $false $_.Exception.Message
}

try {
    $r = Invoke-CurlJsonRpc -Id 3 -Method 'tools/call' -ParamsJson '{"name":"greenlake_auth_status","arguments":{"refresh":false}}'
    $text = (@($r.Json.result.content | ForEach-Object { $_.text }) -join ' ')
    Assert-Test 'MCP tools/call greenlake_auth_status' (($r.Status -eq 200) -and (-not [bool]$r.Json.result.isError) -and ($text -match 'authenticated')) "(status $($r.Status))"
} catch {
    Assert-Test 'MCP tools/call greenlake_auth_status' $false $_.Exception.Message
}

try {
    $r = Invoke-CurlJsonRpc -Id 9 -Method 'tools/list' -Token ''
    Assert-Test 'Missing token is rejected' ($r.Status -eq 401) "(status $($r.Status))"
} catch {
    Assert-Test 'Missing token is rejected' $false $_.Exception.Message
}

try {
    $r = Invoke-CurlJsonRpc -Id 10 -Method 'tools/list' -Token 'not-a-real-token'
    Assert-Test 'Invalid token is rejected' ($r.Status -eq 403) "(status $($r.Status))"
} catch {
    Assert-Test 'Invalid token is rejected' $false $_.Exception.Message
}

try {
    $r = Invoke-CurlJsonRpc -Id 11 -Method 'tools/list' -ExtraHeaders @{ 'X-GreenLake-Api-Key' = 'client-supplied-value' }
    Assert-Test 'Client-supplied key is rejected' ($r.Status -eq 400) "(status $($r.Status))"
} catch {
    Assert-Test 'Client-supplied key is rejected' $false $_.Exception.Message
}

Write-Host
Write-Host ("Result: {0} passed, {1} failed" -f $script:Passed, $script:Failed) -ForegroundColor Cyan
if ($script:Failed -gt 0) { exit 1 }
