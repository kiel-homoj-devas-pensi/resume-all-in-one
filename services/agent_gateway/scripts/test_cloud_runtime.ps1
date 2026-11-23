# 所有输入和配置均为当前进程新建的仓库外合成数据。
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$TestDirectory)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'CloudRuntimeSettings.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'WindowsProtectedConfiguration.psm1') -Force
$testRoot = [IO.Path]::GetFullPath($TestDirectory)
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..')).TrimEnd('\')
if ($testRoot.StartsWith($repository+'\',[StringComparison]::OrdinalIgnoreCase) -or
    $testRoot.Equals($repository,[StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $testRoot)) {
    throw '测试要求不存在的仓库外独立目录。'
}
New-Item -ItemType Directory -Path $testRoot | Out-Null
$secure = $null
try {
    $path = Join-Path $testRoot 'runtime.dpapi'
    Save-CloudRuntimeSettings -Path $path -PolicyVersion 'synthetic-v1' -Region 'local-synthetic' `
        -ContentRetentionDays 0 -BackupRetentionDays 0 -ResourceIdentity 'synthetic-database'
    $result = Test-CloudRuntimeSettings -Path $path
    if ($result.status -cne '云合成开发配置检查通过' -or @($result.PSObject.Properties).Count -ne 1) {
        throw '检查输出越界。'
    }
    $cipher = [IO.File]::ReadAllText($path)
    Save-CloudRuntimeSettings -Path (Join-Path $testRoot 'runtime-rotated.dpapi') `
        -PolicyVersion 'synthetic-v1' -Region 'local-synthetic' -ContentRetentionDays 0 `
        -BackupRetentionDays 0 -ResourceIdentity 'synthetic-database'
    $secure = ConvertTo-SecureString $cipher
    $json = [Net.NetworkCredential]::new('',$secure).Password
    $bundle = ConvertFrom-Json $json
    $duplicate = ConvertTo-SecureString ($json.Replace('"schemaVersion":1','"schemaVersion":1,"schemaVersion":1')) -AsPlainText -Force
    try { Write-ProtectedConfiguration -Path (Join-Path $testRoot 'duplicate-field.dpapi') -Payload $duplicate }
    finally { $duplicate.Dispose() }
    $secret = [Convert]::FromBase64String($bundle.cursorSecretBase64)
    if ($secret.Length -ne 32 -or $cipher.Contains($bundle.cursorSecretBase64)) { throw '加密不符合预期。' }
    [Array]::Clear($secret,0,$secret.Length)
    $rejected = $false
    try { Save-CloudRuntimeSettings -Path $path -PolicyVersion 'synthetic-v1' -Region 'local-synthetic' `
        -ContentRetentionDays 0 -BackupRetentionDays 0 -ResourceIdentity 'synthetic-database' }
    catch { $rejected = $true }
    if (-not $rejected -or [IO.File]::ReadAllText($path) -cne $cipher) { throw '已有配置被覆盖。' }
    foreach ($name in @('boolean','extra-field','short-secret','not-synthetic')) {
        $invalid = ConvertFrom-Json $json
        if ($name -eq 'boolean') { $invalid.contentRetentionDays = $true }
        elseif ($name -eq 'extra-field') { $invalid | Add-Member NoteProperty PRIVATE_UNKNOWN 'PRIVATE_VALUE' }
        elseif ($name -eq 'short-secret') { $invalid.cursorSecretBase64 = 'eA==' }
        else { $invalid.syntheticOnly = $false }
        $temporary = ConvertTo-SecureString (ConvertTo-Json $invalid -Compress) -AsPlainText -Force
        try { Write-ProtectedConfiguration -Path (Join-Path $testRoot ($name+'.dpapi')) -Payload $temporary }
        finally { $temporary.Dispose() }
    }
    Copy-Item -LiteralPath $path -Destination (Join-Path $testRoot 'inherited-acl.dpapi')
    Write-Output 'PASS: synthetic cloud DPAPI, independent secret, immutable preparation, restricted checks'
} catch {
    Write-Error '合成云运行配置测试失败，未输出配置或秘密。' -ErrorAction Continue
    exit 1
} finally {
    if ($secure) { $secure.Dispose() }
    $bundle = $null
    $json = $null
}
