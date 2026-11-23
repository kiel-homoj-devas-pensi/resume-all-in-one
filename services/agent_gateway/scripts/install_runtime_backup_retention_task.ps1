# Explicit deployment template. Run only after reviewing the root ACL and dry-run
# report, with authorization to install this persistent task on the target host.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$PythonExe,
    [Parameter(Mandatory = $true)][string]$GatewayRoot,
    [Parameter(Mandatory = $true)][string]$BackupRoot,
    [switch]$Apply
)
$ErrorActionPreference = 'Stop'

function Assert-LocalUnredirectedPath([string]$Value) {
    if ($Value.Length -lt 3 -or -not [System.IO.Path]::IsPathRooted($Value) -or $Value.StartsWith('\\') -or
        $Value.Contains('"') -or $Value.Substring(2).Contains(':')) {
        throw 'backup_path_invalid'
    }
    if ([System.IO.Path]::GetFullPath($Value) -ne $Value) { throw 'backup_path_invalid' }
    $item = Get-Item -LiteralPath $Value -Force
    while ($null -ne $item) {
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'backup_path_invalid'
        }
        if ($item -is [System.IO.FileInfo]) { $item = $item.Directory }
        else { $item = $item.Parent }
    }
}

Assert-LocalUnredirectedPath $PythonExe
Assert-LocalUnredirectedPath $GatewayRoot
Assert-LocalUnredirectedPath $BackupRoot
$runner = Join-Path $GatewayRoot 'scripts\manage_runtime_backups.py'
Assert-LocalUnredirectedPath $runner
if (-not (Test-Path -LiteralPath (Join-Path $BackupRoot 'registry.json') -PathType Leaf)) {
    throw 'backup_registry_invalid'
}

# The interpreter must have this exact gateway package installed (editable or
# regular installation). No global PYTHONPATH or gateway startup action changes.
& $PythonExe $runner cleanup --root $BackupRoot --look-ahead-seconds 300
if ($LASTEXITCODE -ne 0) { throw 'backup_dry_run_requires_review' }

$taskName = 'ResumeGateway-ManagedRuntimeBackupRetention'
$arguments = '"' + $runner + '" cleanup --root "' + $BackupRoot +
    '" --look-ahead-seconds 300 --apply'
$action = New-ScheduledTaskAction -Execute $PythonExe -Argument $arguments -WorkingDirectory $GatewayRoot
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
    -RepetitionInterval (New-TimeSpan -Minutes 5)
$identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
# S4U needs local batch-logon rights but no stored password or network access.
# This must be the reviewed operator identity with access to this private root.
$principal = New-ScheduledTaskPrincipal -UserId $identity -LogonType S4U -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 4) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
$description = 'Delete only registered local runtime snapshots within seven days; 5-minute early window. Monitor failures/overdue and host clock. Does not govern old snapshots or vendor backups.'

if (-not $Apply) {
    Write-Output 'Reviewed template only: no task installed. Re-run with -Apply after deployment approval.'
    return
}
if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
    throw 'backup_retention_task_exists_review_before_update'
}
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
    -Settings $settings -Principal $principal -Description $description | Out-Null
Write-Output 'Task installed. Verify TaskLastResult, task history and a separate synthetic seven-day boundary exercise before claiming enforcement.'
