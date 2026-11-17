param(
    [ValidateSet('up', 'down')]
    [string]$ExpectedAction
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'azd-action.ps1')

function Get-ProcessArguments([int]$ProcessId) {
    if ($IsWindows) {
        $process = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId=$ProcessId"
        if ($null -eq $process -or [string]::IsNullOrEmpty($process.CommandLine)) {
            throw 'Cannot inspect azd process arguments.'
        }
        if (-not ('AdlcCommandLine' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class AdlcCommandLine {
    [DllImport("shell32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    public static extern IntPtr CommandLineToArgvW(string commandLine, out int argumentCount);
    [DllImport("kernel32.dll")]
    public static extern IntPtr LocalFree(IntPtr memory);
}
'@
        }
        $count = 0
        $buffer = [AdlcCommandLine]::CommandLineToArgvW($process.CommandLine, [ref]$count)
        if ($buffer -eq [IntPtr]::Zero -or $count -lt 1) { throw 'Cannot parse azd process arguments.' }
        try {
            $result = for ($index = 0; $index -lt $count; $index++) {
                [Runtime.InteropServices.Marshal]::PtrToStringUni(
                    [Runtime.InteropServices.Marshal]::ReadIntPtr($buffer, $index * [IntPtr]::Size))
            }
            return ,([string[]]$result)
        }
        finally {
            [void][AdlcCommandLine]::LocalFree($buffer)
        }
    }
    if (-not $IsLinux) { throw 'Only Windows and Linux process identities are supported.' }
    $bytes = [System.IO.File]::ReadAllBytes("/proc/$ProcessId/cmdline")
    $text = [System.Text.UTF8Encoding]::new($false, $true).GetString($bytes)
    if (-not $text.EndsWith([string][char]0)) { throw 'Cannot parse azd process arguments.' }
    return ,([string[]]$text.TrimEnd([char]0).Split([char]0))
}

function Get-ProcessIdentity([int]$ProcessId) {
    if ($IsWindows) {
        $process = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId=$ProcessId"
        if ($null -eq $process -or [string]::IsNullOrWhiteSpace($process.ExecutablePath) -or $null -eq $process.CreationDate) {
            throw 'Cannot establish process identity.'
        }
        return @{
            pid = [int]$process.ProcessId
            parent = [int]$process.ParentProcessId
            start = $process.CreationDate.ToUniversalTime().Ticks.ToString()
            executable = [string]$process.ExecutablePath
        }
    }
    if (-not $IsLinux) { throw 'Only Windows and Linux process identities are supported.' }
    $stat = [System.IO.File]::ReadAllText("/proc/$ProcessId/stat")
    $end = $stat.LastIndexOf(')')
    if ($end -lt 1) { throw 'Cannot parse process identity.' }
    $fields = $stat.Substring($end + 1).Trim() -split '\s+'
    if ($fields.Count -lt 20) { throw 'Incomplete process identity.' }
    $executable = [System.IO.File]::ResolveLinkTarget("/proc/$ProcessId/exe", $true)
    if ($null -eq $executable) { throw 'Cannot resolve process executable.' }
    $bootId = [guid]::Parse([System.IO.File]::ReadAllText('/proc/sys/kernel/random/boot_id').Trim()).ToString()
    $namespace = (Get-Item -LiteralPath '/proc/self/ns/pid' -Force).LinkTarget
    if ($namespace -notmatch '^pid:\[([0-9]+)\]$') { throw 'Cannot establish PID namespace identity.' }
    $namespaceId = $Matches[1]
    if ($fields[19] -notmatch '^[0-9]+$') { throw 'Invalid process start identity.' }
    return @{
        pid = $ProcessId
        parent = [int]$fields[1]
        start = "${bootId}:${namespaceId}:$($fields[19])"
        executable = $executable.FullName
    }
}

$command = Get-Command azd -CommandType Application | Select-Object -First 1
if ($null -eq $command) { throw 'azd executable not found.' }
$target = [System.IO.Path]::GetFullPath($command.Source)
$link = [System.IO.File]::ResolveLinkTarget($target, $true)
if ($null -ne $link) { $target = $link.FullName }
$comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
$current = $PID
for ($depth = 0; $depth -lt 12 -and $current -gt 0; $depth++) {
    $process = Get-ProcessIdentity $current
    if ([string]::Equals([System.IO.Path]::GetFullPath($process.executable), $target, $comparison)) {
        if ($ExpectedAction) {
            $action = Get-AzdCommandAction (Get-ProcessArguments $current)
            if ($action -ne $ExpectedAction) { throw 'azd command does not match the expected action.' }
        }
        $confirm = Get-ProcessIdentity $current
        if ($confirm.start -ne $process.start -or
            -not [string]::Equals($confirm.executable, $process.executable, $comparison)) {
            throw 'azd process identity changed during inspection.'
        }
        $result = @{ pid = $current; start = $process.start }
        if ($ExpectedAction) { $result.action = $action }
        $result | ConvertTo-Json -Compress
        return
    }
    if ($process.parent -eq $current) { throw 'Invalid process ancestry.' }
    $current = $process.parent
}
throw 'No matching live azd ancestor was found.'
