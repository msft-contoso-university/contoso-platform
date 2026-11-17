$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '..\scripts\azd-action.ps1')

$allowed = @(
    @{ arguments = @('azd', 'up'); action = 'up' },
    @{ arguments = @('azd', '-C', 'some folder', '--environment', 'demo', 'up', '--no-prompt'); action = 'up' },
    @{ arguments = @('azd', '--no-prompt', '--cwd=some folder', 'down'); action = 'down' }
)
foreach ($test in $allowed) {
    if ((Get-AzdCommandAction $test.arguments) -ne $test.action) { throw 'Valid azd action was not bound.' }
}
$denied = @(
    ,@('azd', 'hooks', 'run', 'preup')
    ,@('azd', '-C', 'up', 'hooks', 'run', 'preup')
    ,@('azd', '--environment', 'down', 'hooks', 'run', 'predown')
    ,@('azd', '--unknown', 'up')
    ,@('azd', '--cwd')
    ,@('azd', 'provision')
)
foreach ($arguments in $denied) {
    $failed = $false
    try { [void](Get-AzdCommandAction $arguments) } catch { $failed = $true }
    if (-not $failed) { throw 'Unsupported azd invocation was accepted.' }
}
Write-Output 'Native action parsing rejects independent hooks and unsupported commands.'
