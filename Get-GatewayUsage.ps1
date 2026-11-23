<#
.SYNOPSIS
    Summarize Caddy access logs: request volume by client IP and path.

    This shows source IPs, not authenticated users. The general gateway routes
    (/todos, /httpbin, /vsmonitoring) have no login, so IP is the only identity.
    API-key headers are hashed in the log and are never printed by this script.

.EXAMPLE
    .\Get-GatewayUsage.ps1

.EXAMPLE
    .\Get-GatewayUsage.ps1 -SinceHours 168 -Top 50
#>
[CmdletBinding()]
param(
    [string]$LogPath = 'C:\caddy-gateway\logs\access.log',
    [int]$SinceHours = 24,
    [int]$Top = 20
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $LogPath)) {
    Write-Host 'No Caddy access log found yet.'
    return
}

$cutoff = (Get-Date).ToUniversalTime().AddHours(-$SinceHours)
$entries = @(
    Get-Content -LiteralPath $LogPath -ErrorAction SilentlyContinue |
        ForEach-Object {
            try { $_ | ConvertFrom-Json } catch { }
        } |
        Where-Object {
            $_.ts -and $_.request -and
            ([DateTimeOffset]::FromUnixTimeSeconds([math]::Floor([double]$_.ts)).UtcDateTime -ge $cutoff)
        }
)

Write-Host "Caddy gateway access summary (last $SinceHours hours)"
Write-Host "Log: $LogPath"
Write-Host "Entries parsed: $($entries.Count)"
Write-Host

if ($entries.Count -eq 0) {
    Write-Host 'No requests in this time window.'
    return
}

function Get-Time([double]$unix) {
    [DateTimeOffset]::FromUnixTimeSeconds([math]::Floor($unix)).UtcDateTime.ToString('yyyy-MM-dd HH:mm')
}

$byIp = $entries |
    Group-Object { $_.request.client_ip } |
    ForEach-Object {
        $items = @($_.Group)
        [pscustomobject]@{
            ClientIP      = $_.Name
            Requests      = $items.Count
            Paths         = @($items | ForEach-Object { $_.request.uri } | Select-Object -Unique).Count
            Status2xx     = @($items | Where-Object { $_.status -ge 200 -and $_.status -lt 300 }).Count
            Status4xx     = @($items | Where-Object { $_.status -ge 400 -and $_.status -lt 500 }).Count
            Status5xx     = @($items | Where-Object { $_.status -ge 500 }).Count
            FirstSeenUtc  = Get-Time (($items.ts | Measure-Object -Minimum).Minimum)
            LastSeenUtc   = Get-Time (($items.ts | Measure-Object -Maximum).Maximum)
        }
    } |
    Sort-Object Requests -Descending |
    Select-Object -First $Top

Write-Host 'By client IP:'
$byIp | Format-Table -AutoSize | Out-Host

$byPath = $entries |
    Group-Object { ($_.request.uri -split '\?')[0] } |
    ForEach-Object {
        [pscustomobject]@{
            Path     = $_.Name
            Requests = $_.Count
            Clients  = @($_.Group | ForEach-Object { $_.request.client_ip } | Select-Object -Unique).Count
        }
    } |
    Sort-Object Requests -Descending |
    Select-Object -First $Top

Write-Host 'By path:'
$byPath | Format-Table -AutoSize | Out-Host

Write-Host 'Distinct client IPs:' (@($entries | ForEach-Object { $_.request.client_ip } | Select-Object -Unique).Count)
