$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '..\scripts\private-invocation.ps1')

$root = Join-Path $env:ADLC_TEST_PARENT 'owner'
New-AdlcPrivateDirectory $root
$identity = '{"pid":12345,"start":"123456789","action":"up"}' | ConvertFrom-Json
$tenant = '11111111-1111-4111-8111-111111111111'
$subscription = '22222222-2222-4222-8222-222222222222'
$path = New-AdlcPrivateOwner $root $identity 'up' $tenant $subscription 'demo' 'one'
$owner = Get-AdlcPrivateOwner $root $identity 'up' $tenant $subscription 'demo' 'one'
if (-not (Test-Path -LiteralPath $path) -or [Convert]::FromBase64String($owner.nonce).Length -ne 32) {
    throw 'Private owner was not created correctly.'
}
foreach ($attempt in @(
    { New-AdlcPrivateOwner $root $identity 'up' $tenant $subscription 'demo' 'one' },
    { Get-AdlcPrivateOwner $root $identity 'up' $tenant $subscription 'demo' 'two' },
    { Get-AdlcPrivateOwner $root $identity 'down' $tenant $subscription 'demo' 'one' }
)) {
    $failed = $false
    try { [void](& $attempt) } catch { $failed = $true }
    if (-not $failed) { throw 'Duplicate or mismatched private ownership was accepted.' }
}
if ($IsLinux) {
    [IO.File]::SetUnixFileMode($path, [IO.UnixFileMode]420)
    $failed = $false
    try { [void](Get-AdlcPrivateOwner $root $identity 'up' $tenant $subscription 'demo' 'one') } catch { $failed = $true }
    if (-not $failed) { throw 'A world-readable owner file was accepted.' }
}
elseif ($IsWindows) {
    $acl = Get-Acl -LiteralPath $path
    $everyone = [Security.Principal.SecurityIdentifier]::new('S-1-1-0')
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
        $everyone, [Security.AccessControl.FileSystemRights]::Read,
        [Security.AccessControl.AccessControlType]::Allow))
    [IO.FileSystemAclExtensions]::SetAccessControl([IO.FileInfo]::new($path), $acl)
    $failed = $false
    try { [void](Get-AdlcPrivateOwner $root $identity 'up' $tenant $subscription 'demo' 'one') } catch { $failed = $true }
    if (-not $failed) { throw 'An owner file readable by Everyone was accepted.' }
}
. (Join-Path $PSScriptRoot '..\scripts\native-stack-lock.ps1')
$script:pythonArguments = @()
function python {
    $script:pythonArguments = @($args)
    $global:LASTEXITCODE = 0
}
Invoke-AdlcGithubLock 'verify' $owner
if ($script:pythonArguments -contains $owner.nonce -or
    $script:pythonArguments -notcontains $owner.operationId) {
    throw 'Public lock invocation exposed the private nonce or omitted the operation ID.'
}
Remove-Item Function:\python
$lockRoot = Join-Path $env:ADLC_TEST_PARENT 'lock-owner'
New-AdlcPrivateDirectory $lockRoot
$script:currentIdentity = $identity
$script:calls = [Collections.Generic.List[object]]::new()
function Get-AdlcNativeIdentity { return $script:currentIdentity }
function Invoke-AdlcGithubLock([string]$Command, [object]$Owner) {
    $script:calls.Add([pscustomobject]@{
        command = $Command; id = $Owner.operationId; action = $Owner.action; generation = $Owner.generation
    })
    if ($script:failLock) { throw 'Simulated lock failure.' }
}
$script:failLock = $false
Invoke-AdlcNativeStackLock 'acquire' $lockRoot $tenant $subscription 'demo' 'one'
Invoke-AdlcNativeStackLock 'verify' $lockRoot $tenant $subscription 'demo' 'one'
Invoke-AdlcNativeStackLock 'release' $lockRoot $tenant $subscription 'demo' 'one'
if ($calls.Count -ne 3 -or $calls[0].id -ne $calls[1].id -or $calls[0].id -ne $calls[2].id -or
    @($calls | Where-Object { $_.action -ne 'up' -or $_.generation -ne 'one' }).Count -ne 0) {
    throw 'Private owner was not bound to the exact public lock operation.'
}
$script:currentIdentity = '{"pid":12346,"start":"123456790","action":"up"}' | ConvertFrom-Json
$failed = $false
try { Invoke-AdlcNativeStackLock 'verify' $lockRoot $tenant $subscription 'demo' 'one' } catch { $failed = $true }
if (-not $failed -or $calls.Count -ne 3) { throw 'Another invocation adopted a public lock owner.' }
$script:failLock = $true
$failed = $false
try { Invoke-AdlcNativeStackLock 'acquire' $lockRoot $tenant $subscription 'demo' 'one' } catch { $failed = $true }
if (-not $failed -or -not (Test-Path -LiteralPath (Get-AdlcOwnerPath $lockRoot $script:currentIdentity))) {
    throw 'Failed acquisition did not retain the private owner.'
}
$script:failLock = $false
$failed = $false
try { Invoke-AdlcNativeStackLock 'acquire' $lockRoot $tenant $subscription 'demo' 'one' } catch { $failed = $true }
if (-not $failed -or $calls.Count -ne 4) { throw 'A failed owner was silently adopted or reacquired.' }
$script:currentIdentity = '{"pid":12347,"start":"123456791","action":"up"}' | ConvertFrom-Json
Invoke-AdlcNativeStackLock 'acquire' $lockRoot $tenant $subscription 'demo' 'one'
$script:failLock = $true
$failed = $false
try { Invoke-AdlcNativeStackLock 'release' $lockRoot $tenant $subscription 'demo' 'one' } catch { $failed = $true }
if (-not $failed -or -not (Test-Path -LiteralPath (Get-AdlcOwnerPath $lockRoot $script:currentIdentity))) {
    throw 'Failed lock release did not retain the private owner.'
}
Write-Output 'Private owner creation, binding and permission checks passed.'
