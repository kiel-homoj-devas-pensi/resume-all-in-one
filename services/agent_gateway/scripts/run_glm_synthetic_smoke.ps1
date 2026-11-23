param(
    [Parameter(Mandatory=$true)][string]$EncryptedKeyPath,
    [Parameter(Mandatory=$true)][string]$ReportPath,
    [ValidateRange(1,3)][int]$MaxCalls=3,
    [ValidateSet('basicResumeCompose','targetedResumeOptimization','resumeOptimizationConversation')][string]$Capability,
    [ValidateRange(1,180)][int]$TimeoutSeconds=45,
    [Parameter(Mandatory=$true)][decimal]$BudgetCny
)
$ErrorActionPreference = 'Stop'
if ($BudgetCny -lt 2 -or $BudgetCny -gt 40) { throw '本批仅允许已批准的 2–40 元合成预算，最多三次；不可追加重试' }
$oldKey = $env:AGENT_GATEWAY_GLM_API_KEY
$oldPythonPath = $env:PYTHONPATH
$secret = $null
try {
    $encryptedText = (Get-Content -LiteralPath $EncryptedKeyPath -Raw).Trim()
    $secret = ConvertTo-SecureString -String $encryptedText
    $env:AGENT_GATEWAY_GLM_API_KEY = [Net.NetworkCredential]::new('', $secret).Password
    $env:PYTHONPATH = Join-Path $PSScriptRoot '../src'
    $selection = @('--timeout-seconds', $TimeoutSeconds)
    if ($Capability) { $selection += @('--capability', $Capability) }
    & (Join-Path $PSScriptRoot '../.venv/Scripts/python.exe') (Join-Path $PSScriptRoot 'run_glm_synthetic_smoke.py') --allow-paid-synthetic --confirmed-model-api-price --max-calls $MaxCalls --report $ReportPath @selection
    if ($LASTEXITCODE -ne 0) { throw '合成验收未全部通过；没有自动重试，请核对脱敏报告和实际账单' }
} finally {
    $env:AGENT_GATEWAY_GLM_API_KEY = $oldKey
    $env:PYTHONPATH = $oldPythonPath
    if ($null -ne $secret) { $secret.Dispose() }
}
