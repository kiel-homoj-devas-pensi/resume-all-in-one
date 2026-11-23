# 只使用新建的仓库外合成运行政策，不读取负责人配置或 AccessKey。
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$TestDirectory)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'PnvsRuntimeSettings.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'WindowsProtectedConfiguration.psm1') -Force
$testRoot = [IO.Path]::GetFullPath($TestDirectory)
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..')).TrimEnd('\')
if ($testRoot.Equals($repository, [StringComparison]::OrdinalIgnoreCase) -or
    $testRoot.StartsWith($repository + '\', [StringComparison]::OrdinalIgnoreCase) -or
    (Test-Path -LiteralPath $testRoot)) { throw '请使用仓库外的新合成目录。' }
[IO.Directory]::CreateDirectory($testRoot) | Out-Null
$target = Join-Path $testRoot 'runtime.dpapi'
$expiry = [DateTimeOffset]::Parse('2099-01-01T00:00:00Z')
$passed = 0
$secure = $null
$json = $null
$bundle = $null
function Assert-Synthetic([bool]$Condition) { if (-not $Condition) { throw '合成运行配置断言失败。' } }
try {
    $output = @(Save-PnvsRuntimeSettings -Path $target -AllowedPhones @('+8613800000000') `
        -MaximumAttempts 2 -BudgetCents 12 -ReservePerAttemptCents 6 -ExpiresAtUtc $expiry)
    Assert-Synthetic ($output.Count -eq 0)
    $passed++
    $result = Test-PnvsRuntimeSettings -Path $target
    Assert-Synthetic ($result.status -ceq '运行配置检查通过' -and -not $result.expired -and
        @($result.PSObject.Properties).Count -eq 2)
    $passed++
    $cipher = [IO.File]::ReadAllText($target)
    $secure = ConvertTo-SecureString $cipher
    $json = [Net.NetworkCredential]::new('', $secure).Password
    $bundle = ConvertFrom-Json $json
    Assert-Synthetic ($bundle.allowedPhones.Count -eq 1 -and
        [Convert]::FromBase64String($bundle.otpSecretBase64).Length -eq 32 -and
        [Convert]::FromBase64String($bundle.auditSecretBase64).Length -eq 32 -and
        $bundle.otpSecretBase64 -cne $bundle.auditSecretBase64 -and
        -not $cipher.Contains($bundle.otpSecretBase64) -and -not $cipher.Contains('+8613800000000'))
    $passed++
    $rejected = $false
    try { Save-PnvsRuntimeSettings -Path $target -AllowedPhones @('+8613800000000') `
        -MaximumAttempts 2 -BudgetCents 12 -ReservePerAttemptCents 6 -ExpiresAtUtc $expiry }
    catch { $rejected = $true }
    Assert-Synthetic ($rejected -and [IO.File]::ReadAllText($target) -ceq $cipher)
    $passed++
    foreach ($candidate in @(
        @{Name='below-price';Phones=@('+8613800000000');Maximum=2;Budget=12;Unit=5;Expiry=$expiry},
        @{Name='duplicate';Phones=@('+8613800000000','+8613800000000');Maximum=2;Budget=12;Unit=6;Expiry=$expiry},
        @{Name='foreign';Phones=@('+15550000001');Maximum=2;Budget=12;Unit=6;Expiry=$expiry},
        @{Name='expired';Phones=@('+8613800000000');Maximum=2;Budget=12;Unit=6;Expiry=$expiry.AddYears(-100)},
        @{Name='zero';Phones=@('+8613800000000');Maximum=0;Budget=12;Unit=6;Expiry=$expiry},
        @{Name='over-budget';Phones=@('+8613800000000');Maximum=2;Budget=5;Unit=6;Expiry=$expiry}
    )) {
        $invalid = Join-Path $testRoot ($candidate.Name + '.dpapi')
        $rejected = $false
        try { Save-PnvsRuntimeSettings -Path $invalid -AllowedPhones $candidate.Phones `
            -MaximumAttempts $candidate.Maximum -BudgetCents $candidate.Budget `
            -ReservePerAttemptCents $candidate.Unit -ExpiresAtUtc $candidate.Expiry }
        catch { $rejected = $true }
        Assert-Synthetic ($rejected -and -not (Test-Path -LiteralPath $invalid))
        $passed++
    }
    $loose = Join-Path $testRoot 'inherited-acl.dpapi'
    [IO.File]::WriteAllText($loose, $cipher)
    $rejected = $false
    try { Test-PnvsRuntimeSettings -Path $loose | Out-Null } catch { $rejected = $true }
    Assert-Synthetic $rejected
    $passed++
    # 合成篡改但正确加密，证明字段类型/用途仍须检查，不能只看 DPAPI 成功。
    foreach ($name in @('same-secret','boolean','extra-field')) {
        $invalidBundle = ConvertFrom-Json $json
        if ($name -eq 'same-secret') { $invalidBundle.auditSecretBase64 = $invalidBundle.otpSecretBase64 }
        if ($name -eq 'boolean') { $invalidBundle.maximumAttempts = $true }
        if ($name -eq 'extra-field') { $invalidBundle | Add-Member -NotePropertyName extra -NotePropertyValue 'unexpected' }
        $invalidSecure = ConvertTo-SecureString (ConvertTo-Json $invalidBundle -Compress) -AsPlainText -Force
        try { Write-ProtectedConfiguration -Path (Join-Path $testRoot ($name+'.dpapi')) -Payload $invalidSecure }
        finally { $invalidSecure.Dispose(); $invalidBundle = $null }
        $rejected = $false
        try { Test-PnvsRuntimeSettings -Path (Join-Path $testRoot ($name+'.dpapi')) | Out-Null }
        catch { $rejected = $true }
        Assert-Synthetic $rejected
        $passed++
    }
    Write-Output "合成运行配置安全检查通过：$passed 项；未读取实际密钥，未批准预算，未发送短信。"
} finally {
    if ($secure) { $secure.Dispose() }
    $bundle = $null
    $json = $null
}
