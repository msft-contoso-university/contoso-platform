$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

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
    return @{
        pid = $ProcessId
        parent = [int]$fields[1]
        start = [string]$fields[19]
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
        $confirm = Get-ProcessIdentity $current
        if ($confirm.start -ne $process.start -or
            -not [string]::Equals($confirm.executable, $process.executable, $comparison)) {
            throw 'azd process identity changed during inspection.'
        }
        @{ pid = $current; start = $process.start } | ConvertTo-Json -Compress
        return
    }
    if ($process.parent -eq $current) { throw 'Invalid process ancestry.' }
    $current = $process.parent
}
throw 'No matching live azd ancestor was found.'
