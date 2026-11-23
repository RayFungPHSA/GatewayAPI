<#
.SYNOPSIS
    Summarize HPEGreenLake MCP usage using the shared MCP report script.

.EXAMPLE
    .\Get-HPEGreenLakeMcpUsage.ps1

.EXAMPLE
    .\Get-HPEGreenLakeMcpUsage.ps1 -SinceHours 168 -Top 50
#>
[CmdletBinding()]
param(
    [int]$SinceHours = 24,
    [int]$Top = 20
)

$ErrorActionPreference = 'Stop'
$RootDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Report = Join-Path $RootDir 'Get-CohesityMcpUsage.ps1'
$LogPath = Join-Path $RootDir 'hpegreenlake-mcp\usage.jsonl'

& $Report -LogPath $LogPath -ServerName 'HPEGreenLake MCP' -SinceHours $SinceHours -Top $Top
