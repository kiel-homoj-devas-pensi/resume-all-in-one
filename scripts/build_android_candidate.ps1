[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][ValidateSet('Offline','Online')][string]$CandidateKind,
    [Parameter(Mandatory=$true)][ValidateRange(1,2147483647)][int]$BuildNumber,
    [Parameter(Mandatory=$true)][string]$BuildName,
    [Parameter(Mandatory=$true)][string]$OutputDirectory,
    [string]$GatewayBaseUrl,
    [string]$FlutterExecutable = 'flutter'
)
$ErrorActionPreference = 'Stop'
$clientRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../apps/client'))

function Read-EndpointJson([Uri]$Address) {
    Add-Type -AssemblyName System.Net.Http
    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $http = [Net.Http.HttpClient]::new($handler)
    $http.Timeout = [TimeSpan]::FromSeconds(30)
    $response = $null
    $stream = $null
    $body = [IO.MemoryStream]::new()
    try {
        $response = $http.GetAsync($Address, [Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        if (-not $response.IsSuccessStatusCode) { throw 'Online endpoint did not return success.' }
        $stream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $buffer = [byte[]]::new(4096)
        while (($count = $stream.Read($buffer,0,$buffer.Length)) -gt 0) {
            if ($body.Length + $count -gt 32768) { throw 'Online endpoint response exceeded 32 KiB.' }
            $body.Write($buffer,0,$count)
        }
        return [Text.Encoding]::UTF8.GetString($body.ToArray()) | ConvertFrom-Json
    } finally {
        if ($stream) { $stream.Dispose() }
        if ($response) { $response.Dispose() }
        $body.Dispose(); $http.Dispose(); $handler.Dispose()
    }
}

$readinessVerified = $false
if ($CandidateKind -eq 'Online') {
    $gatewayUri = $null
    if (-not [Uri]::TryCreate($GatewayBaseUrl,[UriKind]::Absolute,[ref]$gatewayUri) -or
        $gatewayUri.Scheme -ne 'https' -or $gatewayUri.UserInfo -or $gatewayUri.Query -or
        $gatewayUri.Fragment -or $gatewayUri.AbsolutePath -ne '/') {
        throw 'Online candidate requires an explicit HTTPS Gateway root URL, without credentials, query or fragment.'
    }
    $ready = Read-EndpointJson ([Uri]::new($gatewayUri,'/health/ready'))
    if ($ready.status -ne 'ready') { throw 'Gateway is not ready; no online APK will be built.' }
    $options = Read-EndpointJson ([Uri]::new($gatewayUri,'/v2/account/options?features=recoveryCodes'))
    if ($options.protocolVersion -ne '0.5.0' -or
        $options.developmentSms -isnot [bool] -or $options.developmentSms -ne $false -or
        $options.persistentLogin -isnot [bool] -or $options.persistentLogin -ne $false) {
        throw 'Online candidate requires the actual verification service, not development SMS.'
    }
    if ($options.recoveryCodes -isnot [bool] -or $options.recoveryCodes -ne $true) {
        throw 'Online candidate requires the deployed recovery-code contract; update and verify the server first.'
    }
    $resultRecovery = Read-EndpointJson ([Uri]::new($gatewayUri,'/v1/resume-ai/recovery-options'))
    if ($resultRecovery.protocolVersion -ne '0.1.0' -or
        $resultRecovery.enabled -isnot [bool] -or $resultRecovery.enabled -ne $true -or
        $resultRecovery.resultRetentionSeconds -ne 86400) {
        throw 'Online candidate requires protected original-result recovery; deploy and verify the server first.'
    }
    $readinessVerified = $true
} elseif (-not [string]::IsNullOrWhiteSpace($GatewayBaseUrl)) {
    throw 'Offline candidates cannot silently include a Gateway URL; choose Online explicitly.'
}
if (-not [IO.Path]::IsPathRooted($OutputDirectory)) { throw 'OutputDirectory must be absolute.' }
$outputRoot = [IO.Path]::GetFullPath($OutputDirectory)
$apkName = 'resume-' + $CandidateKind.ToLowerInvariant() + '-code' + $BuildNumber + '.apk'
$destination = Join-Path $outputRoot $apkName
$bindingPath = Join-Path $outputRoot ($apkName + '.json')
if ([IO.File]::Exists($destination) -or [IO.File]::Exists($bindingPath)) { throw 'Candidate already exists; do not overwrite a previous result.' }

$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
function Get-SourceBinding {
    $items = [ordered]@{}
    $paths = @((Join-Path $clientRoot 'lib'), (Join-Path $clientRoot 'android/app/src/main'))
    # Legal text is a runtime asset and must be frozen with the APK's code.
    if ([IO.Directory]::Exists((Join-Path $clientRoot 'assets'))) { $paths += Join-Path $clientRoot 'assets' }
    foreach ($package in Get-ChildItem (Join-Path $repositoryRoot 'packages') -Directory) { $paths += Join-Path $package.FullName 'lib' }
    $sourceFiles = foreach ($path in $paths) { Get-ChildItem -LiteralPath $path -File -Recurse }
    $sourceFiles += Get-ChildItem -LiteralPath $clientRoot -File | Where-Object { $_.Name -in @('pubspec.yaml','pubspec.lock') }
    foreach ($package in Get-ChildItem (Join-Path $repositoryRoot 'packages') -Directory) {
        $sourceFiles += Get-ChildItem -LiteralPath $package.FullName -File | Where-Object { $_.Name -in @('pubspec.yaml','pubspec.lock') }
    }
    foreach ($file in $sourceFiles | Sort-Object FullName -Unique) {
        $relative = $file.FullName.Substring($repositoryRoot.Length+1).Replace('\','/')
        $items[$relative] = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    }
    return $items
}
$before = Get-SourceBinding
$arguments = @('build','apk','--release','--no-pub',('--build-number='+$BuildNumber),('--build-name='+$BuildName))
if ($CandidateKind -eq 'Online') { $arguments += '--dart-define=AGENT_GATEWAY_BASE_URL=' + $gatewayUri.AbsoluteUri }
Push-Location $clientRoot
try {
    & $FlutterExecutable @arguments
    if ($LASTEXITCODE -ne 0) { throw 'Flutter build failed; no candidate is published.' }
} finally { Pop-Location }
$after = Get-SourceBinding
if (($before | ConvertTo-Json -Compress) -ne ($after | ConvertTo-Json -Compress)) { throw 'Source changed during build; do not publish this candidate.' }
$apkPath = Join-Path $clientRoot 'build/app/outputs/flutter-apk/app-release.apk'
if (-not [IO.File]::Exists($apkPath)) { throw 'Flutter APK output is missing.' }
New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null
[IO.File]::Copy($apkPath,$destination,$false)
$head = & git -C $repositoryRoot rev-parse HEAD
$binding = [ordered]@{
    candidateKind=$CandidateKind; versionName=$BuildName; versionCode=$BuildNumber
    gatewayBaseUrl=if($CandidateKind -eq 'Online'){$gatewayUri.AbsoluteUri}else{$null}
    gatewayReadyAndRealSmsOptionsVerified=$readinessVerified
    originalResultRecoveryVerified=($CandidateKind -eq 'Online' -and $readinessVerified)
    realPhoneAuthenticationAccepted=$false; realMembershipAccepted=$false; realAiAccepted=$false
    apkSha256=(Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
    signing='Requires independent signature verification; may be unsigned'
    gitBaseRevision=$head; actualSourceFiles=$after; builtAtUtc=[DateTime]::UtcNow.ToString('o')
}
$binding | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $bindingPath -Encoding UTF8
Write-Output ('Candidate: '+$destination)
