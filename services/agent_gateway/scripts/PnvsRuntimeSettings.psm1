# PNVS 运行政策及两个独立服务端秘密；没有网络调用或预算数据库写入。
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'WindowsProtectedConfiguration.psm1') -Force

function Assert-PnvsRuntimeBundle {
    param($Bundle)
    $expected = @('schemaVersion','otpSecretBase64','auditSecretBase64','allowedPhones',
        'maximumAttempts','budgetCents','reservePerAttemptCents','expiresAtUtc')
    if (@(Compare-Object $expected @($Bundle.PSObject.Properties.Name)).Count -ne 0) {
        throw '运行配置字段不匹配。'
    }
    foreach ($name in @('schemaVersion','maximumAttempts','budgetCents','reservePerAttemptCents')) {
        if ($Bundle.$name -isnot [int] -and $Bundle.$name -isnot [long]) {
            throw '运行配置整数类型不正确。'
        }
    }
    if ($Bundle.schemaVersion -ne 1 -or $Bundle.maximumAttempts -lt 1 -or
        $Bundle.maximumAttempts -gt 10000 -or $Bundle.budgetCents -lt 1 -or
        $Bundle.budgetCents -gt 1000000 -or $Bundle.reservePerAttemptCents -lt 6 -or
        $Bundle.reservePerAttemptCents -gt $Bundle.budgetCents) { throw '运行政策范围不正确。' }
    if ($Bundle.allowedPhones -isnot [array] -or $Bundle.allowedPhones.Count -lt 1 -or
        $Bundle.allowedPhones.Count -gt 100) { throw '运行政策需要明确白名单。' }
    $unique = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($phone in $Bundle.allowedPhones) {
        if ($phone -isnot [string] -or $phone -cnotmatch '^\+861[3-9][0-9]{9}$' -or
            -not $unique.Add($phone)) { throw '白名单格式不正确或重复。' }
    }
    $expiry = [DateTimeOffset]::MinValue
    if ($Bundle.expiresAtUtc -isnot [string] -or
        -not [DateTimeOffset]::TryParseExact($Bundle.expiresAtUtc,
            "yyyy-MM-dd'T'HH:mm:ss.ffffff'Z'", [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$expiry)) {
        throw '运行政策到期时间不正确。'
    }
    $otp = $null
    $audit = $null
    try {
        foreach ($name in @('otpSecretBase64','auditSecretBase64')) {
            if ($Bundle.$name -isnot [string]) { throw '运行秘密类型不正确。' }
        }
        $otp = [Convert]::FromBase64String($Bundle.otpSecretBase64)
        $audit = [Convert]::FromBase64String($Bundle.auditSecretBase64)
        if ($otp.Length -ne 32 -or $audit.Length -ne 32 -or
            [Convert]::ToBase64String($otp) -cne $Bundle.otpSecretBase64 -or
            [Convert]::ToBase64String($audit) -cne $Bundle.auditSecretBase64 -or
            $Bundle.otpSecretBase64 -ceq $Bundle.auditSecretBase64) {
            throw '运行秘密格式或独立性不正确。'
        }
    } finally {
        if ($otp) { [Array]::Clear($otp, 0, $otp.Length) }
        if ($audit) { [Array]::Clear($audit, 0, $audit.Length) }
    }
    return $expiry.ToUniversalTime()
}

function Save-PnvsRuntimeSettings {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string[]]$AllowedPhones,
        [Parameter(Mandatory=$true)][int]$MaximumAttempts,
        [Parameter(Mandatory=$true)][int]$BudgetCents,
        [Parameter(Mandatory=$true)][int]$ReservePerAttemptCents,
        [Parameter(Mandatory=$true)][DateTimeOffset]$ExpiresAtUtc
    )
    $created = $false
    $otp = [byte[]]::new(32)
    $audit = [byte[]]::new(32)
    $generator = $null
    $protected = $null
    $bundle = $null
    $json = $null
    try {
        $target = Resolve-ProtectedConfigurationPath -Path $Path
        if (Test-Path -LiteralPath $target) { throw '运行配置已经存在。' }
        if ($ExpiresAtUtc.Offset -ne [TimeSpan]::Zero -or $ExpiresAtUtc -le [DateTimeOffset]::UtcNow) {
            throw '运行政策必须有未来 UTC 到期时间。'
        }
        $generator = [Security.Cryptography.RandomNumberGenerator]::Create()
        $generator.GetBytes($otp)
        $generator.GetBytes($audit)
        $bundle = [pscustomobject][ordered]@{
            schemaVersion = 1
            otpSecretBase64 = [Convert]::ToBase64String($otp)
            auditSecretBase64 = [Convert]::ToBase64String($audit)
            allowedPhones = @($AllowedPhones)
            maximumAttempts = $MaximumAttempts
            budgetCents = $BudgetCents
            reservePerAttemptCents = $ReservePerAttemptCents
            expiresAtUtc = $ExpiresAtUtc.ToString("yyyy-MM-dd'T'HH:mm:ss.ffffff'Z'", [Globalization.CultureInfo]::InvariantCulture)
        }
        Assert-PnvsRuntimeBundle $bundle | Out-Null
        $json = ConvertTo-Json -InputObject $bundle -Compress
        $protected = ConvertTo-SecureString -String $json -AsPlainText -Force
        Write-ProtectedConfiguration -Path $target -Payload $protected
        $created = $true
        Test-PnvsRuntimeSettings -Path $target | Out-Null
    } catch {
        if ($created) { Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue }
        throw 'PNVS 运行配置未保存；请核对仓库外新路径、白名单、次数、分数预算与未来 UTC 到期时间。'
    } finally {
        [Array]::Clear($otp, 0, $otp.Length)
        [Array]::Clear($audit, 0, $audit.Length)
        if ($generator) { $generator.Dispose() }
        if ($protected) { $protected.Dispose() }
        $bundle = $null
        $json = $null
    }
}

function Test-PnvsRuntimeSettings {
    param([Parameter(Mandatory=$true)][string]$Path)
    $protected = $null
    $bundle = $null
    $json = $null
    try {
        $target = Test-ProtectedConfigurationFile -Path $Path
        $protected = ConvertTo-SecureString -String ([IO.File]::ReadAllText($target))
        $json = [Net.NetworkCredential]::new('', $protected).Password
        $bundle = ConvertFrom-Json -InputObject $json
        $expiry = Assert-PnvsRuntimeBundle $bundle
        # 不返回白名单、两个秘密、长度/摘要或密文。到期不是结构损坏，
        # 显式状态说明不可再发送；启动和发送仍必须检查实际时钟。
        return [pscustomobject][ordered]@{
            status = '运行配置检查通过'
            expired = ($expiry -le [DateTimeOffset]::UtcNow)
        }
    } catch {
        throw 'PNVS 运行配置检查失败；请核对路径、当前 Windows 用户、所有者、权限与配置完整性。'
    } finally {
        if ($protected) { $protected.Dispose() }
        $bundle = $null
        $json = $null
    }
}

Export-ModuleMember -Function Save-PnvsRuntimeSettings, Test-PnvsRuntimeSettings
