# Synthetic only. Never reads existing configuration or invokes a network client.
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$TestDirectory)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'GatewayStartupSettings.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'PnvsCredentials.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'PnvsRuntimeSettings.psm1') -Force
$target = [IO.Path]::GetFullPath($TestDirectory)
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..')).TrimEnd('\')
if ((Test-Path -LiteralPath $target) -or
    $target.StartsWith($repository, [StringComparison]::OrdinalIgnoreCase)) { throw 'New external test directory required.' }
[IO.Directory]::CreateDirectory($target) | Out-Null
& (Join-Path $PSScriptRoot 'prepare_remote_result_cache.ps1') -ResultDirectory (Join-Path (Split-Path -Parent $target) 'ai-results') -ServiceSid ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value) | Out-Null
$key = 'SYNTHETIC_MODEL_KEY_NO_NETWORK_20261013'
$dsn = 'mysql://synthetic_business:synthetic_password@localhost:18029/synthetic_accounts'
$id = ConvertTo-SecureString 'SYNTHETIC_PNVS_ID_ONLY_20261013' -AsPlainText -Force
$secret = ConvertTo-SecureString 'SYNTHETIC_PNVS_SECRET_ONLY_20261013' -AsPlainText -Force
$payload = $null
try {
    $credentials = Join-Path $target 'pnvs.dpapi'
    $runtime = Join-Path $target 'runtime.dpapi'
    Save-PnvsCredentials -Path $credentials -AccessKeyId $id -AccessKeySecret $secret
    Save-PnvsRuntimeSettings -Path $runtime -AllowedPhones @('+8613800000000') -MaximumAttempts 1 `
        -BudgetCents 6 -ReservePerAttemptCents 6 -ExpiresAtUtc ([DateTimeOffset]::UtcNow.AddHours(2))
    $ca = Join-Path $target 'synthetic-ca.pem'
    [IO.File]::WriteAllText($ca, 'SYNTHETIC_CA_NOT_FOR_NETWORK')
    $bundle = [ordered]@{
        schemaVersion = 2; glmApiKey = $key; businessDatabaseDsn = $dsn;
        databaseTlsCaFile = $ca;
        pnvsCredentialsPath = $credentials; pnvsRuntimePath = $runtime
    }
    $payload = ConvertTo-SecureString (ConvertTo-Json $bundle -Compress) -AsPlainText -Force
    $configuration = Join-Path $target 'startup.dpapi'
    Save-GatewayStartupSettings -Path $configuration -Payload $payload
    $cipher = [IO.File]::ReadAllText($configuration)
    if ($cipher.Contains($key) -or $cipher.Contains($dsn)) { throw 'Plaintext written.' }
    $safe = Test-GatewayStartupSettings -Path $configuration
    if ($safe.Contains($key) -or $safe.Contains($dsn)) { throw 'Plaintext output.' }
    $rejected = $false
    try { Save-GatewayStartupSettings -Path $configuration -Payload $payload } catch { $rejected = $true }
    if (-not $rejected -or [IO.File]::ReadAllText($configuration) -cne $cipher) { throw 'Existing file overwritten.' }
    $loose = Join-Path $target 'inherited.dpapi'
    [IO.File]::WriteAllText($loose, $cipher)
    $rejected = $false
    try { Test-GatewayStartupSettings -Path $loose | Out-Null } catch { $rejected = $true }
    if (-not $rejected) { throw 'Inherited ACL accepted.' }
    $corrupt = Join-Path $target 'corrupt.dpapi'
    Copy-Item -LiteralPath $configuration -Destination $corrupt
    Set-Acl -LiteralPath $corrupt -AclObject (Get-Acl -LiteralPath $configuration)
    [IO.File]::WriteAllText($corrupt, 'CORRUPT_SYNTHETIC_ONLY')
    Write-Output 'synthetic_protected_startup_save_acl_roundtrip_passed'
} finally {
    $id.Dispose()
    $secret.Dispose()
    if ($payload) { $payload.Dispose() }
    $bundle = $null
    $cipher = $null
}
