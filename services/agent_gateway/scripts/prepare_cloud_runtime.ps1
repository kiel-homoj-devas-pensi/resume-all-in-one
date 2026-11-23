# 元数据必须逐项明确；游标秘密由系统生成，不从命令行录入或输出。
[CmdletBinding(DefaultParameterSetName='Create')]
param(
    [Parameter(Mandatory=$true)][string]$EncryptedRuntimePath,
    [Parameter(Mandatory=$true,ParameterSetName='Verify')][switch]$VerifyOnly,
    [Parameter(Mandatory=$true,ParameterSetName='Create')][string]$PolicyVersion,
    [Parameter(Mandatory=$true,ParameterSetName='Create')][string]$Region,
    [Parameter(Mandatory=$true,ParameterSetName='Create')][int]$ContentRetentionDays,
    [Parameter(Mandatory=$true,ParameterSetName='Create')][int]$BackupRetentionDays,
    [Parameter(Mandatory=$true,ParameterSetName='Create')][string]$ResourceIdentity
)
$ErrorActionPreference = 'Stop'
try {
    Import-Module (Join-Path $PSScriptRoot 'CloudRuntimeSettings.psm1') -Force
    if ($VerifyOnly) {
        $result = Test-CloudRuntimeSettings -Path $EncryptedRuntimePath
        Write-Output $result.status
        Write-Output '仅本机字段/权限检查；未连接数据库、读取 AccessKey 或发送短信。'
        exit 0
    }
    Save-CloudRuntimeSettings -Path $EncryptedRuntimePath -PolicyVersion $PolicyVersion -Region $Region `
        -ContentRetentionDays $ContentRetentionDays -BackupRetentionDays $BackupRetentionDays `
        -ResourceIdentity $ResourceIdentity
    Write-Output '云合成开发配置已加密保存；文件仅授权当前 Windows 用户与 SYSTEM。'
    Write-Output ([IO.Path]::GetFullPath($EncryptedRuntimePath))
    Write-Output '未连接数据库、读取 AccessKey、发送短信或批准生产云同步。'
} catch {
    Write-Error '云配置准备或检查未完成；只提供路径和检查结果，不提供密钥或文件内容。' -ErrorAction Continue
    exit 1
}
