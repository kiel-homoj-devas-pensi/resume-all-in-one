# 仅合成凭据；测试目录必须是仓库外的新目录，不读取负责人配置。
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$TestDirectory)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'PnvsCredentials.psm1') -Force
$testRoot = [IO.Path]::GetFullPath($TestDirectory)
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..')).TrimEnd('\')
if ($testRoot.StartsWith($repository, [StringComparison]::OrdinalIgnoreCase) -or
    (Test-Path -LiteralPath $testRoot)) { throw '请指定仓库外的新测试目录。' }
[IO.Directory]::CreateDirectory($testRoot) | Out-Null
$dummyId = 'SYNTHETIC_PNVS_ID_ONLY_20261010'
$dummySecret = 'SYNTHETIC_PNVS_SECRET_ONLY_20261010'
$id = ConvertTo-SecureString $dummyId -AsPlainText -Force
$secret = ConvertTo-SecureString $dummySecret -AsPlainText -Force
$short = ConvertTo-SecureString 'short' -AsPlainText -Force
$target = Join-Path $testRoot 'synthetic.dpapi'
$script:passed = 0

function Assert-Synthetic {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-RejectedSave {
    param([string]$Path, [Security.SecureString]$CandidateId = $id)
    $rejected = $false
    try { Save-PnvsCredentials -Path $Path -AccessKeyId $CandidateId -AccessKeySecret $secret }
    catch {
        $rejected = $true
        Assert-Synthetic (-not $_.Exception.Message.Contains($dummyId) -and
            -not $_.Exception.Message.Contains($dummySecret)) '失败消息包含合成凭据。'
    }
    Assert-Synthetic $rejected '应拒绝保存。'
}

try {
    $saveOutput = @(Save-PnvsCredentials -Path $target -AccessKeyId $id -AccessKeySecret $secret)
    Assert-Synthetic ($saveOutput.Count -eq 0) '保存不能返回凭据。'
    $ciphertext = [IO.File]::ReadAllText($target)
    Assert-Synthetic (-not $ciphertext.Contains($dummyId) -and
        -not $ciphertext.Contains($dummySecret) -and -not $ciphertext.Contains('恒创联众')) '磁盘必须只含密文。'
    $plainSecure = ConvertTo-SecureString $ciphertext
    try {
        $roundTrip = ConvertFrom-Json ([Net.NetworkCredential]::new('', $plainSecure).Password)
        Assert-Synthetic ($roundTrip.ALIBABA_CLOUD_ACCESS_KEY_ID -ceq $dummyId -and
            $roundTrip.ALIBABA_CLOUD_ACCESS_KEY_SECRET -ceq $dummySecret -and
            $roundTrip.PNVS_SIGN_NAME -ceq '恒创联众' -and $roundTrip.PNVS_TEMPLATE_CODE -ceq '100001' -and
            $roundTrip.PNVS_CODE_VARIABLE -ceq 'code' -and $roundTrip.PNVS_MINUTES_VARIABLE -ceq 'min') '合成配置往返失真。'
    } finally { $plainSecure.Dispose(); $roundTrip = $null }
    $script:passed++

    $safe = Test-PnvsCredentials -Path $target | ConvertTo-Json -Compress
    Assert-Synthetic ($safe.Contains('配置检查通过') -and -not $safe.Contains($dummyId) -and
        -not $safe.Contains($dummySecret) -and -not $safe.Contains('ACCESS_KEY')) '检查结果不能返回凭据字段。'
    $script:passed++

    $acl = Get-Acl -LiteralPath $target
    $rules = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
    $actualSids = @($rules | ForEach-Object { $_.IdentityReference.Value })
    $expectedSids = @([Security.Principal.WindowsIdentity]::GetCurrent().User.Value, 'S-1-5-18')
    Assert-Synthetic ($acl.AreAccessRulesProtected -and $rules.Count -eq 2 -and
        @(Compare-Object $expectedSids $actualSids).Count -eq 0) '文件 ACL 未限制到当前用户与 SYSTEM。'
    $script:passed++

    Assert-RejectedSave $target
    Assert-Synthetic ([IO.File]::ReadAllText($target) -ceq $ciphertext) '拒绝覆盖必须保护原密文。'
    $script:passed++

    $inside = Join-Path $repository 'pnvs-synthetic-must-not-exist.dpapi'
    Assert-RejectedSave $inside
    Assert-Synthetic (-not (Test-Path -LiteralPath $inside)) '仓库内不得产生凭据文件。'
    Assert-RejectedSave 'relative-pnvs.dpapi'
    Assert-RejectedSave '\\localhost\synthetic\pnvs.dpapi'
    Assert-RejectedSave ($target + ':other')
    $script:passed++

    $invalid = Join-Path $testRoot 'invalid.dpapi'
    Assert-RejectedSave -Path $invalid -CandidateId $short
    Assert-Synthetic (-not (Test-Path -LiteralPath $invalid)) '非法输入不能保存。'
    $script:passed++

    $corrupt = Join-Path $testRoot 'corrupt.dpapi'
    Copy-Item -LiteralPath $target -Destination $corrupt
    Set-Acl -LiteralPath $corrupt -AclObject $acl
    [IO.File]::WriteAllText($corrupt, $dummySecret)
    $rejected = $false
    try { Test-PnvsCredentials -Path $corrupt | Out-Null }
    catch {
        $rejected = $true
        Assert-Synthetic (-not $_.Exception.Message.Contains($dummySecret)) '损坏文件错误不能带入内容。'
    }
    Assert-Synthetic $rejected '损坏文件不能通过。'
    $script:passed++

    $badJson = Join-Path $testRoot 'invalid-json.dpapi'
    Copy-Item -LiteralPath $target -Destination $badJson
    Set-Acl -LiteralPath $badJson -AclObject $acl
    $badSecure = ConvertTo-SecureString ('{"extra":"' + $dummySecret + '"}') -AsPlainText -Force
    try { [IO.File]::WriteAllText($badJson, (ConvertFrom-SecureString $badSecure)) }
    finally { $badSecure.Dispose() }
    $rejected = $false
    try { Test-PnvsCredentials -Path $badJson | Out-Null }
    catch {
        $rejected = $true
        Assert-Synthetic ($_.Exception.Message -ceq 'PNVS 配置检查失败；请检查路径、当前 Windows 用户、文件权限和配置完整性。') '无效字段必须给出固定错误。'
    }
    Assert-Synthetic $rejected '无效字段不能通过。'
    $script:passed++

    $loose = Join-Path $testRoot 'inherited-acl.dpapi'
    [IO.File]::WriteAllText($loose, $ciphertext)
    $rejected = $false
    try { Test-PnvsCredentials -Path $loose | Out-Null } catch { $rejected = $true }
    Assert-Synthetic $rejected '继承目录权限的配置不能通过。'
    $script:passed++

    $entry = Join-Path $PSScriptRoot 'prepare_pnvs_credentials.ps1'
    $output = & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -File $entry -EncryptedCredentialsPath $target -VerifyOnly
    Assert-Synthetic ($LASTEXITCODE -eq 0) '用户检查命令应成功。'
    $text = $output -join "`n"
    Assert-Synthetic ($text.Contains('配置检查通过') -and -not $text.Contains($dummyId) -and
        -not $text.Contains($dummySecret) -and -not $text.Contains($ciphertext)) '用户检查命令只能输出安全元数据。'
    $output = & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -File $entry -EncryptedCredentialsPath $corrupt -VerifyOnly
    Assert-Synthetic ($LASTEXITCODE -eq 1 -and -not (($output -join "`n").Contains($dummySecret))) '用户检查失败应退出且不输出内容。'
    $script:passed++
    Write-Output "PNVS 本机合成安全检查通过：$script:passed 项；未读取真实凭据，未发送短信。"
} finally {
    $id.Dispose()
    $secret.Dispose()
    $short.Dispose()
}
