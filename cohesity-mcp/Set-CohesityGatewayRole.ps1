<#
.SYNOPSIS
    Change an existing gateway user's role without rotating their token.

.EXAMPLE
    .\Set-CohesityGatewayRole.ps1 -Name 'ray.fung@phsa.ca' -Role admin
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][ValidateSet('admin', 'read-only')][string]$Role
)

$ErrorActionPreference = 'Stop'

$BridgeDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = Split-Path -Parent $BridgeDir
$AclFile = Join-Path $RootDir 'secrets\cohesity-gateway-acl.json'

if (-not (Test-Path -LiteralPath $AclFile)) {
    throw "ACL file not found: $AclFile"
}

$acl = Get-Content -LiteralPath $AclFile -Raw | ConvertFrom-Json
$users = @($acl.users)
$target = @($users | Where-Object { $_.name -ieq $Name })
if ($target.Count -eq 0) {
    throw "No ACL entry found for '$Name'."
}
if ($target.Count -gt 1) {
    throw "Multiple ACL entries match '$Name'. Fix the ACL file before changing roles."
}

$target[0].role = $Role

$out = [pscustomobject]@{
    version = 1
    users   = @($users)
}
$json = $out | ConvertTo-Json -Depth 6
$utf8NoBom = New-Object Text.UTF8Encoding($false)
[IO.File]::WriteAllText($AclFile, $json + "`n", $utf8NoBom)

Write-Host "Set role for '$($target[0].name)' to '$Role'."
Write-Host 'The bridge picks up ACL changes on the next request; no restart is required.'
