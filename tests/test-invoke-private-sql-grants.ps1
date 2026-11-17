$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$subscription = '22222222-2222-4222-8222-222222222222'
$tenant = '11111111-1111-4111-8111-111111111111'
$shared = 'adlc-shared'
$targets = @(
    @{ database = 'students'; runtime = 'students-api'; migration = 'students-migration' }
    @{ database = 'academics'; runtime = 'academics-api'; migration = 'academics-migration' }
    @{ database = 'enrollments'; runtime = 'enrollments-api'; migration = 'enrollments-migration' }
) | ConvertTo-Json -Compress
$global:testValues = @{
    AZURE_SUBSCRIPTION_ID = $subscription
    AZURE_TENANT_ID = $tenant
    AZURE_LOCATION = 'example-region'
    ADLC_STACK_NAME = 'demo'
    ADLC_STACK_GENERATION = 'one'
    ADLC_SHARED_RESOURCE_GROUP = $shared
    ADLC_EXECUTION_STORAGE_ID = "/subscriptions/$subscription/resourceGroups/$shared/providers/Microsoft.Storage/storageAccounts/scriptstorage"
    ADLC_RUNNER_SUBNET_ID = "/subscriptions/$subscription/resourceGroups/$shared/providers/Microsoft.Network/virtualNetworks/demo/subnets/runner"
}
foreach ($stage in @('DEV', 'STAGING')) {
    $group = "adlc-$($stage.ToLowerInvariant())"
    $global:testValues["ADLC_${stage}_RESOURCE_GROUP"] = $group
    $global:testValues["ADLC_${stage}_SQL_BOOTSTRAP_IDENTITY_ID"] = "/subscriptions/$subscription/resourceGroups/$group/providers/Microsoft.ManagedIdentity/userAssignedIdentities/bootstrap"
    $global:testValues["ADLC_${stage}_SQL_BOOTSTRAP_CLIENT_ID"] = '33333333-3333-4333-8333-333333333333'
    $global:testValues["ADLC_${stage}_SQL_SERVER_NAME"] = "sql-$($stage.ToLowerInvariant())"
    $global:testValues["ADLC_${stage}_SQL_GRANT_TARGETS"] = $targets
}
$global:testDeployments = @()
$global:testBadTenant = $false

function global:azd {
    $global:LASTEXITCODE = 0
    foreach ($entry in $global:testValues.GetEnumerator()) {
        "$($entry.Key)=$(ConvertTo-Json -InputObject $entry.Value -Compress)"
    }
}

function global:az {
    $global:LASTEXITCODE = 0
    if ($args[0] -eq 'account') {
        $actualTenant = if ($global:testBadTenant) { 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa' } else { $tenant }
        return (@{ id = $subscription; tenantId = $actualTenant; state = 'Enabled' } | ConvertTo-Json -Compress)
    }
    if ($args[0] -eq 'group') {
        return (@{ tags = @{ 'adlc-stack' = 'demo'; 'adlc-generation' = 'one' } } | ConvertTo-Json -Compress)
    }
    if ($args[0] -eq 'deployment') {
        $file = [string] $args[([array]::IndexOf($args, '--parameters') + 1)]
        $parameters = Get-Content -Raw -LiteralPath $file.Substring(1) | ConvertFrom-Json -AsHashtable
        $global:testDeployments += $parameters.parameters
        return '{"properties":{"provisioningState":"Succeeded","outputs":{"result":{"value":{"result":"granted","databaseCount":3}}}}}'
    }
    throw 'Unexpected Azure CLI command'
}

try {
    & (Join-Path $PSScriptRoot '..\scripts\invoke-private-sql-grants.ps1') | Out-Null
    if ($global:testDeployments.Count -ne 2) { throw 'Expected both private SQL grant deployments.' }
    if ($global:testDeployments[0].targets.value.Count -ne 3) { throw 'Expected all three service targets.' }
    $global:testDeployments = @()
    $global:testBadTenant = $true
    $refused = $false
    try {
        & (Join-Path $PSScriptRoot '..\scripts\invoke-private-sql-grants.ps1') | Out-Null
    } catch {
        if ($_.Exception.Message -notmatch 'does not match') { throw }
        $refused = $true
    }
    if (-not $refused -or $global:testDeployments.Count -ne 0) { throw 'Wrong tenant was not rejected before deployment.' }
    $global:testBadTenant = $false
    $global:testValues.ADLC_STAGING_SQL_GRANT_TARGETS = @(
        @{ database = 'students'; runtime = 'students-api'; migration = 'students-api' }
        @{ database = 'academics'; runtime = 'academics-api'; migration = 'academics-migration' }
        @{ database = 'enrollments'; runtime = 'enrollments-api'; migration = 'enrollments-migration' }
    ) | ConvertTo-Json -Compress
    $refused = $false
    try {
        & (Join-Path $PSScriptRoot '..\scripts\invoke-private-sql-grants.ps1') | Out-Null
    } catch {
        if ($_.Exception.Message -notmatch 'must be distinct') { throw }
        $refused = $true
    }
    if (-not $refused -or $global:testDeployments.Count -ne 0) { throw 'Invalid staging identities were not rejected before dev deployment.' }
    Write-Output 'Private SQL grant orchestration tests passed.'
} finally {
    Remove-Item Function:\azd, Function:\az -ErrorAction SilentlyContinue
}
