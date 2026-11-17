Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'private-invocation.ps1')

function Get-AdlcNativeIdentity {
    $result = & (Join-Path $PSScriptRoot 'get-azd-ancestor.ps1') -ExpectedAction 'up'
    return ($result | ConvertFrom-Json)
}

function Invoke-AdlcGithubLock([string]$Command, [object]$Owner) {
    $script = Join-Path $PSScriptRoot 'stack-lock.py'
    $output = & python $script $Command --tenant $Owner.tenant --subscription $Owner.subscription `
        --environment $Owner.environment --generation $Owner.generation --operation-id $Owner.operationId --action $Owner.action 2>&1
    if ($LASTEXITCODE -ne 0) { throw "GitHub stack lock $Command failed: $($output | Out-String)" }
}

function Invoke-AdlcNativeStackLock([string]$Command, [string]$Directory, [string]$Tenant,
    [string]$Subscription, [string]$Environment, [string]$Generation) {
    if ($Command -notin @('acquire', 'verify', 'release')) { throw 'Unsupported stack lock command.' }
    $identity = Get-AdlcNativeIdentity
    if ($Command -eq 'acquire') {
        [void](New-AdlcPrivateOwner $Directory $identity 'up' $Tenant $Subscription $Environment $Generation)
    }
    $owner = Get-AdlcPrivateOwner $Directory $identity 'up' $Tenant $Subscription $Environment $Generation
    Invoke-AdlcGithubLock $Command $owner
}
