# Existing RDS passwords are entered in masked controls and passed over anonymous stdin only.
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$DatabaseHost,
    [Parameter(Mandatory=$true)][string]$DatabaseName,
    [Parameter(Mandatory=$true)][string]$TlsCaFile,
    [Parameter(Mandatory=$true)][string]$ExpiresAtUtc
)
$ErrorActionPreference='Stop'
$form=$null
$process=$null
$boxes=@{}
$payload=$null
$previousPythonPath=$env:PYTHONPATH
try {
    if([Threading.Thread]::CurrentThread.ApartmentState-ne 'STA'){throw 'STA required'}
    if($DatabaseHost-notmatch '^[A-Za-z0-9.-]{1,253}$'-or $DatabaseName-notmatch '^[A-Za-z0-9_]{1,64}$'){throw 'Invalid target'}
    if($TlsCaFile-notmatch '^[A-Za-z]:[\\/][^:]*$'){throw 'CA must be an ordinary local absolute file path'}
    $python=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.venv/Scripts/python.exe'))
    $entry=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'prepare_mysql_deployment.py'))
    $ca=[IO.Path]::GetFullPath($TlsCaFile)
    foreach($path in @($python,$entry,$ca)){
        if(!(Test-Path -LiteralPath $path -PathType Leaf)-or $path.Contains('"')){throw 'Unavailable input'}
        for($check=$path;$check;){if((Get-Item -LiteralPath $check -Force).Attributes-band [IO.FileAttributes]::ReparsePoint){throw 'Redirected input'};$parent=Split-Path $check -Parent;if($parent-eq $check){break};$check=$parent}
    }
    Add-Type -AssemblyName System.Windows.Forms
    $form=[Windows.Forms.Form]::new()
    $form.Text='RDS 专用空库初始化（建表并收紧权限）'
    $form.ClientSize=[Drawing.Size]::new(820,470)
    $form.StartPosition='CenterScreen'
    $form.FormBorderStyle='FixedDialog'
    $form.MaximizeBox=$false
    $notice=[Windows.Forms.Label]::new()
    $notice.Text="目标：$DatabaseHost :3306 / $DatabaseName`r`n填写已创建的三个数据库账号密码；创建17张空表；收紧maint/web默认权限并授予表/列级权限。owner不变。不生成测试账号，不发短信，不调用模型。密码不保存。"
    $notice.SetBounds(16,12,788,70)
    $form.Controls.Add($notice)
    $accounts=@('resume_owner','resume_maint','resume_web')
    for($i=0;$i-lt $accounts.Count;$i++){
        $label=[Windows.Forms.Label]::new();$label.Text=$accounts[$i]+' 密码';$label.SetBounds(16,98+52*$i,240,28)
        $box=[Windows.Forms.TextBox]::new();$box.SetBounds(260,94+52*$i,540,32);$box.UseSystemPasswordChar=$true;$box.MaxLength=4096
        $boxes[$accounts[$i]]=$box;$form.Controls.AddRange(@($label,$box))
    }
    $dedicated=[Windows.Forms.CheckBox]::new();$dedicated.Text='确认 resume_aio 是本APP的专用空库，无任何其他业务对象';$dedicated.SetBounds(16,268,788,30)
    $quiescent=[Windows.Forms.CheckBox]::new();$quiescent.Text='确认没有其他人或程序正在初始化/修改此库和这两个普通账号';$quiescent.SetBounds(16,304,788,30)
    $warning=[Windows.Forms.Label]::new();$warning.Text='仅执行一次；若失败会停止，先只读核查，不能反复点击初始化。';$warning.SetBounds(16,344,788,30)
    $form.Controls.AddRange(@($dedicated,$quiescent,$warning))
    $confirm=[Windows.Forms.Button]::new();$confirm.Text='初始化并验收';$confirm.SetBounds(510,408,140,36);$confirm.Enabled=$false;$confirm.DialogResult=[Windows.Forms.DialogResult]::OK
    $cancel=[Windows.Forms.Button]::new();$cancel.Text='取消';$cancel.SetBounds(660,408,140,36);$cancel.DialogResult=[Windows.Forms.DialogResult]::Cancel
    $toggle={ $confirm.Enabled=$dedicated.Checked-and $quiescent.Checked }
    $dedicated.Add_CheckedChanged($toggle);$quiescent.Add_CheckedChanged($toggle)
    $form.Controls.AddRange(@($confirm,$cancel));$form.AcceptButton=$confirm;$form.CancelButton=$cancel
    if($ExpiresAtUtc-notmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$'){throw 'Invalid expiry'}
    if($form.ShowDialog()-ne [Windows.Forms.DialogResult]::OK){Write-Output 'Cancelled; no database connection attempted.';exit 0}
    $payload=[ordered]@{}
    foreach($account in $accounts){if(!$boxes[$account].Text){throw 'Missing password'};$payload[$account]=$boxes[$account].Text}
    $start=[Diagnostics.ProcessStartInfo]::new()
    $start.FileName=$python
    $start.Arguments='-X utf8 -I -B "'+$entry+'" --host '+$DatabaseHost+' --database '+$DatabaseName+' --ca-file "'+$ca+'" --expires-at-utc '+$ExpiresAtUtc+' --apply --confirmed-quiescent-dedicated-empty'
    $start.UseShellExecute=$false;$start.CreateNoWindow=$true
    $start.RedirectStandardInput=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    # No owner/maintenance credential is inherited by a long-lived service process.
    foreach($key in @($start.EnvironmentVariables.Keys)){if($key-match '^(AGENT_GATEWAY_|GATEWAY_|PYTHON)'){$start.EnvironmentVariables.Remove($key)}}
    $process=[Diagnostics.Process]::Start($start)
    $stdoutTask=$process.StandardOutput.ReadToEndAsync();$stderrTask=$process.StandardError.ReadToEndAsync()
    $process.StandardInput.WriteLine(($payload|ConvertTo-Json -Compress));$process.StandardInput.Close()
    foreach($box in $boxes.Values){$box.Clear()};$payload.Clear();$payload=$null
    if(!$process.WaitForExit(300000)){$process.Kill();throw 'Initialization outcome unknown'}
    $stdout=$stdoutTask.GetAwaiter().GetResult();$stderr=[string]$stderrTask.GetAwaiter().GetResult()
    if($stderr-or $stdout.Length-gt 65536){throw 'Unexpected diagnostic output'}
    $result=$stdout|ConvertFrom-Json
    if($result.status-notin @('dedicated_database_prepared','outcome_requires_read_only_review','preflight_failed')){throw 'Unexpected result'}
    Write-Output $stdout
    exit $process.ExitCode
} catch {
    Write-Output '{"status":"initialization_unavailable","retryable":false,"outcomeRequiresReadOnlyReview":true}'
    exit 1
} finally {
    foreach($box in $boxes.Values){$box.Clear()}
    if($payload){$payload.Clear()};$payload=$null
    if($form){$form.Dispose()}
    if($process){
        try{$process.StandardInput.Close()}catch{}
        try{if(!$process.HasExited){$process.Kill();[void]$process.WaitForExit(5000)}}catch{}
        $process.Dispose()
    }
    $env:PYTHONPATH=$previousPythonPath
}
