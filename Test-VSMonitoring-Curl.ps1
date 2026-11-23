<#
.SYNOPSIS
    curl.exe GET tests for the VS Monitoring health endpoint via the gateway.

    Gateway path: /vsmonitoring/api/health
    Upstream:     https://vsmonitoring.healthbc.org/api/health

.EXAMPLE
    .\Test-VSMonitoring-Curl.ps1

.EXAMPLE
    .\Test-VSMonitoring-Curl.ps1 -BaseUrl https://10.53.19.120:8088 -CurlArgs '--ssl-no-revoke'
#>
[CmdletBinding()]
param(
    [string]$BaseUrl = 'http://10.53.19.120:8081',
    [string[]]$CurlArgs = @()
)

$ErrorActionPreference = 'Stop'
$BaseUrl = $BaseUrl.TrimEnd('/')
$script:Passed = 0
$script:Failed = 0

function Test-Vs {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Path,
        [int]$ExpectStatus = 200,
        [string]$ExpectBody,
        [string]$ExpectHeader,
        [string[]]$Extra = @()
    )
    $bodyTmp = [IO.Path]::GetTempFileName()
    $headTmp = [IO.Path]::GetTempFileName()
    try {
        $a = @('-sS', '-D', $headTmp, '-o', $bodyTmp, '-w', '%{http_code}', '--max-time', '30') +
             $CurlArgs + $Extra + ("$BaseUrl$Path")
        $code = ((& curl.exe @a) | Out-String).Trim()
        $body = Get-Content -LiteralPath $bodyTmp -Raw -ErrorAction SilentlyContinue
        $heads = Get-Content -LiteralPath $headTmp -Raw -ErrorAction SilentlyContinue

        $okStatus = ([int]$code) -eq $ExpectStatus
        $okBody = if ($ExpectBody) { $body -like "*$ExpectBody*" } else { $true }
        $okHead = if ($ExpectHeader) { $heads -like "*$ExpectHeader*" } else { $true }

        if ($okStatus -and $okBody -and $okHead) {
            Write-Host ("  PASS  {0}" -f $Name) -ForegroundColor Green
            $script:Passed++
        } else {
            Write-Host ("  FAIL  {0} (status {1}, expected {2})" -f $Name, $code, $ExpectStatus) -ForegroundColor Red
            if (-not $okBody) { Write-Host ("        body missing: {0}" -f $ExpectBody) -ForegroundColor DarkGray }
            if (-not $okHead) { Write-Host ("        header missing: {0}" -f $ExpectHeader) -ForegroundColor DarkGray }
            $script:Failed++
        }
    } catch {
        Write-Host ("  FAIL  {0} - {1}" -f $Name, $_.Exception.Message) -ForegroundColor Red
        $script:Failed++
    } finally {
        Remove-Item -LiteralPath $bodyTmp, $headTmp -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "VS Monitoring health tests via: $BaseUrl" -ForegroundColor Cyan
Write-Host ('-' * 68) -ForegroundColor DarkGray

# --- Health endpoint ------------------------------------------------------
Test-Vs 'Health endpoint returns 200'           '/vsmonitoring/api/health' 200
Test-Vs 'Health JSON: database ok'               '/vsmonitoring/api/health' 200 '"database": "ok"'
Test-Vs 'Health JSON: version present'           '/vsmonitoring/api/health' 200 '"version"'
Test-Vs 'Health JSON: commit present'            '/vsmonitoring/api/health' 200 '"commit"'
Test-Vs 'Content-Type is JSON'                   '/vsmonitoring/api/health' 200 $null 'Content-Type: application/json'
Test-Vs 'Cache-Control header passes through'    '/vsmonitoring/api/health' 200 $null 'Cache-Control: no-store'
Test-Vs 'Query string tolerated'                 '/vsmonitoring/api/health?probe=1' 200 '"database": "ok"'

# --- Upstream edge behaviors ---------------------------------------------
Test-Vs 'Trailing slash rejected by upstream'    '/vsmonitoring/api/health/' 401
Test-Vs 'Unknown path redirects to login'        '/vsmonitoring/nope' 302
Test-Vs 'Relative Location kept in gateway'      '/vsmonitoring/nope' 302 $null 'Location: /vsmonitoring/login'

# --- Timing ---------------------------------------------------------------
$tmp = [IO.Path]::GetTempFileName()
try {
    $a = @('-sS', '-o', $tmp, '-w', '%{http_code} %{time_total}', '--max-time', '30') +
         $CurlArgs + ("$BaseUrl/vsmonitoring/api/health")
    $out = ((& curl.exe @a) | Out-String).Trim()
    $parts = $out -split '\s+'
    $sec = [double]::Parse($parts[1], [Globalization.CultureInfo]::InvariantCulture)
    if (([int]$parts[0] -eq 200) -and ($sec -lt 5)) {
        Write-Host ("  PASS  Health response time ({0:N2}s)" -f $sec) -ForegroundColor Green
        $script:Passed++
    } else {
        Write-Host ("  FAIL  Health response time (status {0}, {1}s)" -f $parts[0], $parts[1]) -ForegroundColor Red
        $script:Failed++
    }
} catch {
    Write-Host ("  FAIL  Health response time - {0}" -f $_.Exception.Message) -ForegroundColor Red
    $script:Failed++
} finally {
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
}

Write-Host ('-' * 68) -ForegroundColor DarkGray
$color = if ($script:Failed -gt 0) { 'Yellow' } else { 'Green' }
Write-Host ("Result: {0} passed, {1} failed" -f $script:Passed, $script:Failed) -ForegroundColor $color
if ($script:Failed -gt 0) { exit 1 }
