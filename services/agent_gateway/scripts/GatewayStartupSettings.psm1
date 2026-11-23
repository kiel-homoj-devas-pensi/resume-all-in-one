# Only startup fields. Reuses the existing CurrentUser DPAPI and exact ACL writer.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'WindowsProtectedConfiguration.psm1') -Force

function Assert-GatewayStartupBundle {
    param($Bundle)
    $expected = @('schemaVersion','glmApiKey','businessDatabaseDsn','databaseTlsCaFile',
        'pnvsCredentialsPath','pnvsRuntimePath')
    if ($Bundle.schemaVersion -eq 1) { $expected += 'databaseExpiresAtUtc' }
    if (@(Compare-Object $expected @($Bundle.PSObject.Properties.Name)).Count -ne 0 -or
        ($Bundle.schemaVersion -isnot [int] -and $Bundle.schemaVersion -isnot [long]) -or
        $Bundle.schemaVersion -notin @(1,2)) { throw 'Invalid startup fields.' }
    foreach ($name in ($expected | Where-Object { $_ -ne 'schemaVersion' })) {
        $value = $Bundle.$name
        if ($value -isnot [string] -or $value.Length -lt 1 -or $value.Length -gt 4096 -or
            $value -cne $value.Trim() -or $value -match '[\x00-\x1f\x7f]') {
            throw 'Invalid startup value.'
        }
    }
    if ($Bundle.glmApiKey.Length -lt 16 -or $Bundle.glmApiKey.Length -gt 256 -or
        $Bundle.glmApiKey -match '\s' -or $Bundle.businessDatabaseDsn -cnotmatch '^mysql://') {
        throw 'Invalid startup credentials.'
    }
    foreach ($name in @('databaseTlsCaFile','pnvsCredentialsPath','pnvsRuntimePath')) {
        $reference = Resolve-ProtectedConfigurationPath -Path $Bundle.$name
        if (-not [IO.File]::Exists($reference)) { throw 'Referenced file unavailable.' }
    }
    if ($Bundle.schemaVersion -eq 1) {
        # Syntax validation only for existing encrypted bundles; not service expiry.
        $expiry = [DateTimeOffset]::MinValue
        if ($Bundle.databaseExpiresAtUtc -cnotmatch 'Z$' -or
            -not [DateTimeOffset]::TryParse($Bundle.databaseExpiresAtUtc,
                [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$expiry)) {
            throw 'Invalid legacy database date.'
        }
    }
}

function Save-GatewayStartupSettings {
    param([Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][Security.SecureString]$Payload)
    $created = $false
    $bundle = $null
    $plain = $null
    try {
        $target = Resolve-ProtectedConfigurationPath -Path $Path
        if (Test-Path -LiteralPath $target) { throw 'Target exists.' }
        $plain = [Net.NetworkCredential]::new('', $Payload).Password
        $bundle = ConvertFrom-Json $plain
        Assert-GatewayStartupBundle $bundle
        Write-ProtectedConfiguration -Path $target -Payload $Payload
        $created = $true
        Test-GatewayStartupSettings -Path $target | Out-Null
    } catch {
        if ($created) { Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue }
        throw 'Gateway startup configuration not saved; verify paths, identity and input.'
    } finally { $bundle = $null; $plain = $null }
}

function Test-GatewayStartupSettings {
    param([Parameter(Mandatory=$true)][string]$Path)
    $secure = $null
    $bundle = $null
    $plain = $null
    try {
        $target = Test-ProtectedConfigurationFile -Path $Path
        $secure = ConvertTo-SecureString ([IO.File]::ReadAllText($target))
        $plain = [Net.NetworkCredential]::new('', $secure).Password
        $bundle = ConvertFrom-Json $plain
        Assert-GatewayStartupBundle $bundle
        return 'protected_startup_file_check_passed; no network or database access'
    } catch {
        throw 'Gateway startup configuration unavailable; verify paths, identity and permissions.'
    } finally {
        if ($secure) { $secure.Dispose() }
        $bundle = $null
        $plain = $null
    }
}

Export-ModuleMember -Function Save-GatewayStartupSettings, Test-GatewayStartupSettings
