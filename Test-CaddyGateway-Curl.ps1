<#
.SYNOPSIS
    Extra curl.exe GET tests for the Caddy API gateway.

.EXAMPLE
    .\Test-CaddyGateway-Curl.ps1

.EXAMPLE
    .\Test-CaddyGateway-Curl.ps1 -BaseUrl https://10.53.19.120:8088 -CurlArgs '--ssl-no-revoke'
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

function Test-Curl {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Path,
        [string]$ExpectBody,
        [int]$ExpectStatus = 200,
        [string[]]$Extra = @()
    )
    $tmp = [IO.Path]::GetTempFileName()
    try {
        $a = @('-sS', '-o', $tmp, '-w', '%{http_code}', '--max-time', '30') +
             $CurlArgs + $Extra + ("$BaseUrl$Path")
        $code = ((& curl.exe @a) | Out-String).Trim()
        $body = Get-Content -LiteralPath $tmp -Raw -ErrorAction SilentlyContinue
        $statusOk = ([int]$code) -eq $ExpectStatus
        $bodyOk = if ($ExpectBody) { $body -like "*$ExpectBody*" } else { $true }
        if ($statusOk -and $bodyOk) {
            Write-Host ("  PASS  {0}" -f $Name) -ForegroundColor Green
            $script:Passed++
        } else {
            Write-Host ("  FAIL  {0} (status {1}, expected {2})" -f $Name, $code, $ExpectStatus) -ForegroundColor Red
            if (-not $bodyOk) { Write-Host ("        body did not contain: {0}" -f $ExpectBody) -ForegroundColor DarkGray }
            $script:Failed++
        }
    } catch {
        Write-Host ("  FAIL  {0} - {1}" -f $Name, $_.Exception.Message) -ForegroundColor Red
        $script:Failed++
    } finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "curl.exe GET tests against: $BaseUrl" -ForegroundColor Cyan
Write-Host ('-' * 68) -ForegroundColor DarkGray

# --- Gateway / catch-all --------------------------------------------------
Test-Curl 'Catch-all response'                  '/'                          'Caddy gateway is running'
Test-Curl 'Catch-all with query string'         '/anything?x=1'              'Caddy gateway is running'

# --- todos route ----------------------------------------------------------
Test-Curl 'todos/1 known item'                  '/todos/1'                   'delectus aut autem'
Test-Curl 'todos/3 another item'                '/todos/3'                   '"id": 3'
Test-Curl 'todos/5 another item'                '/todos/5'                   '"id": 5'
Test-Curl 'todos with query string'             '/todos/1?ignored=yes'       '"id": 1'

# --- httpbin route / prefix stripping -------------------------------------
Test-Curl 'httpbin /get'                        '/httpbin/get'               'httpbin.org:443/get'
Test-Curl 'httpbin /get with args'              '/httpbin/get?foo=bar&n=2'   '"foo": "bar"'
Test-Curl 'httpbin /headers'                    '/httpbin/headers'           'X-Forwarded-Host'
Test-Curl 'httpbin upstream Host header'        '/httpbin/headers'           'httpbin.org:443'
Test-Curl 'httpbin /ip'                         '/httpbin/ip'                '"origin"'
Test-Curl 'httpbin /user-agent'                 '/httpbin/user-agent'        'curl/'
Test-Curl 'httpbin /uuid'                       '/httpbin/uuid'              '"uuid"'
Test-Curl 'httpbin nested path'                 '/httpbin/anything/a/b/c'    '/anything/a/b/c'
Test-Curl 'httpbin trailing slash (upstream 404)' '/httpbin/get/'            '' 404

# --- Status passthrough ---------------------------------------------------
Test-Curl 'httpbin status 200'                  '/httpbin/status/200'        '' 200
Test-Curl 'httpbin status 404'                  '/httpbin/status/404'        '' 404
Test-Curl 'httpbin status 500'                  '/httpbin/status/500'        '' 500

# --- Redirects ------------------------------------------------------------
Test-Curl 'httpbin redirect without -L'         '/httpbin/redirect/2'        '' 302
Test-Curl 'httpbin redirect with -L'            '/httpbin/redirect/2'        'httpbin.org:443/get' 200 @('-L')

# --- Response headers -----------------------------------------------------
Test-Curl 'Response headers include JSON type'  '/httpbin/get'               'Content-Type: application/json' 200 @('-i')
Test-Curl 'Custom response header forwarded'    '/httpbin/response-headers?Foo=bar' 'Foo: bar' 200 @('-i')

# --- Binary payload -------------------------------------------------------
Test-Curl 'httpbin 128 random bytes'            '/httpbin/bytes/128'         '' 200

# --- Delay / timing -------------------------------------------------------
$tmp = [IO.Path]::GetTempFileName()
try {
    $a = @('-sS', '-o', $tmp, '-w', '%{http_code} %{time_total}', '--max-time', '30') +
         $CurlArgs + ("$BaseUrl/httpbin/delay/1")
    $out = ((& curl.exe @a) | Out-String).Trim()
    $parts = $out -split '\s+'
    $delaySec = [double]::Parse($parts[1], [Globalization.CultureInfo]::InvariantCulture)
    if (([int]$parts[0] -eq 200) -and ($delaySec -ge 1)) {
        Write-Host ("  PASS  httpbin delay/1 ({0:N2}s)" -f $delaySec) -ForegroundColor Green
        $script:Passed++
    } else {
        Write-Host ("  FAIL  httpbin delay/1 (status {0}, {1}s)" -f $parts[0], $parts[1]) -ForegroundColor Red
        $script:Failed++
    }
} catch {
    Write-Host ("  FAIL  httpbin delay/1 - {0}" -f $_.Exception.Message) -ForegroundColor Red
    $script:Failed++
} finally {
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
}

Write-Host ('-' * 68) -ForegroundColor DarkGray
$color = if ($script:Failed -gt 0) { 'Yellow' } else { 'Green' }
Write-Host ("Result: {0} passed, {1} failed" -f $script:Passed, $script:Failed) -ForegroundColor $color
if ($script:Failed -gt 0) { exit 1 }
