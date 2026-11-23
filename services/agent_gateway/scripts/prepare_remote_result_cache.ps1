[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$ResultDirectory,
    [string]$ServiceSid,
    [switch]$VerifyOnly
)
$ErrorActionPreference='Stop'
$raw=$ResultDirectory
if($raw-notmatch '^[A-Za-z]:[\\/]' -or $raw.Substring(2).Contains(':')){throw 'Local result directory required.'}
$target=[IO.Path]::GetFullPath($raw).TrimEnd('\')
$repository=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..')).TrimEnd('\')
if($target.Length-le 3-or $target.StartsWith($repository+'\',[StringComparison]::OrdinalIgnoreCase)){
    throw 'External result directory required.'
}
for($candidate=$target;$candidate;){
    if((Test-Path -LiteralPath $candidate)-and ((Get-Item -LiteralPath $candidate -Force).Attributes-band [IO.FileAttributes]::ReparsePoint)){
        throw 'Redirected result directory refused.'
    }
    $parent=Split-Path -Parent $candidate
    if($parent-eq $candidate){break}
    $candidate=$parent
}
$current=[Security.Principal.WindowsIdentity]::GetCurrent()
if(!$ServiceSid){$ServiceSid=$current.User.Value}
$runtime=New-Object Security.Principal.SecurityIdentifier($ServiceSid)
if($runtime.Value-in @('S-1-5-18','S-1-5-32-544')){throw 'A dedicated runtime user SID is required.'}
$expected=New-Object Security.AccessControl.DirectorySecurity
$expected.SetAccessRuleProtection($true,$false)
$administrators=New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')
$principal=New-Object Security.Principal.WindowsPrincipal($current)
$canProvisionAnotherUser=$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)-or $current.User.Value-eq 'S-1-5-18'
if($canProvisionAnotherUser){$expected.SetOwner($administrators)}else{$expected.SetOwner($current.User)}
foreach($sid in @('S-1-5-18','S-1-5-32-544')){
    $identity=New-Object Security.Principal.SecurityIdentifier($sid)
    $expected.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
        $identity,'FullControl','ContainerInherit,ObjectInherit','None','Allow')))
}
$expected.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
    $runtime,'Modify','ContainerInherit,ObjectInherit','None','Allow')))
if(!(Test-Path -LiteralPath $target)){
    if($VerifyOnly){throw 'Result directory is not provisioned.'}
    if(!$canProvisionAnotherUser-and $ServiceSid-cne $current.User.Value){
        throw 'Only the current identity or an administrator may provision its result directory.'
    }
    if(!(Test-Path -LiteralPath (Split-Path -Parent $target) -PathType Container)){throw 'Result parent is unavailable.'}
    $null=New-Item -ItemType Directory -Path $target
    Set-Acl -LiteralPath $target -AclObject $expected
}
if(!(Test-Path -LiteralPath $target -PathType Container)){throw 'Result directory unavailable.'}
$actual=Get-Acl -LiteralPath $target
$ruleType=[Security.Principal.SecurityIdentifier]
$actualRules=@($actual.GetAccessRules($true,$true,$ruleType)|ForEach-Object {
    '{0}|{1}|{2}|{3}|{4}|{5}'-f $_.IdentityReference.Value,[int]$_.AccessControlType,[int]$_.FileSystemRights,[int]$_.InheritanceFlags,[int]$_.PropagationFlags,$_.IsInherited
}|Sort-Object)
$expectedRules=@($expected.GetAccessRules($true,$true,$ruleType)|ForEach-Object {
    '{0}|{1}|{2}|{3}|{4}|{5}'-f $_.IdentityReference.Value,[int]$_.AccessControlType,[int]$_.FileSystemRights,[int]$_.InheritanceFlags,[int]$_.PropagationFlags,$_.IsInherited
}|Sort-Object)
if(!$actual.AreAccessRulesProtected-or !$actual.AreAccessRulesCanonical-or
   ($actualRules-join "`n")-cne ($expectedRules-join "`n")-or
   $actual.GetOwner([Security.Principal.SecurityIdentifier]).Value-notin @('S-1-5-18','S-1-5-32-544',$ServiceSid)){
    throw 'Result directory ACL differs.'
}
Write-Output 'remote_result_cache_directory_verified'
