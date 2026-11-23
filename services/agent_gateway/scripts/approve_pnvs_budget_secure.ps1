# Plain Windows PS 5.1 GUI; credentials only enter a private stdin pipe.
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$DatabaseHost,
    [ValidateRange(1,65535)][int]$DatabasePort=3306,
    [Parameter(Mandatory=$true)][string]$DatabaseName,
    [Parameter(Mandatory=$true)][string]$TlsCaFile,
    [Parameter(Mandatory=$true)][string]$ExpiresAtUtc,
    [Parameter(Mandatory=$true)][string]$EncryptedRuntimePath,
    [switch]$Apply
)
$ErrorActionPreference='Stop'
$form=$null;$process=$null;$boxes=@{};$payload=$null;$serialized=$null;$encoded=$null
try {
    if([Threading.Thread]::CurrentThread.ApartmentState-ne 'STA'){throw 'STA required'}
    if($DatabaseHost-cnotmatch '^[A-Za-z0-9.-]{1,253}$'-or
       $DatabaseName-cnotmatch '^[A-Za-z0-9_]{1,64}$'-or
       $ExpiresAtUtc-cnotmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$'){throw 'Invalid target'}
    $python=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.venv/Scripts/python.exe'))
    $entry=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'approve_pnvs_budget_secure.py'))
    foreach($path in @($TlsCaFile,$EncryptedRuntimePath)){
        if($path-cnotmatch '^[A-Za-z]:[\\/][^:]*$'){throw 'Ordinary absolute path required'}
    }
    $ca=[IO.Path]::GetFullPath($TlsCaFile)
    $runtime=[IO.Path]::GetFullPath($EncryptedRuntimePath)
    foreach($path in @($python,$entry,$ca,$runtime)){
        if(-not [IO.File]::Exists($path)-or $path.Contains('"')){throw 'Unavailable input'}
        for($check=$path;$check;){
            if((Get-Item -LiteralPath $check -Force).Attributes-band [IO.FileAttributes]::ReparsePoint){throw 'Redirected input'}
            $parent=Split-Path $check -Parent;if($parent-eq $check){break};$check=$parent
        }
    }
    Add-Type -AssemblyName System.Windows.Forms
    $form=[Windows.Forms.Form]::new()
    $form.Text=$(if($Apply){'PNVS 首次预算批准'}else{'PNVS 预算只读检查'})
    $form.ClientSize=[Drawing.Size]::new(820,390)
    $form.StartPosition='CenterScreen';$form.FormBorderStyle='FixedDialog';$form.MaximizeBox=$false
    $notice=[Windows.Forms.Label]::new()
    $notice.Text="目标：$DatabaseHost :$DatabasePort / $DatabaseName`r`n请使用保存 PNVS 运行密文的同一普通 Windows 用户。默认只读，不读取 AccessKey，不发短信、不调用模型。密码不保存，不放参数或环境。"
    if($Apply){$notice.Text+="`r`n仅首次建立已审政策；不重置次数、费用或秘密。请先完成默认只读检查。"}
    $notice.SetBounds(16,12,788,96);$form.Controls.Add($notice)
    $accounts=@('resume_web','resume_maint')
    for($i=0;$i-lt $accounts.Count;$i++){
        $label=[Windows.Forms.Label]::new();$label.Text=$accounts[$i]+' 密码';$label.SetBounds(16,116+54*$i,240,28)
        $box=[Windows.Forms.TextBox]::new();$box.SetBounds(260,112+54*$i,540,32)
        $box.UseSystemPasswordChar=$true;$box.MaxLength=4096;$box.Enabled=($i-eq 0-or $Apply)
        $boxes[$accounts[$i]]=$box;$form.Controls.AddRange(@($label,$box))
    }
    $confirmation=[Windows.Forms.CheckBox]::new()
    $confirmation.Text='已核对政策白名单、次数、整数分预算与到期；批准首次建立，不重置已使用额度'
    $confirmation.SetBounds(16,232,788,38);$confirmation.Visible=[bool]$Apply;$form.Controls.Add($confirmation)
    $warning=[Windows.Forms.Label]::new();$warning.Text='若失败或提交结果未知，请只读检查，不重复批准。';$warning.SetBounds(16,278,788,28);$form.Controls.Add($warning)
    $confirm=[Windows.Forms.Button]::new();$confirm.Text=$(if($Apply){'批准并复核'}else{'只读检查'})
    $confirm.SetBounds(510,334,140,36);$confirm.Enabled=(-not $Apply);$confirm.DialogResult=[Windows.Forms.DialogResult]::OK
    $confirmation.Add_CheckedChanged({$confirm.Enabled=$confirmation.Checked})
    $cancel=[Windows.Forms.Button]::new();$cancel.Text='取消';$cancel.SetBounds(660,334,140,36);$cancel.DialogResult=[Windows.Forms.DialogResult]::Cancel
    $form.Controls.AddRange(@($confirm,$cancel));$form.AcceptButton=$confirm;$form.CancelButton=$cancel
    if($form.ShowDialog()-ne [Windows.Forms.DialogResult]::OK){Write-Output '{"status":"cancelled","writeRequested":false}';exit 0}
    if($Apply-and -not $confirmation.Checked){throw 'Approval confirmation required'}
    $payload=[ordered]@{}
    foreach($account in $(if($Apply){$accounts}else{@('resume_web')})){
        if(-not $boxes[$account].Text){throw 'Missing password'}
        $payload[$account]=$boxes[$account].Text
    }
    $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=$python
    $start.Arguments='-X utf8 -I -B "'+$entry+'" --host '+$DatabaseHost+' --port '+$DatabasePort+' --database '+$DatabaseName+' --ca-file "'+$ca+'" --expires-at-utc '+$ExpiresAtUtc+' --encrypted-runtime-path "'+$runtime+'"'
    if($Apply){$start.Arguments+=' --apply-approved-budget --confirmed-policy-approval'}
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
    if(-not $process.WaitForExit(180000)){$process.Kill();throw 'Budget operation timed out'}
    $stdout=[string]$stdoutTask.GetAwaiter().GetResult();$stderr=[string]$stderrTask.GetAwaiter().GetResult()
    if($stderr-or $stdout.Length-gt 65536){throw 'Unexpected diagnostic output'}
    $result=ConvertFrom-Json $stdout
    if($result.status-notin @('approved_policy_verified','policy_not_approved','outcome_unknown','budget_check_failed','budget_arguments_invalid','unsupported_mysql_version')){throw 'Unexpected result'}
    Write-Output $stdout
    $summary='状态：'+$result.status
    if($result.status-eq 'approved_policy_verified'){
        $summary+="`r`n政策到期 UTC：$($result.expiresAtUtc)；已到期：$($result.expired)`r`n次数已用/剩余：$($result.attemptsUsed) / $($result.attemptsRemaining)`r`n预算已预留/剩余（分）：$($result.reservedCents) / $($result.budgetRemainingCents)"
    }elseif($result.status-eq 'policy_not_approved'){
        $summary+="`r`n尚未批准；最多 $($result.maximumAttempts) 次，总预算 $($result.budgetCents) 分，每次预留 $($result.reservePerAttemptCents) 分。`r`n政策到期 UTC：$($result.expiresAtUtc)；已到期：$($result.expired)"
    }elseif($result.status-eq 'unsupported_mysql_version'){
        $summary+="`r`n需要真实 MySQL 8.0.22 及以上；本次未批准预算。请只读核查，不重复批准。"
    }else{$summary+="`r`n请只读核查，不重复批准。"}
    [void][Windows.Forms.MessageBox]::Show($summary,'PNVS 预算结果')
    # CLI exit 1 deliberately blocks unattended startup when policy is unapproved.
    # A successful read-only GUI inspection may report that expected state normally.
    if(-not $Apply-and $result.status-eq 'policy_not_approved'-and $process.ExitCode-eq 1){exit 0}
    exit $process.ExitCode
} catch {
    Write-Output '{"status":"budget_window_failed","retryable":false,"next":"read_only_check"}'
    exit 1
} finally {
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
