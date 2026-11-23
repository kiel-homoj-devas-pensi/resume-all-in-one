# 本机双遮罩录入；命令行只接受文件路径，不接受明文凭据。
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$EncryptedCredentialsPath,
    [switch]$VerifyOnly
)
$ErrorActionPreference = 'Stop'
$window = $null
$idBox = $null
$secretBox = $null
$id = $null
$secret = $null
try {
    Import-Module (Join-Path $PSScriptRoot 'PnvsCredentials.psm1') -Force
    if ($VerifyOnly) {
        $result = Test-PnvsCredentials -Path $EncryptedCredentialsPath
        Write-Output $result.status
        Write-Output "签名：$($result.signName)；模板：$($result.templateCode)；变量：$($result.variables)"
        Write-Output '仅完成本机解密、字段与权限检查；未校验云端权限，未发送短信。'
        exit 0
    }
    if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
        throw '请用 powershell.exe -NoProfile -STA -File 启动此脚本。'
    }
    Add-Type -AssemblyName System.Windows.Forms
    $window = [Windows.Forms.Form]::new()
    $window.Text = 'PNVS 本机凭据安全录入'
    $window.ClientSize = [Drawing.Size]::new(600, 270)
    $window.StartPosition = 'CenterScreen'
    $window.FormBorderStyle = 'FixedDialog'
    $window.MaximizeBox = $false
    $window.MinimizeBox = $false
    $notice = [Windows.Forms.Label]::new()
    $notice.Text = '分别按 Ctrl+V 粘贴 AccessKey ID 和 Secret，两项均遮罩。只加密保存，不发送短信。'
    $notice.SetBounds(16, 16, 565, 40)
    $idLabel = [Windows.Forms.Label]::new()
    $idLabel.Text = 'AccessKey ID'
    $idLabel.SetBounds(16, 65, 125, 25)
    $idBox = [Windows.Forms.TextBox]::new()
    $idBox.UseSystemPasswordChar = $true
    $idBox.SetBounds(150, 62, 430, 28)
    $secretLabel = [Windows.Forms.Label]::new()
    $secretLabel.Text = 'AccessKey Secret'
    $secretLabel.SetBounds(16, 106, 125, 25)
    $secretBox = [Windows.Forms.TextBox]::new()
    $secretBox.UseSystemPasswordChar = $true
    $secretBox.SetBounds(150, 103, 430, 28)
    $metadata = [Windows.Forms.Label]::new()
    $metadata.Text = '签名：恒创联众；模板：100001；变量：code、min'
    $metadata.SetBounds(16, 151, 565, 28)
    $save = [Windows.Forms.Button]::new()
    $save.Text = '加密保存'
    $save.SetBounds(370, 204, 100, 32)
    $save.DialogResult = [Windows.Forms.DialogResult]::OK
    $cancel = [Windows.Forms.Button]::new()
    $cancel.Text = '取消'
    $cancel.SetBounds(480, 204, 100, 32)
    $cancel.DialogResult = [Windows.Forms.DialogResult]::Cancel
    $window.Controls.AddRange(@($notice, $idLabel, $idBox, $secretLabel, $secretBox, $metadata, $save, $cancel))
    $window.AcceptButton = $save
    $window.CancelButton = $cancel
    $window.Add_Shown({ $idBox.Focus() })
    if ($window.ShowDialog() -ne [Windows.Forms.DialogResult]::OK) {
        Write-Output '已取消；没有保存 PNVS 配置。'
        exit 0
    }
    if (-not $idBox.Text -or -not $secretBox.Text) { throw '两项输入均不能为空；未保存。' }
    $id = ConvertTo-SecureString -String $idBox.Text -AsPlainText -Force
    $secret = ConvertTo-SecureString -String $secretBox.Text -AsPlainText -Force
    $idBox.Clear()
    $secretBox.Clear()
    Save-PnvsCredentials -Path $EncryptedCredentialsPath -AccessKeyId $id -AccessKeySecret $secret
    Write-Output 'PNVS 配置已加密保存；文件仅授权当前 Windows 用户与 SYSTEM。'
    Write-Output ([IO.Path]::GetFullPath($EncryptedCredentialsPath))
    Write-Output '请只提供路径和检查结果，不发送密钥或文件内容。Gateway 尚未读取此配置；未发送短信。'
} catch {
    # 固定错误文本，不输出 WinForms/DPAPI/JSON 原异常或局部变量。
    Write-Output 'PNVS 本机配置操作未完成；请检查路径、输入、当前用户与权限，并用 -STA 启动录入。已有文件不会覆盖。'
    exit 1
} finally {
    if ($idBox) { $idBox.Clear() }
    if ($secretBox) { $secretBox.Clear() }
    if ($window) { $window.Dispose() }
    if ($id) { $id.Dispose() }
    if ($secret) { $secret.Dispose() }
}
