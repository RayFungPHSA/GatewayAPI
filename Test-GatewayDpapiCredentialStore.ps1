<#
.SYNOPSIS
    Verify that all gateway MCPs use DPAPI-protected credential records.

.DESCRIPTION
    Checks that protected records and restricted helpers exist, that each helper
    returns the required fields without displaying values, that the bridges
    report credential_store=dpapi, and that legacy plain-text env files are gone.
    No secret values are printed or written.
#>
[CmdletBinding()]
param(
    [string]$RootDir = 'C:\caddy-gateway'
)

$ErrorActionPreference = 'Stop'
$script:Passed = 0
$script:Failed = 0

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

Write-Host 'Gateway DPAPI credential store test'
Write-Host ''

$specs = @(
    @{
        Name = 'Cohesity'
        Xml = 'secrets\cohesity-gateway.xml'
        Helper = 'cohesity-mcp\scripts\Get-CohesityGatewayCredential.ps1'
        Required = @('COHESITY_API_KEY')
        Port = 8400
    }
    @{
        Name = 'HPEGreenLake'
        Xml = 'secrets\hpegreenlake-gateway.xml'
        Helper = 'hpegreenlake-mcp\scripts\Get-HPEGreenLakeGatewayCredential.ps1'
        Required = @('AUTH_URL', 'CLIENT_ID', 'CLIENT_SECRET')
        Port = 8401
    }
    @{
        Name = 'Lansweeper'
        Xml = 'secrets\lansweeper-gateway.xml'
        Helper = 'lansweeper-mcp\scripts\Get-LansweeperGatewayCredential.ps1'
        Required = @('LANSWEEPER_URL', 'LANSWEEPER_USERNAME', 'LANSWEEPER_PASSWORD')
        Port = 8402
    }
    @{
        Name = 'vSphere'
        Xml = 'secrets\vsphere.xml'
        Helper = 'vsphere-mcp\scripts\Get-VsphereGatewayCredential.ps1'
        Required = @()
        Port = 8403
    }
)

foreach ($spec in $specs) {
    $xmlPath = Join-Path $RootDir $spec.Xml
    $helperPath = Join-Path $RootDir $spec.Helper
    Assert-Test "$($spec.Name): protected record exists" (Test-Path -LiteralPath $xmlPath)
    Assert-Test "$($spec.Name): restricted helper exists" (Test-Path -LiteralPath $helperPath)

    if ((Test-Path -LiteralPath $helperPath) -and $spec.Required.Count -gt 0) {
        try {
            $raw = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $helperPath 2>&1
            $helperExit = $LASTEXITCODE
            if ($helperExit -eq 0) {
                $data = $raw | ConvertFrom-Json
                $names = @($data.PSObject.Properties.Name)
                $missing = @($spec.Required | Where-Object {
                    $names -notcontains $_ -or [string]::IsNullOrWhiteSpace([string]$data.$_)
                })
                Assert-Test "$($spec.Name): helper returns required fields" ($missing.Count -eq 0)
            } else {
                Assert-Test "$($spec.Name): helper returns required fields" $false 'helper failed'
            }
        } catch {
            Assert-Test "$($spec.Name): helper returns required fields" $false 'helper output invalid'
        }
    }

    try {
        $health = Invoke-RestMethod -Uri "http://127.0.0.1:$($spec.Port)/health" -TimeoutSec 5
        Assert-Test "$($spec.Name): bridge reports DPAPI store" ($health.credential_store -eq 'dpapi')
    } catch {
        Assert-Test "$($spec.Name): bridge reports DPAPI store" $false 'health request failed'
    }
}

foreach ($name in @('cohesity-gateway.env', 'hpegreenlake-gateway.env', 'lansweeper-gateway.env')) {
    $legacy = Join-Path $RootDir "secrets\$name"
    Assert-Test "Legacy plaintext file absent: $name" (-not (Test-Path -LiteralPath $legacy))
}

$aclPath = Join-Path $RootDir 'secrets\cohesity-gateway-acl.json'
try {
    $acl = Get-Content -LiteralPath $aclPath -Raw | ConvertFrom-Json
    $users = @($acl.users)
    $admins = @($users | Where-Object { $_.role -eq 'admin' } | ForEach-Object { $_.name })
    Assert-Test 'Shared ACL has 15 named users' ($users.Count -eq 15) "count=$($users.Count)"
    Assert-Test 'Only ray.fung@phsa.ca is admin' ($admins.Count -eq 1 -and $admins[0] -eq 'ray.fung@phsa.ca')
} catch {
    Assert-Test 'Shared ACL state is valid' $false 'ACL could not be read'
}

Write-Host ''
Write-Host "Result: $script:Passed passed, $script:Failed failed"
if ($script:Failed -gt 0) { exit 1 }
