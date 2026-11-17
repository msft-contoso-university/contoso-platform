$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '..\scripts\private-invocation.ps1')
$root = Join-Path $env:ADLC_TEST_PARENT 'race-owner'
New-AdlcPrivateDirectory $root
$identity = '{"pid":12345,"start":"123456789","action":"up"}' | ConvertFrom-Json
New-AdlcPrivateOwner $root $identity 'up' '11111111-1111-4111-8111-111111111111' `
    '22222222-2222-4222-8222-222222222222' 'demo' 'one'
