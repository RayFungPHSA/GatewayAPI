<#
.SYNOPSIS
    Summarize Lansweeper MCP usage using the shared MCP report script.

.EXAMPLE
    .\Get-LansweeperMcpUsage.ps1

.EXAMPLE
    .\Get-LansweeperMcpUsage.ps1 -SinceHours 168 -Top 50
#>
[CmdletBinding()]
param(
    [int]$SinceHours = 24,
    [int]$Top = 20
)

$ErrorActionPreference = 'Stop'
$RootDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Report = Join-Path $RootDir 'Get-CohesityMcpUsage.ps1'
$LogPath = Join-Path $RootDir 'lansweeper-mcp\usage.jsonl'

& $Report -LogPath $LogPath -ServerName 'Lansweeper MCP' -SinceHours $SinceHours -Top $Top
