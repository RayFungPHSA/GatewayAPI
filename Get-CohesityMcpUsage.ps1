<#
.SYNOPSIS
    Summarize Cohesity MCP usage: authenticated users, tokens, and tools.

    Users are identified by the gateway token ACL, not by a self-declared
    header. Neither raw tokens nor the shared Cohesity API key are logged;
    only short SHA-256 fingerprints appear.

.EXAMPLE
    .\Get-CohesityMcpUsage.ps1

.EXAMPLE
    .\Get-CohesityMcpUsage.ps1 -SinceHours 168 -Top 50
#>
[CmdletBinding()]
param(
    [string]$LogPath = 'C:\caddy-gateway\cohesity-mcp\usage.jsonl',
    [string]$ServerName = 'Cohesity MCP',
    [int]$SinceHours = 24,
    [int]$Top = 20
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $LogPath)) {
    Write-Host 'No Cohesity MCP usage log found yet.'
    return
}

$cutoff = (Get-Date).ToUniversalTime().AddHours(-$SinceHours)
$entries = @(
    Get-Content -LiteralPath $LogPath -ErrorAction SilentlyContinue |
        ForEach-Object {
            try { $_ | ConvertFrom-Json } catch { }
        } |
        Where-Object {
            $_.ts -and ([datetimeoffset]::Parse($_.ts).UtcDateTime -ge $cutoff)
        }
)

Write-Host "$ServerName usage summary (last $SinceHours hours)"
Write-Host "Log: $LogPath"
Write-Host "Events parsed: $($entries.Count)"
Write-Host

if ($entries.Count -eq 0) {
    Write-Host 'No MCP activity in this time window.'
    return
}

$calls = @($entries | Where-Object { $_.event -eq 'tools/call' })
$denied = @($entries | Where-Object { $_.event -in @('auth_denied', 'auth_rejected') })

$byUser = $entries |
    Group-Object user |
    ForEach-Object {
        $items = @($_.Group)
        [pscustomobject]@{
            User         = $_.Name
            Role         = @($items | ForEach-Object { $_.role } | Where-Object { $_ -and $_ -ne 'none' } | Select-Object -Unique) -join ','
            TokenFp      = @($items | ForEach-Object { $_.token_fp } | Where-Object { $_ } | Select-Object -Unique) -join ','
            Events       = $items.Count
            ToolCalls    = @($items | Where-Object { $_.event -eq 'tools/call' }).Count
            Failed       = @($items | Where-Object { $_.ok -eq $false }).Count
            Clients      = @($items | ForEach-Object { $_.client_ip } | Select-Object -Unique).Count
            FirstSeenUtc = ($items | Sort-Object ts | Select-Object -First 1).ts
            LastSeenUtc  = ($items | Sort-Object ts | Select-Object -Last 1).ts
        }
    } |
    Sort-Object Events -Descending |
    Select-Object -First $Top

Write-Host 'By authenticated user:'
$byUser | Format-Table -AutoSize | Out-Host

$byTool = $calls |
    Group-Object tool |
    ForEach-Object {
        [pscustomobject]@{
            Tool     = $_.Name
            Calls    = $_.Count
            Users    = @($_.Group | ForEach-Object { $_.user } | Select-Object -Unique).Count
            Failures = @($_.Group | Where-Object { $_.ok -eq $false }).Count
        }
    } |
    Sort-Object Calls -Descending |
    Select-Object -First $Top

Write-Host 'By tool:'
$byTool | Format-Table -AutoSize | Out-Host

if ($denied.Count -gt 0) {
    Write-Host 'Authentication denials:'
    $denied |
        Group-Object reason |
        ForEach-Object {
            [pscustomobject]@{
                Reason = $_.Name
                Count  = $_.Count
                IPs    = @($_.Group | ForEach-Object { $_.client_ip } | Select-Object -Unique).Count
            }
        } |
        Sort-Object Count -Descending |
        Format-Table -AutoSize | Out-Host
}

Write-Host ("Distinct authenticated users: {0}" -f @($entries | ForEach-Object { $_.user } | Where-Object { $_ -ne 'unauthenticated' } | Select-Object -Unique).Count)
Write-Host ("Distinct token hashes:       {0}" -f @($entries | ForEach-Object { $_.token_fp } | Where-Object { $_ } | Select-Object -Unique).Count)
Write-Host ("Shared key hash:             {0}" -f @($entries | ForEach-Object { $_.key_fp } | Where-Object { $_ -and $_ -ne 'none' } | Select-Object -First 1))
Write-Host ("Auth denials:                {0}" -f $denied.Count)
Write-Host ("Total tool calls:            {0}" -f $calls.Count)
