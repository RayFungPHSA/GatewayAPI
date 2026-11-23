<#
.SYNOPSIS
    Shared DPAPI-backed credential store for the Caddy gateway MCP servers.

.DESCRIPTION
    Secrets are serialized to JSON, wrapped in a PSCredential, and written with
    Export-Clixml. Windows DPAPI protects the payload for the current Windows
    user. Callers must apply Set-RestrictedSecretAcl.ps1 to the resulting file.

    These functions never write secret values to console output. Errors are kept
    generic so a failed import cannot disclose the protected record.
#>

$ErrorActionPreference = 'Stop'

function ConvertTo-GatewayHashtable {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Object)

    $result = @{}
    foreach ($property in $Object.PSObject.Properties) {
        if ($null -ne $property.Value) {
            $result[$property.Name] = [string]$property.Value
        }
    }
    return $result
}

function New-GatewayDpapiRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][hashtable]$Config,
        [string]$Label = 'gateway-credential'
    )

    $json = $Config | ConvertTo-Json -Compress -Depth 10
    $secure = ConvertTo-SecureString -String $json -AsPlainText -Force
    $credential = New-Object PSCredential($Label, $secure)

    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $credential | Export-Clixml -LiteralPath $Path -Force
}

function Get-GatewayDpapiRecord {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw 'The protected credential record is not configured.'
    }

    try {
        $credential = Import-Clixml -LiteralPath $Path
        $json = [string]$credential.GetNetworkCredential().Password
        if ([string]::IsNullOrWhiteSpace($json)) {
            throw 'Empty record'
        }
        return ($json | ConvertFrom-Json)
    } catch {
        throw 'The protected credential record could not be loaded.'
    }
}

function Read-GatewaySecureString {
    [CmdletBinding()]
    param([Parameter(Mandatory)][SecureString]$SecureString)

    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringUni($pointer)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
    }
}

Export-ModuleMember -Function ConvertTo-GatewayHashtable, New-GatewayDpapiRecord, Get-GatewayDpapiRecord, Read-GatewaySecureString
