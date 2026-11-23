<#
.SYNOPSIS
    Remote smoke test for the Caddy API gateway.

.DESCRIPTION
    Run this from any Windows 11 machine that can reach the gateway over the
    network. It checks routing, prefix stripping, upstream Host/TLS handling,
    status passthrough, POST forwarding and latency.

    TWO WAYS TO RUN

    A) Trusted (recommended). On the remote machine, as Administrator,
       install the public CA cert (no private key is distributed):
         certutil -addstore -f Root .\caddy-local-root.crt
       Then run without -SkipCertCheck:
         powershell.exe -ExecutionPolicy Bypass -File .\Test-CaddyGateway.ps1
       The cert covers both gateway.localhost and 10.53.19.120, so no hosts
       file change is needed.

    B) Plain HTTP (no certificate at all) - easiest for remote machines:
         powershell.exe -ExecutionPolicy Bypass -File .\Test-CaddyGateway.ps1 -Http

    C) Quick HTTPS, no admin on the remote machine (cert validation skipped):
         powershell.exe -ExecutionPolicy Bypass -File .\Test-CaddyGateway.ps1 `
             -Gateway https://10.53.19.120:8088 -SkipCertCheck

.PARAMETER Gateway
    Base URL of the gateway. Default: https://10.53.19.120:8088

.PARAMETER SkipCertCheck
    Disable TLS certificate validation for this process only.

.PARAMETER Http
    Shortcut for -Gateway http://10.53.19.120:8081 (the plain HTTP listener).

.PARAMETER TimeoutSec
    Per-request timeout. Default: 25.
#>
[CmdletBinding()]
param(
    [string]$Gateway = 'https://10.53.19.120:8088',
    [switch]$SkipCertCheck,
    [switch]$Http,
    [int]$TimeoutSec = 25
)

$ErrorActionPreference = 'Stop'
if ($Http) { $Gateway = 'http://10.53.19.120:8081' }
$Gateway = $Gateway.TrimEnd('/')

if ($SkipCertCheck -and $Gateway -like 'http:*') {
    Write-Warning '-SkipCertCheck has no effect for an http:// gateway.'
}

if ($SkipCertCheck -and $Gateway -like 'https:*') {
    # A PowerShell scriptblock callback is invoked on a .NET worker thread and
    # is unreliable here; use a compiled .NET delegate instead.
    Add-Type -TypeDefinition @'
using System.Net;
using System.Net.Security;
public static class CaddyGatewayTlsBypass {
    public static void Enable() {
        ServicePointManager.ServerCertificateValidationCallback =
            (sender, cert, chain, errors) => true;
    }
}
'@
    [CaddyGatewayTlsBypass]::Enable()
    Write-Warning 'TLS certificate validation is DISABLED for this process (-SkipCertCheck).'
}

$script:Passed = 0
$script:Failed = 0

function Test-Gateway {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Assertion
    )
    try {
        $ok = & $Assertion
        if ($ok) {
            Write-Host ("  PASS  {0}" -f $Name) -ForegroundColor Green
            $script:Passed++
        } else {
            Write-Host ("  FAIL  {0} (assertion returned false)" -f $Name) -ForegroundColor Red
            $script:Failed++
        }
    } catch {
        Write-Host ("  FAIL  {0} - {1}" -f $Name, $_.Exception.Message) -ForegroundColor Red
        $script:Failed++
    }
}

Write-Host "Testing gateway: $Gateway" -ForegroundColor Cyan
Write-Host ("TLS: {0}" -f $(if ($Gateway -like 'http:*') { 'none (plain HTTP)' } elseif ($SkipCertCheck) { 'validation skipped' } else { 'validated against Windows trust store' })) -ForegroundColor DarkGray

if ($Gateway -like 'https:*' -and -not $SkipCertCheck) {
    $trustedRoot = @(
        Get-ChildItem Cert:\LocalMachine\Root, Cert:\CurrentUser\Root -ErrorAction SilentlyContinue |
            Where-Object { $_.Subject -like '*Caddy Local Authority*' }
    )
    if ($trustedRoot.Count -eq 0) {
        Write-Warning 'Caddy local CA root is NOT in this machine trust store.'
        Write-Warning 'Run as Administrator: certutil -addstore -f Root .\caddy-local-root.crt'
        Write-Warning 'Or rerun with -SkipCertCheck to skip TLS validation.'
    } else {
        Write-Host ("CA root found: {0}" -f $trustedRoot[0].Subject) -ForegroundColor DarkGray
    }
}

Write-Host ('-' * 64) -ForegroundColor DarkGray

# Preflight: verify TCP reachability before running the HTTP assertions.
$authority = $Gateway -replace '^https?://', '' -replace '/.*$', ''
$peerHost  = $authority -replace ':\d+$', ''
$peerPort  = if ($authority -match ':(\d+)$') { [int]$Matches[1] } elseif ($Gateway -like 'https:*') { 443 } else { 80 }
$tcpOk = Test-NetConnection -ComputerName $peerHost -Port $peerPort -InformationLevel Quiet -WarningAction SilentlyContinue
if (-not $tcpOk) {
    Write-Warning "TCP preflight FAILED: cannot reach ${peerHost}:${peerPort}."
    Write-Warning 'Check routing, VPN, and the gateway firewall (inbound TCP 8088).'
}

Test-Gateway 'Gateway reachable / catch-all response' {
    $body = Invoke-RestMethod -Uri "$Gateway/" -TimeoutSec $TimeoutSec
    $body -like 'Caddy gateway is running*'
}

Test-Gateway 'Route /todos -> jsonplaceholder' {
    $r = Invoke-RestMethod -Uri "$Gateway/todos/1" -TimeoutSec $TimeoutSec
    ($r.id -eq 1) -and ($r.userId -eq 1)
}

Test-Gateway 'Route /httpbin -> httpbin.org' {
    $r = Invoke-RestMethod -Uri "$Gateway/httpbin/get" -TimeoutSec $TimeoutSec
    $r.url -like 'https://httpbin.org*/get'
}

Test-Gateway 'Upstream Host header set by Caddy' {
    $r = Invoke-RestMethod -Uri "$Gateway/httpbin/get" -TimeoutSec $TimeoutSec
    $r.headers.Host -like 'httpbin.org*'
}

Test-Gateway 'Original host preserved in X-Forwarded-Host' {
    $expected = $Gateway -replace '^https?://', ''
    $r = Invoke-RestMethod -Uri "$Gateway/httpbin/get" -TimeoutSec $TimeoutSec
    $r.headers.'X-Forwarded-Host' -eq $expected
}

Test-Gateway 'Query string forwarded upstream' {
    $r = Invoke-RestMethod -Uri "$Gateway/httpbin/get?foo=bar&n=2" -TimeoutSec $TimeoutSec
    ($r.args.foo -eq 'bar') -and ($r.args.n -eq '2')
}

Test-Gateway 'Nested path forwarded (prefix stripped)' {
    $r = Invoke-RestMethod -Uri "$Gateway/httpbin/anything/a/b/c" -TimeoutSec $TimeoutSec
    $r.url -like '*/anything/a/b/c'
}

Test-Gateway 'Upstream status passthrough (418)' {
    $code = $null
    try {
        $resp = Invoke-WebRequest -Uri "$Gateway/httpbin/status/418" -TimeoutSec $TimeoutSec -UseBasicParsing
        $code = [int]$resp.StatusCode
    } catch {
        if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
        else { throw }
    }
    $code -eq 418
}

Test-Gateway 'POST body forwarded' {
    $r = Invoke-RestMethod -Uri "$Gateway/httpbin/post" -Method Post `
        -Body '{"hello":"world"}' -ContentType 'application/json' -TimeoutSec $TimeoutSec
    ($r.url -like '*/post') -and ($r.data -eq '{"hello":"world"}')
}

Test-Gateway 'Response time under 3 seconds' {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    Invoke-RestMethod -Uri "$Gateway/todos/1" -TimeoutSec $TimeoutSec | Out-Null
    $sw.Stop()
    Write-Host ("        latency: {0} ms" -f $sw.ElapsedMilliseconds) -ForegroundColor DarkGray
    $sw.ElapsedMilliseconds -lt 3000
}

Write-Host ('-' * 64) -ForegroundColor DarkGray
$color = if ($script:Failed -gt 0) { 'Yellow' } else { 'Green' }
Write-Host ("Result: {0} passed, {1} failed" -f $script:Passed, $script:Failed) -ForegroundColor $color
if ($script:Failed -gt 0) { exit 1 }
