<#
.SYNOPSIS
    Runs the gateway test suite with dedicated automation identities.

.DESCRIPTION
    Reads the admin token for ray.fung@phsa.ca and the read-only test token for
    gateway-test@phsa.ca from the restricted distribution file. It verifies each
    token fingerprint against the live ACL, then runs the tests with canonical
    environment variables. Token values are never echoed.

.EXAMPLE
    .\Run-GatewayTests.ps1

.EXAMPLE
    .\Run-GatewayTests.ps1 -Tests Test-McpDiscovery.ps1,Test-CohesityMcpGuardrails.ps1
#>
[CmdletBinding()]
param(
    [string[]]$Tests = @(
        'Test-CaddyGateway.ps1',
        'Test-CaddyGateway-Curl.ps1',
        'Test-GatewayDpapiCredentialStore.ps1',
        'Test-McpDiscovery.ps1',
        'Test-CohesityMcp.ps1',
        'Test-CohesityMcp-Curl.ps1',
        'Test-CohesityMcpGuardrails.ps1',
        'Test-HPEGreenLakeMcp.ps1',
        'Test-HPEGreenLakeMcp-Curl.ps1',
        'Test-HPEGreenLakeMcpGuardrails.ps1',
        'Test-LansweeperMcp.ps1',
        'Test-LansweeperMcp-Curl.ps1',
        'Test-LansweeperMcpGuardrails.ps1',
        'Test-VsphereMcp.ps1',
        'Test-VsphereMcp-Curl.ps1',
        'Test-VsphereMcpGuardrails.ps1',
        'Test-3PARLegacyMcp.ps1',
        'Test-3PARLegacyMcpGuardrails.ps1',
        'Test-HPEXP8Mcp.ps1',
        'Test-HPEXP8McpGuardrails.ps1',
        'Test-BrocadeMcp.ps1',
        'Test-BrocadeMcpGuardrails.ps1'
    )
)

$ErrorActionPreference = 'Stop'

$RootDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$AclFile = Join-Path $RootDir 'secrets\cohesity-gateway-acl.json'
$DistFile = Join-Path $RootDir 'secrets\gateway-tokens-to-distribute.txt'

$acl = Get-Content -LiteralPath $AclFile -Raw | ConvertFrom-Json

$rows = @()
foreach ($line in (Get-Content -LiteralPath $DistFile)) {
    if (-not $line.Contains("`t")) { continue }
    $parts = $line -split "`t"
    if ($parts.Count -ge 3) {
        $rows += [pscustomobject]@{
            Name = $parts[0]
            Role = $parts[1]
            Token = $parts[2]
        }
    }
}

function Get-TokenForUser {
    param([Parameter(Mandatory)][string]$Name)

    $row = @($rows | Where-Object { $_.Name -ieq $Name } | Select-Object -First 1)
    if ($row.Count -eq 0) { throw "No distribution row for '$Name'." }

    $entry = @($acl.users | Where-Object { $_.name -ieq $Name } | Select-Object -First 1)
    if ($entry.Count -eq 0) { throw "No ACL entry for '$Name'." }

    $hashBytes = [Security.Cryptography.SHA256]::Create().ComputeHash(
        [Text.Encoding]::UTF8.GetBytes($row[0].Token))
    $fingerprint = ([BitConverter]::ToString($hashBytes).Replace('-', '')).ToLowerInvariant()
    if ($fingerprint -ine $entry[0].token_fp) {
        throw "Distribution token does not match the ACL fingerprint for '$Name'."
    }

    return $row[0].Token
}

$adminToken = Get-TokenForUser -Name 'ray.fung@phsa.ca'
$testToken = Get-TokenForUser -Name 'gateway-test@phsa.ca'

Remove-Item Env:COHESITY_GATEWAY_TOKEN, Env:COHESITY_GATEWAY_ADMIN_TOKEN, `
    Env:COHESITY_GATEWAY_READONLY_TOKEN -ErrorAction SilentlyContinue

$env:CADDY_GATEWAY_TOKEN = $adminToken
$env:CADDY_GATEWAY_ADMIN_TOKEN = $adminToken
$env:CADDY_GATEWAY_READONLY_TOKEN = $testToken
$env:CADDY_GATEWAY_TEST_TOKEN = $testToken

$failures = @()
foreach ($test in $Tests) {
    $path = Join-Path $RootDir $test
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        "FAIL: Test file not found: $test"
        $failures += $test
        continue
    }

    $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $path 2>&1
    $code = $LASTEXITCODE
    $result = $output | Select-String -Pattern 'Result:' | Select-Object -Last 1
    Write-Host "RUN $test (exit=$code) $result"

    $bad = @($output | Select-String -Pattern '^\s+FAIL|Exception|Error:' | Select-Object -First 3)
    $bad | ForEach-Object { Write-Host "  $_" }
    if ($code -ne 0 -or $bad.Count -gt 0) { $failures += $test }
}

if ($failures.Count -gt 0) {
    throw "Failures: $($failures -join ', ')"
}

"ALL $($Tests.Count) TEST FILES PASSED"
