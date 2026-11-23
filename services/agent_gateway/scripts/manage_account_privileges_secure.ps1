# Owner-masked input for one explicit grant. No passwords/phone in argv or environment.
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$DatabaseHost,
    [ValidateRange(1,65535)][int]$DatabasePort=3306,
    [Parameter(Mandatory=$true)][string]$DatabaseName,
    [Parameter(Mandatory=$true)][string]$TlsCaFile,
    [Parameter(Mandatory=$true)][string]$ExpiresAtUtc,
    [Parameter(Mandatory=$true)][string]$AccountId,
    [Parameter(Mandatory=$true)][string]$GrantId,
    [Parameter(Mandatory=$true)][ValidateSet('admin','permanentMember')][string]$Privilege,
    [Parameter(Mandatory=$true)][string]$OperatorId,
    [Parameter(Mandatory=$true)][string]$EvidenceSha256,
    [switch]$Apply
)
$ErrorActionPreference='Stop'
$form=$null;$process=$null;$boxes=@{};$payload=$null;$encoded=$null;$serialized=$null
try{
    if([Threading.Thread]::CurrentThread.ApartmentState-ne 'STA'){throw 'STA required'}
    foreach($id in @($AccountId,$GrantId,$OperatorId)){if($id-cnotmatch '^[A-Za-z0-9._:-]{1,64}$'){throw 'Invalid plan'}}
    if($DatabaseHost-cnotmatch '^[A-Za-z0-9.-]{1,253}$'-or $DatabaseName-cnotmatch '^[A-Za-z0-9_]{1,64}$'-or
       $EvidenceSha256-cnotmatch '^[a-f0-9]{64}$'-or $ExpiresAtUtc-cnotmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$'){throw 'Invalid target'}
    $python=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.venv/Scripts/python.exe'))
    $entry=Join-Path $PSScriptRoot 'manage_account_privileges_secure.py'
    foreach($path in @($python,$entry,$TlsCaFile)){
        if($path-cnotmatch '^[A-Za-z]:[\\/][^:]*$'-or $path.Contains('"')-or -not [IO.File]::Exists($path)){throw 'Unavailable input'}
        for($check=$path;$check;){
            if((Get-Item -LiteralPath $check -Force).Attributes-band [IO.FileAttributes]::ReparsePoint){throw 'Redirected input'}
            $parent=Split-Path $check -Parent;if($parent-eq $check){break};$check=$parent
        }
    }
    Add-Type -AssemblyName System.Windows.Forms
    $form=[Windows.Forms.Form]::new();$form.ClientSize=[Drawing.Size]::new(860,450)
    $form.Text=$(if($Apply){'账号权益受控授予'}else{'账号权益只读计划核对'})
    $form.StartPosition='CenterScreen';$form.FormBorderStyle='FixedDialog';$form.MaximizeBox=$false
    $notice=[Windows.Forms.Label]::new()
    $notice.Text="数据库：$DatabaseHost :$DatabasePort / $DatabaseName`r`n账号ID：$AccountId；权益：$Privilege；审计grant：$GrantId`r`n手机号只经私有stdin验证已认证归属，不进入参数/日志。默认只读；不迁移、不发送短信、不调用模型。"
    $notice.SetBounds(16,12,828,96);$form.Controls.Add($notice)
    $fields=@(@('phone','账号已验证手机号（+国家码）'),@('resume_web','resume_web 密码'),@('resume_maint','resume_maint 密码（仅授予时）'))
    for($i=0;$i-lt $fields.Count;$i++){
        $label=[Windows.Forms.Label]::new();$label.Text=$fields[$i][1];$label.SetBounds(16,122+54*$i,250,30)
        $box=[Windows.Forms.TextBox]::new();$box.SetBounds(270,118+54*$i,570,32);$box.MaxLength=4096
        $box.UseSystemPasswordChar=($i-gt 0);$box.Enabled=($i-ne 2-or $Apply)
        $boxes[$fields[$i][0]]=$box;$form.Controls.AddRange(@($label,$box))
    }
    $confirmation=[Windows.Forms.CheckBox]::new();$confirmation.SetBounds(16,294,828,44)
    $confirmation.Text='已核真实账号ID、手机号归属、权益与审计证据；批准这一项授予，不迁移或重置旧授权'
    $confirmation.Visible=[bool]$Apply;$form.Controls.Add($confirmation)
    $warning=[Windows.Forms.Label]::new();$warning.SetBounds(16,346,828,32)
    $warning.Text='结果未知只做相同grant的只读核对；不自动重发或换grant ID。管理员和永久会员分别验收。'
    $form.Controls.Add($warning)
    $confirm=[Windows.Forms.Button]::new();$confirm.Text=$(if($Apply){'授予并独立回读'}else{'只读核对'})
    $confirm.SetBounds(520,394,160,36);$confirm.DialogResult=[Windows.Forms.DialogResult]::OK;$confirm.Enabled=(-not $Apply)
    $confirmation.Add_CheckedChanged({$confirm.Enabled=$confirmation.Checked})
    $cancel=[Windows.Forms.Button]::new();$cancel.Text='取消';$cancel.SetBounds(694,394,146,36);$cancel.DialogResult=[Windows.Forms.DialogResult]::Cancel
    $form.Controls.AddRange(@($confirm,$cancel));$form.AcceptButton=$confirm;$form.CancelButton=$cancel
    if($form.ShowDialog()-ne [Windows.Forms.DialogResult]::OK){Write-Output '{"status":"cancelled","writeRequested":false}';exit 0}
    if($Apply-and -not $confirmation.Checked){throw 'Explicit confirmation required'}
    $payload=[ordered]@{phone=$boxes.phone.Text;resume_web=$boxes.resume_web.Text}
    if($Apply){$payload['resume_maint']=$boxes.resume_maint.Text}
    foreach($value in $payload.Values){if(-not $value){throw 'Missing input'}}
    $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=$python
    $start.Arguments='-X utf8 -I -B "'+$entry+'" --host '+$DatabaseHost+' --port '+$DatabasePort+' --database '+$DatabaseName+' --ca-file "'+$TlsCaFile+'" --expires-at-utc '+$ExpiresAtUtc+' --account-id '+$AccountId+' --grant-id '+$GrantId+' --privilege '+$Privilege+' --operator-id '+$OperatorId+' --evidence-sha256 '+$EvidenceSha256
    if($Apply){$start.Arguments+=' --apply --confirmed-grant'}
    $start.UseShellExecute=$false;$start.CreateNoWindow=$true
    $start.RedirectStandardInput=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    $start.StandardOutputEncoding=[Text.UTF8Encoding]::new($false);$start.StandardErrorEncoding=[Text.UTF8Encoding]::new($false)
    foreach($key in @($start.EnvironmentVariables.Keys)){if($key-match '^(AGENT_GATEWAY_|GATEWAY_|PYTHON)'){$start.EnvironmentVariables.Remove($key)}}
    $process=[Diagnostics.Process]::Start($start)
    $stdoutTask=$process.StandardOutput.ReadToEndAsync();$stderrTask=$process.StandardError.ReadToEndAsync()
    $serialized=ConvertTo-Json -InputObject $payload -Compress;$encoded=[Text.Encoding]::UTF8.GetBytes($serialized)
    $process.StandardInput.BaseStream.Write($encoded,0,$encoded.Length);$process.StandardInput.Close()
    [Array]::Clear($encoded,0,$encoded.Length);$payload.Clear();$serialized=$null
    foreach($box in $boxes.Values){$box.Clear()}
    if(-not $process.WaitForExit(180000)){$process.Kill();throw 'Outcome unknown'}
    $stdout=[string]$stdoutTask.GetAwaiter().GetResult();$stderr=[string]$stderrTask.GetAwaiter().GetResult()
    if($stderr-or $stdout.Length-gt 8192){throw 'Unexpected output'}
    $result=ConvertFrom-Json $stdout
    if($result.status-notin @('privilege_plan','privilege_verified','outcome_unknown','privilege_check_failed','privilege_arguments_invalid')){throw 'Unexpected result'}
    Write-Output $stdout
    $summary='状态：'+$result.status
    if($result.status-in @('privilege_plan','privilege_verified')){$summary+="`r`n相同grant已核：$($result.matchingGrantVerified)`r`n角色：$($result.role)；会员：$($result.membership)"}
    else{
        if($result.failureStage-cmatch '^[a-z_]{1,64}$'){$summary+="`r`n失败阶段：$($result.failureStage)"}
        if($result.failureCategory-cmatch '^[a-z_]{1,64}$'){$summary+="`r`n原因类别：$($result.failureCategory)"}
        $summary+="`r`n仅做相同grant只读核对，不重复提交。"
    }
    [void][Windows.Forms.MessageBox]::Show($summary,'账号权益结果')
    exit $process.ExitCode
}catch{
    Write-Output '{"status":"privilege_window_stopped","retryable":false,"next":"read_only_same_grant_check"}'
    exit 1
}finally{
    foreach($box in $boxes.Values){$box.Clear()}
    if($encoded){[Array]::Clear($encoded,0,$encoded.Length)}
    if($payload){$payload.Clear()};$serialized=$null
    if($form){$form.Dispose()}
    if($process){
        try{$process.StandardInput.Close()}catch{}
        try{if(-not $process.HasExited){$process.Kill();[void]$process.WaitForExit(5000)}}catch{}
        $process.Dispose()
    }
}
