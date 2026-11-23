<#
.SYNOPSIS
    Issue a per-user gateway token for Cohesity MCP and store only its fingerprint.

.EXAMPLE
    .\New-CohesityGatewayToken.ps1 -Name 'alice@example.com'

.EXAMPLE
    .\New-CohesityGatewayToken.ps1 -Name 'bob@example.com' -Force

.EXAMPLE
    .\New-CohesityGatewayToken.ps1 -Name 'ray.fung@phsa.ca' -Role admin
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Name,
    [ValidateSet('admin', 'read-only')][string]$Role = 'read-only',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$BridgeDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = Split-Path -Parent $BridgeDir
$SecretsDir = Join-Path $RootDir 'secrets'
$AclFile = Join-Path $SecretsDir 'cohesity-gateway-acl.json'

$Name = $Name.Trim()
if (-not $Name) { throw 'Name cannot be empty.' }

New-Item -ItemType Directory -Path $SecretsDir -Force | Out-Null

$users = @()
if (Test-Path -LiteralPath $AclFile) {
    $existing = Get-Content -LiteralPath $AclFile -Raw | ConvertFrom-Json
    $users = @($existing.users)
}

$duplicate = @($users | Where-Object { $_.name -ieq $Name })
if ($duplicate.Count -gt 0 -and -not $Force) {
    throw "A token already exists for '$Name'. Use -Force to rotate it or change the role."
}
if ($duplicate.Count -gt 0) {
    $users = @($users | Where-Object { $_.name -ine $Name })
}

$bytes = New-Object byte[] 32
[Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
$token = [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')

$sha = [Security.Cryptography.SHA256]::Create()
$hashBytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($token))
$fingerprint = ($hashBytes | ForEach-Object { $_.ToString('x2') }) -join ''

$users += [pscustomobject]@{
    name        = $Name
    role        = $Role
    token_fp    = $fingerprint
    created_utc = [datetime]::UtcNow.ToString('o')
}

$acl = [pscustomobject]@{
    version = 1
    users   = @($users)
}
$json = $acl | ConvertTo-Json -Depth 6
$utf8NoBom = New-Object Text.UTF8Encoding($false)
[IO.File]::WriteAllText($AclFile, $json + "`n", $utf8NoBom)

$aclHelper = Join-Path $BridgeDir 'Set-RestrictedSecretAcl.ps1'
& $aclHelper -Path $SecretsDir -Directory
& $aclHelper -Path $AclFile

Write-Output "Issued gateway token for: $Name [$Role]"
Write-Output "TOKEN (shown once): $token"
Write-Output 'Give this token only to that user. The bridge stores only its SHA-256 fingerprint.'
Write-Output "ACL file: $AclFile"
