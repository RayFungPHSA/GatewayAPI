<#
.SYNOPSIS
    Create the named Cohesity MCP ACL and issue one token per approved user.

.DESCRIPTION
    Ray Fung is the only admin. All other listed users are read-only and can
    use GET/read tools only. Tokens are written to a temporary restricted file
    for private distribution; only SHA-256 fingerprints go into the ACL.
#>
[CmdletBinding()]
param(
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$BridgeDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = Split-Path -Parent $BridgeDir
$SecretsDir = Join-Path $RootDir 'secrets'
$AclFile = Join-Path $SecretsDir 'cohesity-gateway-acl.json'
$DistFile = Join-Path $SecretsDir 'gateway-tokens-to-distribute.txt'
$NewTokenScript = Join-Path $BridgeDir 'New-CohesityGatewayToken.ps1'
$AclHelper = Join-Path $BridgeDir 'Set-RestrictedSecretAcl.ps1'

if ((Test-Path -LiteralPath $AclFile) -and -not $Force) {
    $existing = Get-Content -LiteralPath $AclFile -Raw | ConvertFrom-Json
    if (@($existing.users).Count -gt 0) {
        throw "$AclFile already has users. Use -Force to rotate every token."
    }
}

# Admin first. The regular-user list below intentionally omits the duplicate
# Ray.Fung@phsa.ca entry because it is the same person as the admin.
$users = @(
    [pscustomobject]@{ Name = 'ray.fung@phsa.ca';          Role = 'admin' }
    [pscustomobject]@{ Name = 'chris.chong@phsa.ca';       Role = 'read-only' }
    [pscustomobject]@{ Name = 'nes.gatus@phsa.ca';         Role = 'read-only' }
    [pscustomobject]@{ Name = 'eran.hershko@phsa.ca';      Role = 'read-only' }
    [pscustomobject]@{ Name = 'kulbir.multani@phsa.ca';    Role = 'read-only' }
    [pscustomobject]@{ Name = 'ali.nasiripour@phsa.ca';    Role = 'read-only' }
    [pscustomobject]@{ Name = 'chandra.neelakandan@phsa.ca'; Role = 'read-only' }
    [pscustomobject]@{ Name = 'manjot.singh1@phsa.ca';     Role = 'read-only' }
    [pscustomobject]@{ Name = 'chris.stewart@phsa.ca';     Role = 'read-only' }
    [pscustomobject]@{ Name = 'chun.su@phsa.ca';           Role = 'read-only' }
    [pscustomobject]@{ Name = 'philippe.tchape@phsa.ca';   Role = 'read-only' }
    [pscustomobject]@{ Name = 'dennis.xie@phsa.ca';        Role = 'read-only' }
    [pscustomobject]@{ Name = 'jim.xu@phsa.ca';            Role = 'read-only' }
    [pscustomobject]@{ Name = 'kai.yang@phsa.ca';          Role = 'read-only' }
)

New-Item -ItemType Directory -Path $SecretsDir -Force | Out-Null
& $AclHelper -Path $SecretsDir -Directory

$lines = @(
    'Cohesity MCP gateway tokens - distribute privately, then delete this file.',
    'Format: email <tab> role <tab> token',
    ''
)

foreach ($user in $users) {
    $output = & $NewTokenScript -Name $user.Name -Role $user.Role -Force 6>&1 | Out-String
    $match = [regex]::Match($output, 'TOKEN \(shown once\):\s*(\S+)')
    if (-not $match.Success) {
        throw "Could not read issued token for $($user.Name). Output: $output"
    }
    $lines += ("{0}`t{1}`t{2}" -f $user.Name, $user.Role, $match.Groups[1].Value)
}

$utf8NoBom = New-Object Text.UTF8Encoding($false)
[IO.File]::WriteAllLines($DistFile, $lines, $utf8NoBom)
& $AclHelper -Path $DistFile

Write-Host "Issued $($users.Count) gateway tokens (1 admin, $($users.Count - 1) read-only)."
Write-Host "Distribution file: $DistFile"
Write-Host 'Distribute each token privately and then delete the distribution file.'
