<#
.SYNOPSIS
    Creates or removes the canonical gateway-token environment variable from
    the legacy Cohesity-named variable, without exposing the token value.

.DESCRIPTION
    The gateway token is shared by all MCP servers. Its canonical environment
    variable is CADDY_GATEWAY_TOKEN; COHESITY_GATEWAY_TOKEN remains accepted as
    a deprecated alias so clients can be migrated without reissuing tokens.

    By default this script copies the legacy value into the canonical User
    environment variable and the current process, but only when the canonical
    variable is not already set. It never prints, logs, or writes the token to
    a project file.

    Use -Revert to remove the canonical variable. The legacy variable is never
    changed, so rollback is immediate: point clients back at
    COHESITY_GATEWAY_TOKEN and restart them.

.EXAMPLE
    .\Set-GatewayTokenAlias.ps1

.EXAMPLE
    .\Set-GatewayTokenAlias.ps1 -ProcessOnly

.EXAMPLE
    .\Set-GatewayTokenAlias.ps1 -Revert
#>
[CmdletBinding()]
param(
    [switch]$ProcessOnly,
    [switch]$Revert
)

$ErrorActionPreference = 'Stop'

$canonicalName = 'CADDY_GATEWAY_TOKEN'
$legacyName = 'COHESITY_GATEWAY_TOKEN'

function Get-TokenValue {
    param([Parameter(Mandatory)][string]$Name)
    $processValue = [Environment]::GetEnvironmentVariable($Name, 'Process')
    if ($processValue) { return $processValue }
    return [Environment]::GetEnvironmentVariable($Name, 'User')
}

if ($Revert) {
    [Environment]::SetEnvironmentVariable($canonicalName, $null, 'Process')
    if (-not $ProcessOnly) {
        [Environment]::SetEnvironmentVariable($canonicalName, $null, 'User')
    }
    Write-Host "Removed $canonicalName from the current process$(
        if ($ProcessOnly) { '' } else { ' and the User environment' }
    )."
    Write-Host "The legacy variable $legacyName was not changed."
    return
}

$canonicalValue = Get-TokenValue -Name $canonicalName
if ($canonicalValue) {
    Write-Host "$canonicalName is already set; no change was made."
    Write-Host 'If you need to replace it, set it locally in your own shell.'
    return
}

$legacyValue = Get-TokenValue -Name $legacyName
if (-not $legacyValue) {
    throw "$legacyName is not set. Set your issued token locally before running this script."
}

[Environment]::SetEnvironmentVariable($canonicalName, $legacyValue, 'Process')
if (-not $ProcessOnly) {
    [Environment]::SetEnvironmentVariable($canonicalName, $legacyValue, 'User')
}

Write-Host "Set $canonicalName from the existing $legacyName value$(
    if ($ProcessOnly) { ' for this process only' } else { ' for new processes and this process' }
)."
Write-Host 'The token value was not displayed or written to a project file.'
Write-Host 'Restart MCP clients so they pick up the canonical variable name.'
