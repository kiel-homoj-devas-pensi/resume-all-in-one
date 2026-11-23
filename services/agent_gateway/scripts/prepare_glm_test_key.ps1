# 由负责人在本机 PowerShell 执行；不接收明文参数，避免进入命令历史。
param([Parameter(Mandatory=$true)][string]$EncryptedKeyPath)
$ErrorActionPreference = 'Stop'
$targetPath = [IO.Path]::GetFullPath($EncryptedKeyPath)
if (Test-Path -LiteralPath $targetPath) { throw '目标已存在，请指定新文件以免覆盖现有密钥配置' }
Add-Type -AssemblyName System.Windows.Forms
$keyWindow = New-Object Windows.Forms.Form
$keyWindow.Text = '本机 GLM 测试 Key 安全配置'
$keyWindow.Width = 560
$keyWindow.Height = 190
$keyWindow.StartPosition = 'CenterScreen'
$keyWindow.FormBorderStyle = 'FixedDialog'
$keyWindow.MaximizeBox = $false
$keyWindow.MinimizeBox = $false
$label = New-Object Windows.Forms.Label
$label.Text = '在下方密码框按 Ctrl+V 粘贴完整通用 API Key；只保存 Windows 加密密文。'
$label.SetBounds(16, 16, 510, 36)
$inputBox = New-Object Windows.Forms.TextBox
$inputBox.UseSystemPasswordChar = $true
$inputBox.SetBounds(16, 55, 510, 28)
$saveButton = New-Object Windows.Forms.Button
$saveButton.Text = '加密保存'
$saveButton.SetBounds(322, 98, 100, 32)
$saveButton.DialogResult = [Windows.Forms.DialogResult]::OK
$cancelButton = New-Object Windows.Forms.Button
$cancelButton.Text = '取消'
$cancelButton.SetBounds(430, 98, 96, 32)
$cancelButton.DialogResult = [Windows.Forms.DialogResult]::Cancel
$keyWindow.Controls.AddRange(@($label, $inputBox, $saveButton, $cancelButton))
$keyWindow.AcceptButton = $saveButton
$keyWindow.CancelButton = $cancelButton
$keyWindow.Add_Shown({ $inputBox.Focus() })
try {
    if ($keyWindow.ShowDialog() -ne [Windows.Forms.DialogResult]::OK) {
        Write-Output '已取消；没有保存 Key。'
        return
    }
    $secret = ConvertTo-SecureString -String $inputBox.Text.Trim() -AsPlainText -Force
} finally {
    $inputBox.Clear()
    $keyWindow.Dispose()
}
if ($secret.Length -lt 16) { throw 'Key 长度异常；未保存' }
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $targetPath) | Out-Null
$secret | ConvertFrom-SecureString | Set-Content -LiteralPath $targetPath -Encoding utf8
$secret.Dispose()
Write-Output '仅保存当前 Windows 用户可解密的 DPAPI 密文；请只提供文件路径，不发送 Key。'
Write-Output $targetPath
