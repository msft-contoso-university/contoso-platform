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
    foreach ($service in @('STUDENTS', 'ACADEMICS', 'ENROLLMENTS')) {
        $global:testValues["ADLC_${stage}_${service}_IDENTITY_NAME"] = "$($service.ToLowerInvariant())-api"
        $global:testValues["ADLC_${stage}_${service}_MIGRATION_IDENTITY_NAME"] = "$($service.ToLowerInvariant())-migration"
    }
}
$global:testDeployments = @()
$global:testBadTenant = $false
$global:testBadIdentity = $false

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
    if ($args[0] -eq 'identity') {
        $name = [string] $args[([array]::IndexOf($args, '--name') + 1)]
        $group = [string] $args[([array]::IndexOf($args, '--resource-group') + 1)]
        $stage = $group.Substring('adlc-'.Length)
        $generation = if ($global:testBadIdentity -and $stage -eq 'staging') { 'other' } else { 'one' }
        $client = switch ($name) {
            'bootstrap' { '33333333-3333-4333-8333-333333333333' }
            'students-api' { 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa' }
            'students-migration' { 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb' }
            'academics-api' { 'cccccccc-cccc-4ccc-8ccc-cccccccccccc' }
            'academics-migration' { 'dddddddd-dddd-4ddd-8ddd-dddddddddddd' }
            'enrollments-api' { 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee' }
            'enrollments-migration' { 'ffffffff-ffff-4fff-8fff-ffffffffffff' }
            default { throw 'Unexpected test identity.' }
        }
        return (@{
            id = "/subscriptions/$subscription/resourceGroups/$group/providers/Microsoft.ManagedIdentity/userAssignedIdentities/$name"
            clientId = $client
            principalId = '44444444-4444-4444-8444-444444444444'
            tags = @{ 'adlc-stack' = 'demo'; 'adlc-generation' = $generation; 'adlc-stage' = $stage }
        } | ConvertTo-Json -Compress)
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
    $refused = $false
    try {
        & (Join-Path $PSScriptRoot '..\scripts\invoke-private-sql-grants.ps1') | Out-Null
    } catch {
        if ($_.Exception.Message -notmatch 'principal SID') { throw }
        $refused = $true
    }
    if (-not $refused -or $global:testDeployments.Count -ne 0) { throw 'Unverified SQL principal binding was not blocked.' }
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
    $global:testValues.ADLC_STAGING_SQL_GRANT_TARGETS = $targets
    $global:testBadIdentity = $true
    $refused = $false
    try {
        & (Join-Path $PSScriptRoot '..\scripts\invoke-private-sql-grants.ps1') | Out-Null
    } catch {
        if ($_.Exception.Message -notmatch 'stack ownership') { throw }
        $refused = $true
    }
    if (-not $refused -or $global:testDeployments.Count -ne 0) { throw 'Unowned staging identity was not rejected before dev deployment.' }
    $global:testBadIdentity = $false
    $global:testValues.ADLC_STAGING_STUDENTS_IDENTITY_NAME = 'different-api'
    $refused = $false
    try {
        & (Join-Path $PSScriptRoot '..\scripts\invoke-private-sql-grants.ps1') | Out-Null
    } catch {
        if ($_.Exception.Message -notmatch 'stack outputs') { throw }
        $refused = $true
    }
    if (-not $refused -or $global:testDeployments.Count -ne 0) { throw 'Identity mismatch was not rejected before dev deployment.' }
    Write-Output 'Private SQL grant orchestration tests passed.'
} finally {
    Remove-Item Function:\azd, Function:\az -ErrorAction SilentlyContinue
}
