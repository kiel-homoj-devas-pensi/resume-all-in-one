# Existing RDS passwords are entered in masked controls and passed over anonymous stdin only.
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$DatabaseHost,
    [Parameter(Mandatory=$true)][string]$DatabaseName,
    [Parameter(Mandatory=$true)][string]$TlsCaFile
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
    $entry=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'inspect_mysql_deployment.py'))
    $ca=[IO.Path]::GetFullPath($TlsCaFile)
    foreach($path in @($python,$entry,$ca)){
        if(!(Test-Path -LiteralPath $path -PathType Leaf)-or $path.Contains('"')){throw 'Unavailable input'}
        for($check=$path;$check;){if((Get-Item -LiteralPath $check -Force).Attributes-band [IO.FileAttributes]::ReparsePoint){throw 'Redirected input'};$parent=Split-Path $check -Parent;if($parent-eq $check){break};$check=$parent}
    }
    Add-Type -AssemblyName System.Windows.Forms
    $form=[Windows.Forms.Form]::new()
    $form.Text='RDS 账号只读验收（不建表、不授权）'
    $form.ClientSize=[Drawing.Size]::new(820,340)
    $form.StartPosition='CenterScreen'
    $form.FormBorderStyle='FixedDialog'
    $form.MaximizeBox=$false
    $notice=[Windows.Forms.Label]::new()
    $notice.Text="目标：$DatabaseHost :3306 / $DatabaseName`r`n填写已创建的三个数据库账号密码；仅验证 TLS、实际身份、GRANTS 和数据库可见信息。密码不保存、不放命令参数。"
    $notice.SetBounds(16,12,788,70)
    $form.Controls.Add($notice)
    $accounts=@('resume_owner','resume_maint','resume_web')
    for($i=0;$i-lt $accounts.Count;$i++){
        $label=[Windows.Forms.Label]::new();$label.Text=$accounts[$i]+' 密码';$label.SetBounds(16,98+52*$i,240,28)
        $box=[Windows.Forms.TextBox]::new();$box.SetBounds(260,94+52*$i,540,32);$box.UseSystemPasswordChar=$true;$box.MaxLength=4096
        $boxes[$accounts[$i]]=$box;$form.Controls.AddRange(@($label,$box))
    }
    $confirm=[Windows.Forms.Button]::new();$confirm.Text='只读检查';$confirm.SetBounds(510,280,140,36);$confirm.DialogResult=[Windows.Forms.DialogResult]::OK
    $cancel=[Windows.Forms.Button]::new();$cancel.Text='取消';$cancel.SetBounds(660,280,140,36);$cancel.DialogResult=[Windows.Forms.DialogResult]::Cancel
    $form.Controls.AddRange(@($confirm,$cancel));$form.AcceptButton=$confirm;$form.CancelButton=$cancel
    if($form.ShowDialog()-ne [Windows.Forms.DialogResult]::OK){Write-Output 'Cancelled; no database connection attempted.';exit 0}
    $payload=[ordered]@{}
    foreach($account in $accounts){if(!$boxes[$account].Text){throw 'Missing password'};$payload[$account]=$boxes[$account].Text}
    $start=[Diagnostics.ProcessStartInfo]::new()
    $start.FileName=$python
    $start.Arguments='-X utf8 -I -B "'+$entry+'" --host '+$DatabaseHost+' --database '+$DatabaseName+' --ca-file "'+$ca+'"'
    $start.UseShellExecute=$false;$start.CreateNoWindow=$true
    $start.RedirectStandardInput=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    # No owner/maintenance credential is inherited by a long-lived service process.
    foreach($key in @($start.EnvironmentVariables.Keys)){if($key-match '^(AGENT_GATEWAY_|GATEWAY_|PYTHON)'){$start.EnvironmentVariables.Remove($key)}}
    $process=[Diagnostics.Process]::Start($start)
    $stdoutTask=$process.StandardOutput.ReadToEndAsync();$stderrTask=$process.StandardError.ReadToEndAsync()
    $process.StandardInput.WriteLine(($payload|ConvertTo-Json -Compress));$process.StandardInput.Close()
    foreach($box in $boxes.Values){$box.Clear()};$payload.Clear();$payload=$null
    if(!$process.WaitForExit(120000)){$process.Kill();throw 'Inspection timed out'}
    $stdout=$stdoutTask.GetAwaiter().GetResult();$stderr=[string]$stderrTask.GetAwaiter().GetResult()
    if($stderr-or $stdout.Length-gt 65536){throw 'Unexpected diagnostic output'}
    $result=$stdout|ConvertFrom-Json
    if($result.status-notin @('authenticated_accounts_inspected','inspection_failed')){throw 'Unexpected result'}
    Write-Output $stdout
    exit $process.ExitCode
} catch {
    Write-Output '{"status":"inspection_unavailable","retryable":false,"grantsApplied":false}'
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
