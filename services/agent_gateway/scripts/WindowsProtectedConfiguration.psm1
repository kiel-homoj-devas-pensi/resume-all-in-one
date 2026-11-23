# 本机受限配置的路径、CurrentUser DPAPI 和 ACL；不返回解密内容。
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-ProtectedConfigurationPath {
    param([Parameter(Mandatory=$true)][string]$Path)
    if ($Path -notmatch '^[A-Za-z]:[\\/]' -or $Path.Substring(2).Contains(':')) {
        throw '受限配置需要本机普通绝对路径。'
    }
    $target = [IO.Path]::GetFullPath($Path)
    $repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..')).TrimEnd('\')
    if ($target.Equals($repository, [StringComparison]::OrdinalIgnoreCase) -or
        $target.StartsWith($repository + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw '受限配置必须保存在仓库外。'
    }
    $ancestor = $target
    while ($ancestor) {
        if (Test-Path -LiteralPath $ancestor) {
            $item = Get-Item -LiteralPath $ancestor -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw '受限配置不能包含重解析点。'
            }
        }
        $ancestor = Split-Path -Parent $ancestor
    }
    return $target
}

function New-ProtectedConfigurationSecurity {
    $userSid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $security = [Security.AccessControl.FileSecurity]::new()
    $security.SetAccessRuleProtection($true, $false)
    $security.SetOwner($userSid)
    foreach ($sid in @($userSid, [Security.Principal.SecurityIdentifier]::new('S-1-5-18'))) {
        $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            $sid, [Security.AccessControl.FileSystemRights]::FullControl,
            [Security.AccessControl.AccessControlType]::Allow))
    }
    return $security
}

function Test-ProtectedConfigurationFile {
    param([Parameter(Mandatory=$true)][string]$Path)
    try {
        $target = Resolve-ProtectedConfigurationPath $Path
        $file = Get-Item -LiteralPath $target -Force
        if ($file.PSIsContainer -or $file.Length -le 0 -or $file.Length -gt 65536) {
            throw '配置文件不正确。'
        }
        $security = Get-Acl -LiteralPath $target
        $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        if (-not $security.AreAccessRulesProtected -or
            $security.GetOwner([Security.Principal.SecurityIdentifier]).Value -ne $currentSid) {
            throw '配置权限或所有者不正确。'
        }
        $allowed = @($currentSid, 'S-1-5-18')
        $rules = @($security.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
        if ($rules.Count -ne 2) { throw '配置权限不正确。' }
        foreach ($rule in $rules) {
            if ($rule.IdentityReference.Value -notin $allowed -or $rule.IsInherited -or
                $rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow -or
                $rule.FileSystemRights -ne [Security.AccessControl.FileSystemRights]::FullControl) {
                throw '配置权限不正确。'
            }
        }
        return $target
    } catch {
        throw '受限配置检查失败；请核对本机路径、当前用户、所有者与权限。'
    }
}

function Write-ProtectedConfiguration {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][Security.SecureString]$Payload
    )
    $created = $false
    $stream = $null
    try {
        $target = Resolve-ProtectedConfigurationPath $Path
        if (Test-Path -LiteralPath $target) { throw '配置文件已存在。' }
        # 未指定 -Key，绑定本机当前 Windows 用户；保存端不输出密文。
        $bytes = [Text.Encoding]::UTF8.GetBytes((ConvertFrom-SecureString $Payload))
        if ($bytes.Length -gt 65536) { throw '配置文件过大。' }
        [IO.Directory]::CreateDirectory((Split-Path -Parent $target)) | Out-Null
        $stream = [IO.FileStream]::new($target, [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write, [IO.FileShare]::None)
        $created = $true
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Dispose()
        $stream = $null
        Set-Acl -LiteralPath $target -AclObject (New-ProtectedConfigurationSecurity)
        Test-ProtectedConfigurationFile -Path $target | Out-Null
    } catch {
        if ($stream) { $stream.Dispose(); $stream = $null }
        if ($created) { Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue }
        throw '受限配置未保存；请核对本机路径、当前用户、是否已有文件与写入权限。'
    } finally {
        if ($stream) { $stream.Dispose() }
    }
}

Export-ModuleMember -Function Resolve-ProtectedConfigurationPath, Test-ProtectedConfigurationFile, Write-ProtectedConfiguration
