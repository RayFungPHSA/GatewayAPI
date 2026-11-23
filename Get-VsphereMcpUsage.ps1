<#
.SYNOPSIS
    Summarize vSphere MCP usage using the shared MCP report script.

.EXAMPLE
    .\Get-VsphereMcpUsage.ps1

.EXAMPLE
    .\Get-VsphereMcpUsage.ps1 -SinceHours 168 -Top 50
#>
[CmdletBinding()]
param(
    [int]$SinceHours = 24,
    [int]$Top = 20
)

$ErrorActionPreference = 'Stop'
$RootDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Report = Join-Path $RootDir 'Get-CohesityMcpUsage.ps1'
$LogPath = Join-Path $RootDir 'vsphere-mcp\usage.jsonl'

& $Report -LogPath $LogPath -ServerName 'vSphere MCP' -SinceHours $SinceHours -Top $Top
