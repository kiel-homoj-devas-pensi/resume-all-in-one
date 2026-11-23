# 显式合成开发政策和独立游标秘密；只复用 CurrentUser DPAPI/ACL，不操作数据库或网络。
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'WindowsProtectedConfiguration.psm1') -Force

function Assert-CloudRuntimeBundle {
    param($Bundle)
    $fields = @('schemaVersion','syntheticOnly','policyVersion','region','contentRetentionDays',
        'backupRetentionDays','resourceIdentity','cursorSecretBase64')
    if (@(Compare-Object -CaseSensitive $fields @($Bundle.PSObject.Properties.Name)).Count -ne 0) {
        throw '云运行配置字段不匹配。'
    }
    foreach ($name in @('schemaVersion','contentRetentionDays','backupRetentionDays')) {
        if ($Bundle.$name -isnot [int] -and $Bundle.$name -isnot [long]) {
            throw '云运行配置整数类型不正确。'
        }
    }
    if ($Bundle.schemaVersion -ne 1 -or $Bundle.syntheticOnly -isnot [bool] -or
        $Bundle.syntheticOnly -ne $true -or $Bundle.contentRetentionDays -lt 0 -or
        $Bundle.contentRetentionDays -gt 3650 -or $Bundle.backupRetentionDays -lt 0 -or
        $Bundle.backupRetentionDays -gt 3650) { throw '云运行政策范围不正确。' }
    foreach ($name in @('policyVersion','region','resourceIdentity')) {
        if ($Bundle.$name -isnot [string] -or
            $Bundle.$name -cnotmatch '\A[A-Za-z0-9][A-Za-z0-9._:-]{0,63}\z') {
            throw '云运行政策标签不正确。'
        }
    }
    $secret = $null
    try {
        if ($Bundle.cursorSecretBase64 -isnot [string]) { throw '游标秘密类型不正确。' }
        $secret = [Convert]::FromBase64String($Bundle.cursorSecretBase64)
        if ($secret.Length -ne 32 -or
            [Convert]::ToBase64String($secret) -cne $Bundle.cursorSecretBase64) {
            throw '游标秘密格式不正确。'
        }
    } finally {
        if ($secret) { [Array]::Clear($secret, 0, $secret.Length) }
    }
}

function Save-CloudRuntimeSettings {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$PolicyVersion,
        [Parameter(Mandatory=$true)][string]$Region,
        [Parameter(Mandatory=$true)][int]$ContentRetentionDays,
        [Parameter(Mandatory=$true)][int]$BackupRetentionDays,
        [Parameter(Mandatory=$true)][string]$ResourceIdentity
    )
    $created = $false
    $secret = [byte[]]::new(32)
    $generator = $null
    $protected = $null
    $bundle = $null
    $json = $null
    try {
        $target = Resolve-ProtectedConfigurationPath -Path $Path
        if (Test-Path -LiteralPath $target) { throw '云运行配置已经存在。' }
        $generator = [Security.Cryptography.RandomNumberGenerator]::Create()
        $generator.GetBytes($secret)
        $bundle = [pscustomobject][ordered]@{
            schemaVersion = 1
            syntheticOnly = $true
            policyVersion = $PolicyVersion
            region = $Region
            contentRetentionDays = $ContentRetentionDays
            backupRetentionDays = $BackupRetentionDays
            resourceIdentity = $ResourceIdentity
            cursorSecretBase64 = [Convert]::ToBase64String($secret)
        }
        Assert-CloudRuntimeBundle $bundle
        $json = ConvertTo-Json -InputObject $bundle -Compress
        $protected = ConvertTo-SecureString -String $json -AsPlainText -Force
        Write-ProtectedConfiguration -Path $target -Payload $protected
        $created = $true
        Test-CloudRuntimeSettings -Path $target | Out-Null
    } catch {
        if ($created) { Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue }
        throw '云运行配置未保存；请核对仓库外新路径与明确的合成开发政策。'
    } finally {
        [Array]::Clear($secret, 0, $secret.Length)
        if ($generator) { $generator.Dispose() }
        if ($protected) { $protected.Dispose() }
        $bundle = $null
        $json = $null
    }
}

function Test-CloudRuntimeSettings {
    param([Parameter(Mandatory=$true)][string]$Path)
    $protected = $null
    $bundle = $null
    $json = $null
    try {
        $target = Test-ProtectedConfigurationFile -Path $Path
        $protected = ConvertTo-SecureString -String ([IO.File]::ReadAllText($target))
        $json = [Net.NetworkCredential]::new('', $protected).Password
        $bundle = ConvertFrom-Json -InputObject $json
        Assert-CloudRuntimeBundle $bundle
        return [pscustomobject]@{status='云合成开发配置检查通过'}
    } catch {
        throw '云运行配置检查失败；请核对路径、当前 Windows 用户、权限与配置完整性。'
    } finally {
        if ($protected) { $protected.Dispose() }
        $bundle = $null
        $json = $null
    }
}

Export-ModuleMember -Function Save-CloudRuntimeSettings, Test-CloudRuntimeSettings
