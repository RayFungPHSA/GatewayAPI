<#
.SYNOPSIS
    Configure or rotate the server-side Brocade SANnav credential.

.DESCRIPTION
    By default this imports the values from the old project's plaintext .env
    into the gateway's restricted secrets directory as a DPAPI-protected
    credential. The plaintext .env is NEVER copied into the gateway and its
    password is never displayed.

    Use -PromptPassword to rotate the password locally with masked input.

    The password is never accepted from chat, client configs, prompts, Caddy,
    or MCP request headers. Only the SANnav endpoint (host/port) is stored in
    a separate restricted JSON file.

    Run on the gateway host as the same Windows account that starts
    Start-BrocadeBridge.ps1. DPAPI records cannot be decrypted by another
    Windows account.
#>
[CmdletBinding()]
param(
    [string]$SourceEnvFile = 'C:\Code\CStorageDashboard\mcp-configs\Brocade\.env',
    [string]$HostName,
    [string]$Port = '443',
    [string]$Username,
    [switch]$PromptPassword
)

$ErrorActionPreference = 'Stop'

$BridgeDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = Split-Path -Parent $BridgeDir
$SecretsDir = Join-Path $RootDir 'secrets'
$CredentialFile = Join-Path $SecretsDir 'brocade.xml'
$ServerFile = Join-Path $SecretsDir 'brocade-servers.json'
$AclHelper = Join-Path $BridgeDir 'Set-RestrictedSecretAcl.ps1'

Write-Host 'Brocade SANnav MCP server-side credential setup' -ForegroundColor Cyan

$sourceValues = @{}
if (Test-Path -LiteralPath $SourceEnvFile) {
    foreach ($line in (Get-Content -LiteralPath $SourceEnvFile)) {
        if ($line -match '^\s*([A-Za-z0-9_]+)\s*=\s*(.*?)\s*$') {
            $key = $matches[1]
            $value = $matches[2].Trim().Trim('"').Trim("'")
            if ($value) { $sourceValues[$key] = $value }
        }
    }
    Write-Host 'Read endpoint and account values from the local source .env (password not displayed).'
} elseif (-not $PromptPassword) {
    Write-Warning "Source .env not found: $SourceEnvFile. Prompting for credentials instead."
}

if (-not $HostName) { $HostName = $sourceValues['SANNAV_HOST'] }
if (-not $Port) { $Port = $sourceValues['SANNAV_PORT'] }
if (-not $Port) { $Port = '443' }
if (-not $Username) { $Username = $sourceValues['SANNAV_USER'] }

if ([string]::IsNullOrWhiteSpace($HostName)) { throw 'A SANnav host is required.' }
if ([string]::IsNullOrWhiteSpace($Username)) { throw 'A SANnav username is required.' }

if ($PromptPassword -or -not $sourceValues.ContainsKey('SANNAV_PASS')) {
    Write-Host "Username: $Username"
    Write-Host 'The password is masked and protected with Windows DPAPI.' -ForegroundColor Yellow
    Write-Host 'Do not paste the password into chat or any client configuration.'
    $securePassword = Read-Host "Password for SANnav user '$Username'" -AsSecureString
    if ($securePassword.Length -eq 0) { throw 'A password is required.' }
    $credential = New-Object PSCredential($Username, $securePassword)
} else {
    # Convert the locally-read plaintext value into a SecureString in memory
    # only. It is written to disk solely as a DPAPI-encrypted CLIXML blob.
    $securePassword = ConvertTo-SecureString -String $sourceValues['SANNAV_PASS'] -AsPlainText -Force
    $credential = New-Object PSCredential($Username, $securePassword)
}

$server = [pscustomobject]@{
    name = $HostName
    host = $HostName
    port = [int]$Port
    url  = "https://${HostName}:$Port"
}

New-Item -ItemType Directory -Path $SecretsDir -Force | Out-Null

$credential | Export-Clixml -LiteralPath $CredentialFile -Force
ConvertTo-Json -InputObject $server -Depth 4 | Set-Content -LiteralPath $ServerFile -Encoding UTF8

& $AclHelper -Path $SecretsDir -Directory
& $AclHelper -Path $CredentialFile
& $AclHelper -Path $ServerFile

Write-Host ''
Write-Host "SANnav endpoint: $($server.url)"
Write-Host "Protected credential: $CredentialFile"
Write-Host "Restricted endpoint file: $ServerFile"
Write-Host 'Credential values were not displayed and no plaintext .env was created.'
Write-Host 'Restart the bridge with Stop-BrocadeBridge.ps1 and Start-BrocadeBridge.ps1.'
