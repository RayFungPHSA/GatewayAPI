<#
.SYNOPSIS
    List Cohesity MCP gateway ACL entries. Token fingerprints are safe to show;
    raw tokens are never stored or displayed.
#>
[CmdletBinding()]
param(
    [string]$AclFile
)

$ErrorActionPreference = 'Stop'

$BridgeDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $AclFile) {
    $RootDir = Split-Path -Parent $BridgeDir
    $AclFile = Join-Path $RootDir 'secrets\cohesity-gateway-acl.json'
}

if (-not (Test-Path -LiteralPath $AclFile)) {
    Write-Host "No ACL file found: $AclFile"
    return
}

$acl = Get-Content -LiteralPath $AclFile -Raw | ConvertFrom-Json
$rows = @($acl.users | ForEach-Object {
    [pscustomobject]@{
        Name        = $_.name
        Role        = if ($_.role) { $_.role } else { 'read-only' }
        TokenFp     = if ($_.token_fp) { $_.token_fp.Substring(0, [Math]::Min(12, $_.token_fp.Length)) } else { '' }
        CreatedUtc  = $_.created_utc
    }
})

Write-Host "Cohesity MCP gateway ACL: $AclFile"
$rows | Sort-Object Name | Format-Table -AutoSize | Out-Host
Write-Host "Allowed users: $($rows.Count)"
