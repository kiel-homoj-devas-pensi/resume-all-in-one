# 仅负责仓库外本机配置；没有网络调用，也不向调用者返回明文凭据。
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'WindowsProtectedConfiguration.psm1') -Force

function Assert-PnvsBundle {
    param($Bundle)
    $expected = @('schemaVersion', 'ALIBABA_CLOUD_ACCESS_KEY_ID',
        'ALIBABA_CLOUD_ACCESS_KEY_SECRET', 'PNVS_SIGN_NAME', 'PNVS_TEMPLATE_CODE',
        'PNVS_CODE_VARIABLE', 'PNVS_MINUTES_VARIABLE')
    $actual = @($Bundle.PSObject.Properties.Name)
    if (@(Compare-Object $expected $actual).Count -ne 0) { throw '配置字段不完整。' }
    if (($Bundle.schemaVersion -isnot [int] -and $Bundle.schemaVersion -isnot [long]) -or
        $Bundle.schemaVersion -ne 1 -or $Bundle.PNVS_SIGN_NAME -cne '恒创联众' -or
        $Bundle.PNVS_TEMPLATE_CODE -cne '100001' -or $Bundle.PNVS_CODE_VARIABLE -cne 'code' -or
        $Bundle.PNVS_MINUTES_VARIABLE -cne 'min') { throw '配置版本或模板不匹配。' }
    foreach ($name in @('PNVS_SIGN_NAME', 'PNVS_TEMPLATE_CODE', 'PNVS_CODE_VARIABLE', 'PNVS_MINUTES_VARIABLE')) {
        if ($Bundle.$name -isnot [string]) { throw '配置字段类型不正确。' }
    }
    foreach ($name in @('ALIBABA_CLOUD_ACCESS_KEY_ID', 'ALIBABA_CLOUD_ACCESS_KEY_SECRET')) {
        $value = $Bundle.$name
        if ($value -isnot [string] -or $value.Length -lt 16 -or $value.Length -gt 256 -or
            $value -match '\s|[\x00-\x1f\x7f]') { throw '凭据格式不正确。' }
    }
}

function Save-PnvsCredentials {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][Security.SecureString]$AccessKeyId,
        [Parameter(Mandatory=$true)][Security.SecureString]$AccessKeySecret
    )
    $created = $false
    $protectedBundle = $null
    $bundle = $null
    $json = $null
    try {
        $target = Resolve-ProtectedConfigurationPath $Path
        if (Test-Path -LiteralPath $target) { throw '目标已存在。' }
        $bundle = [pscustomobject][ordered]@{
            schemaVersion = 1
            ALIBABA_CLOUD_ACCESS_KEY_ID = [Net.NetworkCredential]::new('', $AccessKeyId).Password
            ALIBABA_CLOUD_ACCESS_KEY_SECRET = [Net.NetworkCredential]::new('', $AccessKeySecret).Password
            PNVS_SIGN_NAME = '恒创联众'
            PNVS_TEMPLATE_CODE = '100001'
            PNVS_CODE_VARIABLE = 'code'
            PNVS_MINUTES_VARIABLE = 'min'
        }
        Assert-PnvsBundle $bundle
        $json = ConvertTo-Json -InputObject $bundle -Compress
        $protectedBundle = ConvertTo-SecureString -String $json -AsPlainText -Force
        Write-ProtectedConfiguration -Path $target -Payload $protectedBundle
        $created = $true
        Test-PnvsCredentials -Path $target | Out-Null
    } catch {
        if ($created) { Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue }
        # 不输出原异常：序列化、格式检查或权限错误可能带入输入值。
        throw '未保存 PNVS 配置；请检查仓库外路径、文件是否已存在、两项输入和本机写入权限。'
    } finally {
        if ($protectedBundle) { $protectedBundle.Dispose() }
        $bundle = $null
        $json = $null
    }
}

function Test-PnvsCredentials {
    param([Parameter(Mandatory=$true)][string]$Path)
    $protectedBundle = $null
    $bundle = $null
    $json = $null
    try {
        $target = Test-ProtectedConfigurationFile -Path $Path
        $protectedBundle = ConvertTo-SecureString -String ([IO.File]::ReadAllText($target))
        $json = [Net.NetworkCredential]::new('', $protectedBundle).Password
        $bundle = ConvertFrom-Json -InputObject $json
        Assert-PnvsBundle $bundle
        # 只返回非密钥字段；不返回 ID、Secret、长度、摘要或密文。
        return [pscustomobject][ordered]@{
            status = '配置检查通过'
            signName = $bundle.PNVS_SIGN_NAME
            templateCode = $bundle.PNVS_TEMPLATE_CODE
            variables = 'code、min'
        }
    } catch {
        throw 'PNVS 配置检查失败；请检查路径、当前 Windows 用户、文件权限和配置完整性。'
    } finally {
        if ($protectedBundle) { $protectedBundle.Dispose() }
        $bundle = $null
        $json = $null
    }
}

Export-ModuleMember -Function Save-PnvsCredentials, Test-PnvsCredentials
