$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

& (Join-Path $PSScriptRoot 'get-azd-ancestor.ps1') -ExpectedAction 'up' | Out-Null
& python (Join-Path $PSScriptRoot 'validate-network-inputs.py') --azd-env
if ($LASTEXITCODE -ne 0) { throw 'Network input preflight failed; no provisioning was started.' }
& (Join-Path $PSScriptRoot 'guard-incomplete.ps1')
