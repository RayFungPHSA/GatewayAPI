<#
.SYNOPSIS
    Remove a user from the Cohesity MCP gateway ACL.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Name,
    [string]$AclFile
)

$ErrorActionPreference = 'Stop'

$BridgeDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $AclFile) {
    $RootDir = Split-Path -Parent $BridgeDir
    $AclFile = Join-Path $RootDir 'secrets\cohesity-gateway-acl.json'
}

if (-not (Test-Path -LiteralPath $AclFile)) {
    throw "ACL file not found: $AclFile"
}

$acl = Get-Content -LiteralPath $AclFile -Raw | ConvertFrom-Json
$users = @($acl.users | Where-Object { $_.name -ine $Name })
if ($users.Count -eq @($acl.users).Count) {
    throw "No ACL entry found for '$Name'."
}

$out = [pscustomobject]@{
    version = 1
    users   = @($users)
}
$json = $out | ConvertTo-Json -Depth 6
$utf8NoBom = New-Object Text.UTF8Encoding($false)
[IO.File]::WriteAllText($AclFile, $json + "`n", $utf8NoBom)

Write-Host "Removed '$Name' from $AclFile"
Write-Host 'The bridge picks up ACL changes on the next request; no restart is required.'
