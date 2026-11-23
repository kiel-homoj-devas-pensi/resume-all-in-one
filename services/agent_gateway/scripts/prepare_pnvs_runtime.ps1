# 只准备运行政策和独立秘密；不读取 AccessKey、不批准数据库预算、不发送短信。
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$EncryptedRuntimePath,
    [switch]$VerifyOnly
)
$ErrorActionPreference = 'Stop'
$window = $null
try {
    Import-Module (Join-Path $PSScriptRoot 'PnvsRuntimeSettings.psm1') -Force
    if ($VerifyOnly) {
        $result = Test-PnvsRuntimeSettings -Path $EncryptedRuntimePath
        Write-Output $result.status
        if ($result.expired) { Write-Output '政策已到期，不可发送。' }
        Write-Output '仅本机检查；未批准数据库预算，未读取 AccessKey，未发送短信。'
        exit 0
    }
    if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { throw '录入需要 STA。' }
    Add-Type -AssemblyName System.Windows.Forms
    $window = [Windows.Forms.Form]::new()
    $window.Text = 'PNVS 本机运行配置'
    $window.ClientSize = [Drawing.Size]::new(620, 410)
    $window.StartPosition = 'CenterScreen'
    $window.FormBorderStyle = 'FixedDialog'
    $window.MaximizeBox = $false
    $notice = [Windows.Forms.Label]::new()
    $notice.Text = '生成独立 OTP / 审计秘密，加密保存。此操作不批准费用、不发送短信，不读取已有 AccessKey。'
    $notice.SetBounds(16, 14, 585, 40)
    $window.Controls.Add($notice)
    $labels = @('号码白名单（每行一个 +86 大陆号码）','最大尝试次数','总预算（整数分）','每次预留（整数分，至少 6）','UTC 到期：yyyy-MM-ddTHH:mm:ssZ')
    $positions = @(58, 143, 185, 227, 269)
    $boxes = @()
    for ($index = 0; $index -lt $labels.Count; $index++) {
        $label = [Windows.Forms.Label]::new()
        $label.Text = $labels[$index]
        $label.SetBounds(16, $positions[$index], 585, 20)
        $box = [Windows.Forms.TextBox]::new()
        $box.SetBounds(16, $positions[$index] + 20, 585, $(if ($index -eq 0) { 58 } else { 24 }))
        if ($index -eq 0) { $box.Multiline = $true; $box.ScrollBars = 'Vertical' }
        $window.Controls.AddRange(@($label,$box))
        $boxes += $box
    }
    $save = [Windows.Forms.Button]::new()
    $save.Text = '生成并保存'
    $save.SetBounds(385, 354, 110, 30)
    $save.DialogResult = [Windows.Forms.DialogResult]::OK
    $cancel = [Windows.Forms.Button]::new()
    $cancel.Text = '取消'
    $cancel.SetBounds(505, 354, 96, 30)
    $cancel.DialogResult = [Windows.Forms.DialogResult]::Cancel
    $window.Controls.AddRange(@($save,$cancel))
    $window.AcceptButton = $save
    $window.CancelButton = $cancel
    if ($window.ShowDialog() -ne [Windows.Forms.DialogResult]::OK) {
        Write-Output '已取消，没有生成运行配置。'
        exit 0
    }
    $numbers = @()
    foreach ($index in @(1,2,3)) {
        if ($boxes[$index].Text -cnotmatch '^[0-9]+$') { throw '需要整数。' }
        $numbers += [int]::Parse($boxes[$index].Text, [Globalization.CultureInfo]::InvariantCulture)
    }
    $expiry = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParseExact($boxes[4].Text,
        "yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$expiry)) { throw '需要 UTC 到期时间。' }
    $phones = @($boxes[0].Lines | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    Save-PnvsRuntimeSettings -Path $EncryptedRuntimePath -AllowedPhones $phones -MaximumAttempts $numbers[0] `
        -BudgetCents $numbers[1] -ReservePerAttemptCents $numbers[2] -ExpiresAtUtc $expiry.ToUniversalTime()
    Write-Output '运行配置已加密保存，文件仅授权当前 Windows 用户与 SYSTEM。'
    Write-Output ([IO.Path]::GetFullPath($EncryptedRuntimePath))
    Write-Output '首次数据库预算批准仍是独立操作；未读取 AccessKey，未发送短信。'
} catch {
    Write-Output '运行配置操作未完成；请核对新路径、白名单、整数分预算、UTC 到期，并用 -STA 启动。已有文件不覆盖。'
    exit 1
} finally {
    if ($window) { $window.Dispose() }
}
