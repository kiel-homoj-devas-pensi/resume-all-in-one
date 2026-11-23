[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$EncryptedStartupPath, [switch]$CheckOnly)
$ErrorActionPreference = 'Stop'
$previousPythonPath = $env:PYTHONPATH
try {
    $python = Join-Path $PSScriptRoot '../.venv/Scripts/python.exe'
    if (-not [IO.File]::Exists($python)) { throw 'Runtime unavailable.' }
    Push-Location (Join-Path $PSScriptRoot '..')
    try {
        # Fixed release source path, no secret environment variables.
        $env:PYTHONPATH = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../src'))
        $launchArguments = @('-B','-s','-P','-m','agent_gateway.protected_startup','--configuration',$EncryptedStartupPath)
        if ($CheckOnly) { $launchArguments += '--check-only' }
        & $python @launchArguments
        $result = $LASTEXITCODE
    } finally { $env:PYTHONPATH = $previousPythonPath; Pop-Location }
    exit $result
} catch {
    Write-Output 'Protected Gateway startup unavailable; verify runtime and release layout.'
    exit 1
}
