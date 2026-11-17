Set-StrictMode -Version Latest

if ($IsLinux -and -not ('AdlcPrivateFiles' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class AdlcPrivateFiles {
    [DllImport("libc", SetLastError=true, EntryPoint="open")]
    public static extern int Open(string pathname, int flags, uint mode);
    [DllImport("libc", EntryPoint="geteuid")]
    public static extern uint EffectiveUserId();
}
'@
}

function Assert-AdlcPrivatePath([string]$Path, [bool]$Directory, [bool]$TrustedParent = $false) {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.PSIsContainer -ne $Directory) {
        throw 'Private owner path must be an ordinary file or directory.'
    }
    if ($IsWindows) {
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
        $acl = Get-Acl -LiteralPath $Path
        if ($acl.GetOwner([Security.Principal.SecurityIdentifier]) -ne $sid -or
            (-not $TrustedParent -and -not $acl.AreAccessRulesProtected)) {
            throw 'Private owner path has an unexpected owner or inherited ACL.'
        }
        $rules = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
        $allowed = if ($TrustedParent) { @($sid.Value, 'S-1-3-4', 'S-1-5-18', 'S-1-5-32-544') } else { @($sid.Value) }
        if ($rules.Count -eq 0 -or
            @($rules | Where-Object { $_.AccessControlType -ne 'Allow' -or
                $_.IdentityReference.Value -notin $allowed -or (-not $TrustedParent -and $_.IsInherited) }).Count -ne 0 -or
            @($rules | Where-Object { ($_.IdentityReference.Value -eq $sid.Value -or
                ($TrustedParent -and $_.IdentityReference.Value -eq 'S-1-3-4')) -and
                ($_.FileSystemRights -band [Security.AccessControl.FileSystemRights]::FullControl) -eq
                [Security.AccessControl.FileSystemRights]::FullControl }).Count -eq 0) {
            throw 'Private owner path ACL is not restricted to the current user.'
        }
    }
    elseif ($IsLinux) {
        $expected = if ($Directory) { 448 } else { 384 }
        $mode = [int][IO.File]::GetUnixFileMode($Path)
        $owner = & stat -c '%u' -- $Path
        if ($LASTEXITCODE -ne 0 -or $owner -notmatch '^[0-9]+$' -or
            [uint32]$owner -ne [AdlcPrivateFiles]::EffectiveUserId() -or $mode -ne $expected) {
            throw 'Private owner path is not user-owned with restrictive permissions.'
        }
    }
    else { throw 'Private owner storage is supported only on Windows and Linux.' }
}

