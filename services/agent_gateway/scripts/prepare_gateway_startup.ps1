# CLI accepts only encrypted path and optional non-secret database target.
[CmdletBinding(DefaultParameterSetName='Dsn')]
param(
    [Parameter(Mandatory=$true)][string]$EncryptedStartupPath,
    [switch]$VerifyOnly,
    [Parameter(Mandatory=$true,ParameterSetName='Password')][string]$DatabaseHost,
    [Parameter(ParameterSetName='Password')][ValidateRange(1,65535)][int]$DatabasePort=3306,
    [Parameter(Mandatory=$true,ParameterSetName='Password')][string]$DatabaseName,
    [Parameter(Mandatory=$true,ParameterSetName='Password')][string]$DatabaseUser,
    [string]$DatabaseTlsCaFile,
    # Compatibility argument for old launch commands; production has no trial expiry.
    [string]$DatabaseExpiresAtUtc,
    [string]$PnvsCredentialsPath,
    [string]$PnvsRuntimePath
)
$ErrorActionPreference = 'Stop'
$window = $null
$boxes = @{}
$secure = $null
$bundle = $null
$plain = $null
$passwordMode = ($PSCmdlet.ParameterSetName -eq 'Password')

function Get-StartupDatabaseDsn {
    param([string]$Password)
    $process = $null
    $payload = $null
    $serialized = $null
    $encoded = $null
    $stdout = $null
    $result = $null
    try {
        $python = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.venv/Scripts/python.exe'))
        $entry = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'build_startup_database_dsn.py'))
        foreach ($path in @($python,$entry)) {
            if (-not [IO.File]::Exists($path) -or $path.Contains('"')) { throw 'Runtime unavailable.' }
            for ($check=$path; $check;) {
                if ((Get-Item -LiteralPath $check -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
                    throw 'Redirected runtime.'
                }
                $parent = Split-Path $check -Parent
                if ($parent -eq $check) { break }
                $check = $parent
            }
        }
        $start = [Diagnostics.ProcessStartInfo]::new()
        $start.FileName = $python
        $start.Arguments = '-X utf8 -I -B "'+$entry+'"'
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $start.RedirectStandardInput = $true
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        $start.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
        $start.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
        foreach ($key in @($start.EnvironmentVariables.Keys)) {
            if ($key -match '^(AGENT_GATEWAY_|GATEWAY_|PYTHON)') { $start.EnvironmentVariables.Remove($key) }
        }
        $process = [Diagnostics.Process]::Start($start)
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $payload = [ordered]@{host=$DatabaseHost;port=$DatabasePort;database=$DatabaseName;user=$DatabaseUser;password=$Password}
        $serialized = ConvertTo-Json -InputObject $payload -Compress
        $encoded = [Text.Encoding]::UTF8.GetBytes($serialized)
        # Explicit UTF-8 private pipe avoids PS 5.1 console encoding differences.
        $process.StandardInput.BaseStream.Write($encoded,0,$encoded.Length)
        $process.StandardInput.Close()
        [Array]::Clear($encoded,0,$encoded.Length)
        $payload.Clear(); $serialized=$null; $Password=$null
        if (-not $process.WaitForExit(10000)) { $process.Kill(); throw 'Encoding timed out.' }
        $stdout = [string]$stdoutTask.GetAwaiter().GetResult()
        $stderr = [string]$stderrTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0 -or $stderr -or $stdout.Length -gt 24576) { throw 'Encoding failed.' }
        $result = ConvertFrom-Json $stdout
        if (@($result.PSObject.Properties.Name).Count -ne 1 -or
            $result.businessDatabaseDsn -isnot [string]) { throw 'Invalid encoding result.' }
        return $result.businessDatabaseDsn
    } catch {
        throw 'Startup database encoding unavailable.'
    } finally {
        if ($encoded) { [Array]::Clear($encoded,0,$encoded.Length) }
        if ($payload) { $payload.Clear() }
        $serialized=$null; $Password=$null; $stdout=$null; $result=$null
        if ($process) {
            try { $process.StandardInput.Close() } catch {}
            try { if (-not $process.HasExited) { $process.Kill(); [void]$process.WaitForExit(5000) } } catch {}
            $process.Dispose()
        }
    }
}
try {
    Import-Module (Join-Path $PSScriptRoot 'GatewayStartupSettings.psm1') -Force
    if ($VerifyOnly) {
        Test-GatewayStartupSettings -Path $EncryptedStartupPath
        exit 0
    }
    if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { throw 'STA required.' }
    if ($passwordMode -and ($DatabaseHost -cnotmatch '^[A-Za-z0-9.-]{1,253}$' -or
        $DatabaseName -cnotmatch '^[A-Za-z0-9_]{1,64}$' -or
        $DatabaseUser -cnotmatch '^[A-Za-z0-9_.-]{1,64}$')) { throw 'Invalid database target.' }
    Add-Type -AssemblyName System.Windows.Forms
    $window = [Windows.Forms.Form]::new()
    $window.Text = 'Gateway 生产配置安全录入'
    $window.ClientSize = [Drawing.Size]::new(760, 400)
    $window.StartPosition = 'CenterScreen'
    $window.FormBorderStyle = 'FixedDialog'
    $window.MaximizeBox = $false
    $window.MinimizeBox = $false
    $notice = [Windows.Forms.Label]::new()
    $notice.Text = '请在云机使用将来运行服务的同一用户录入。只能填写业务账号 DSN，禁止填写管理员/迁移 DSN。保存不连接数据库、不发短信、不调用模型。'
    if ($passwordMode) {
        $notice.Text = "业务目标：$DatabaseUser @ $DatabaseHost :$DatabasePort / $DatabaseName。请使用将来运行服务的同一用户录入。密码自动编码；保存不联网，不发短信、不调用模型。"
    }
    $notice.SetBounds(16, 12, 720, 40)
    $window.Controls.Add($notice)
    $fields = @(
        @('glmApiKey', '模型 API Key（遮罩）'),
        @('businessDatabaseDsn', 'MySQL 业务账号 DSN（遮罩）'),
        @('databaseTlsCaFile', 'TLS CA 文件绝对路径'),
        @('pnvsCredentialsPath', 'PNVS 凭据 DPAPI 文件路径'),
        @('pnvsRuntimePath', 'PNVS 运行 DPAPI 文件路径'))
    # Deployment may prefill public references; credentials always start empty.
    $publicReferences = @{
        databaseTlsCaFile=$DatabaseTlsCaFile
        pnvsCredentialsPath=$PnvsCredentialsPath
        pnvsRuntimePath=$PnvsRuntimePath
    }
    if ($passwordMode) { $fields[1] = @('businessDatabaseDsn','MySQL 业务账号密码（遮罩）') }
    for ($i = 0; $i -lt $fields.Count; $i++) {
        $label = [Windows.Forms.Label]::new()
        $label.Text = $fields[$i][1]
        $label.SetBounds(16, 63 + 44 * $i, 240, 26)
        $box = [Windows.Forms.TextBox]::new()
        $box.SetBounds(260, 60 + 44 * $i, 480, 28)
        $box.UseSystemPasswordChar = ($i -lt 2)
        $box.MaxLength = 4096
        if ($publicReferences.ContainsKey($fields[$i][0])) {
            $box.Text = [string]$publicReferences[$fields[$i][0]]
        }
        $boxes[$fields[$i][0]] = $box
        $window.Controls.AddRange(@($label, $box))
    }
    $save = [Windows.Forms.Button]::new()
    $save.Text = '加密保存'
    $save.SetBounds(460, 344, 140, 32)
    $save.DialogResult = [Windows.Forms.DialogResult]::OK
    $cancel = [Windows.Forms.Button]::new()
    $cancel.Text = '取消'
    $cancel.SetBounds(610, 344, 130, 32)
    $cancel.DialogResult = [Windows.Forms.DialogResult]::Cancel
    $window.Controls.AddRange(@($save, $cancel))
    $window.AcceptButton = $save
    $window.CancelButton = $cancel
    if ($window.ShowDialog() -ne [Windows.Forms.DialogResult]::OK) {
        Write-Output 'Cancelled; no configuration saved.'
        exit 0
    }
    $bundle = [ordered]@{ schemaVersion = 2 }
    foreach ($field in $fields) {
        if ($passwordMode -and $field[0] -eq 'businessDatabaseDsn') {
            $bundle[$field[0]] = Get-StartupDatabaseDsn -Password $boxes[$field[0]].Text
        } else { $bundle[$field[0]] = $boxes[$field[0]].Text.Trim() }
    }
    $plain = ConvertTo-Json -InputObject $bundle -Compress
    $secure = ConvertTo-SecureString $plain -AsPlainText -Force
    foreach ($box in $boxes.Values) { $box.Clear() }
    Save-GatewayStartupSettings -Path $EncryptedStartupPath -Payload $secure
    Write-Output 'Encrypted configuration saved for current Windows user and SYSTEM only.'
    Write-Output 'Verify with Python --check-only before starting; no service, migration or external call executed.'
} catch {
    Write-Output 'Gateway configuration not saved/verified; check identity, permissions, references and input.'
    exit 1
} finally {
    foreach ($box in $boxes.Values) { $box.Clear() }
    if ($window) { $window.Dispose() }
    if ($secure) { $secure.Dispose() }
    $plain = $null
    $bundle = $null
}