function New-AdlcPrivateDirectory([string]$Path) {
    if (-not [IO.Path]::IsPathFullyQualified($Path)) { throw 'Private owner directory must be absolute.' }
    $parent = [IO.Directory]::GetParent($Path)
    if ($null -eq $parent) { throw 'Private owner directory needs a private parent.' }
    Assert-AdlcPrivatePath $parent.FullName $true $true
    if ($IsWindows) {
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
        $security = [Security.AccessControl.DirectorySecurity]::new()
        $security.SetOwner($sid)
        $security.SetAccessRuleProtection($true, $false)
        $rule = [Security.AccessControl.FileSystemAccessRule]::new(
            $sid, [Security.AccessControl.FileSystemRights]::FullControl,
            [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit',
            [Security.AccessControl.PropagationFlags]::None,
            [Security.AccessControl.AccessControlType]::Allow)
        $security.AddAccessRule($rule)
        [void][IO.FileSystemAclExtensions]::CreateDirectory($security, $Path)
    }
    elseif ($IsLinux) {
        [void][IO.Directory]::CreateDirectory($Path, [IO.UnixFileMode]448)
    }
    else { throw 'Private owner storage is supported only on Windows and Linux.' }
    Assert-AdlcPrivatePath $Path $true
}

function Get-AdlcOwnerPath([string]$Directory, [object]$Identity) {
    if (($Identity.pid -isnot [int] -and $Identity.pid -isnot [long]) -or
        $Identity.pid -le 0 -or $Identity.pid -gt [int]::MaxValue -or
        $Identity.start -isnot [string] -or $Identity.start -notmatch '^(?:[0-9a-f-]{36}:[0-9]+:)?[0-9]+$') {
        throw 'Invalid native invocation identity.'
    }
    $bytes = [Text.Encoding]::UTF8.GetBytes("$($Identity.pid)|$($Identity.start)")
    $name = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
    return [IO.Path]::Combine($Directory, "$name.json")
}

function New-AdlcPrivateOwner([string]$Directory, [object]$Identity, [string]$Action,
    [string]$Tenant, [string]$Subscription, [string]$Environment, [string]$Generation) {
    if ($Action -ne 'up' -or $Identity.action -ne $Action) { throw 'Only an action-bound up owner may be prepared.' }
    [void][guid]::Parse($Tenant)
    [void][guid]::Parse($Subscription)
    if ($Environment -cnotmatch '^[a-z0-9](?:[a-z0-9-]{0,38}[a-z0-9])?$' -or
        $Generation -cnotmatch '^[a-z0-9](?:[a-z0-9-]{0,38}[a-z0-9])?$') {
        throw 'Invalid stack environment or generation.'
    }
    Assert-AdlcPrivatePath $Directory $true
    $path = Get-AdlcOwnerPath $Directory $Identity
    $record = @{
        version = 1; pid = $Identity.pid; start = $Identity.start; action = $Action
        tenant = ([guid]::Parse($Tenant)).ToString(); subscription = ([guid]::Parse($Subscription)).ToString()
        environment = $Environment; generation = $Generation
        operationId = [guid]::NewGuid().ToString()
        nonce = [Convert]::ToBase64String([Security.Cryptography.RandomNumberGenerator]::GetBytes(32))
    }
    $content = [Text.Encoding]::UTF8.GetBytes(($record | ConvertTo-Json -Compress))
    if ($IsWindows) {
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
        $security = [Security.AccessControl.FileSecurity]::new()
        $security.SetOwner($sid)
        $security.SetAccessRuleProtection($true, $false)
        $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            $sid, [Security.AccessControl.FileSystemRights]::FullControl,
            [Security.AccessControl.AccessControlType]::Allow))
        $stream = [IO.FileSystemAclExtensions]::Create(
            [IO.FileInfo]::new($path), [IO.FileMode]::CreateNew,
            [Security.AccessControl.FileSystemRights]'Read, Write', [IO.FileShare]::None,
            4096, [IO.FileOptions]::None, $security)
    }
    else {
        $fd = [AdlcPrivateFiles]::Open($path, 1 -bor 64 -bor 128 -bor 131072 -bor 524288, 384)
        if ($fd -lt 0) { throw "Exclusive private owner file creation failed (errno $([Runtime.InteropServices.Marshal]::GetLastPInvokeError()))." }
        $handle = [Microsoft.Win32.SafeHandles.SafeFileHandle]::new([IntPtr]$fd, $true)
        $stream = [IO.FileStream]::new($handle, [IO.FileAccess]::Write)
    }
    try {
        $stream.Write($content, 0, $content.Length)
        $stream.Flush($true)
    }
    finally { $stream.Dispose() }
    Assert-AdlcPrivatePath $path $false
    return $path
}

function Get-AdlcPrivateOwner([string]$Directory, [object]$Identity, [string]$Action,
    [string]$Tenant, [string]$Subscription, [string]$Environment, [string]$Generation) {
    Assert-AdlcPrivatePath $Directory $true
    $path = Get-AdlcOwnerPath $Directory $Identity
    Assert-AdlcPrivatePath $path $false
    if ((Get-Item -LiteralPath $path).Length -gt 4096) { throw 'Private owner record is oversized.' }
    $record = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    if ($Action -ne 'up' -or $Identity.action -ne $Action -or $record.version -ne 1 -or
        $record.pid -ne $Identity.pid -or $record.start -cne $Identity.start -or $record.action -cne $Action -or
        $record.tenant -cne ([guid]::Parse($Tenant)).ToString() -or
        $record.subscription -cne ([guid]::Parse($Subscription)).ToString() -or
        $record.environment -cne $Environment -or $record.generation -cne $Generation -or
        -not [guid]::TryParse($record.operationId, [ref]([guid]::Empty)) -or
        [Convert]::FromBase64String($record.nonce).Length -ne 32) {
        throw 'Private owner record does not match this native invocation and stack.'
    }
    return $record
}
