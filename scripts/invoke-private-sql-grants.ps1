$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-AzdValues {
    $lines = & azd env get-values --no-prompt
    if ($LASTEXITCODE -ne 0) { throw 'Unable to read the selected azd environment.' }
    $values = @{}
    foreach ($line in $lines) {
        if ($line -notmatch '^([A-Z][A-Z0-9_]*)=(.*)$') { throw 'Invalid azd environment entry.' }
        $key, $encoded = $Matches[1], $Matches[2]
        if ($encoded.StartsWith('"')) {
            $values[$key] = ConvertFrom-Json -InputObject $encoded
        } else {
            $values[$key] = $encoded
        }
    }
    return $values
}

function Get-RequiredValue([hashtable] $Values, [string] $Name) {
    if (-not $Values.ContainsKey($Name) -or [string]::IsNullOrWhiteSpace($Values[$Name])) {
        throw "Missing required azd environment value: $Name"
    }
    return [string] $Values[$Name]
}

function Assert-ResourceId([string] $Id, [string] $Subscription, [string] $Group, [string] $ProviderPath) {
    $prefix = "/subscriptions/$Subscription/resourceGroups/$Group/providers/$ProviderPath/"
    if (-not $Id.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -or $Id.Length -le $prefix.Length) {
        throw "Resource ID is outside the expected stack scope: $ProviderPath"
    }
}

function Assert-StackIdentity([string] $Name, [string] $Group, [string] $Stage) {
    $identityJson = & az identity show --name $Name --resource-group $Group --subscription $subscription --output json --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw "Unable to verify identity $Name in $Group." }
    $identityInfo = $identityJson | ConvertFrom-Json
    $expectedId = "/subscriptions/$subscription/resourceGroups/$Group/providers/Microsoft.ManagedIdentity/userAssignedIdentities/$Name"
    if ($identityInfo.id -ine $expectedId -or
        $identityInfo.tags.'adlc-stack' -ne $stack -or
        $identityInfo.tags.'adlc-generation' -ne $generation -or
        $identityInfo.tags.'adlc-stage' -ne $Stage.ToLowerInvariant() -or
        -not [guid]::TryParse($identityInfo.principalId, [ref] [guid]::Empty) -or
        -not [guid]::TryParse($identityInfo.clientId, [ref] [guid]::Empty)) {
        throw "Identity $Name does not match stack ownership and identity requirements."
    }
    return $identityInfo
}

function Assert-WorkloadIdentity([string] $Id, [string] $Group, [string] $Stage, [string] $Service, [string] $IdentityId, [string] $EnvironmentId) {
    $provider = if ($Service -eq 'enrollments') { 'Microsoft.App/containerApps' } else { 'Microsoft.Web/sites' }
    $apiVersion = if ($Service -eq 'enrollments') { '2024-03-01' } else { '2023-12-01' }
    Assert-ResourceId $Id $subscription $Group $provider
    if ($Id -notmatch "(?i)/providers/$([regex]::Escape($provider))/[A-Za-z0-9][A-Za-z0-9-]*$") {
        throw "Invalid $Stage $Service workload ID."
    }
    $resourceJson = & az resource show --ids $Id --api-version $apiVersion --subscription $subscription --output json --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw "Unable to verify $Stage $Service workload identity attachment." }
    $resource = $resourceJson | ConvertFrom-Json -AsHashtable
    if ($resource.id -ine $Id -or $resource.type -ine $provider -or
        $resource.tags.'adlc-stack' -ne $stack -or $resource.tags.'adlc-generation' -ne $generation -or
        $resource.tags.'adlc-stage' -ne $Stage.ToLowerInvariant() -or
        $resource.identity.type -ne 'UserAssigned' -or
        $resource.identity.userAssignedIdentities -isnot [System.Collections.IDictionary] -or
        $resource.identity.userAssignedIdentities.Count -ne 1 -or
        @($resource.identity.userAssignedIdentities.Keys | Where-Object { $_ -ieq $IdentityId }).Count -ne 1) {
        throw "$Stage $Service workload does not have the expected stack-owned runtime identity attached."
    }
    if ($Service -eq 'enrollments') {
        Assert-ResourceId $EnvironmentId $subscription $Group 'Microsoft.App/managedEnvironments'
        if ($EnvironmentId -notmatch '(?i)/providers/Microsoft\.App/managedEnvironments/[A-Za-z0-9][A-Za-z0-9-]*$' -or
            $resource.properties.managedEnvironmentId -ine $EnvironmentId) {
            throw "$Stage Enrollments workload is not in the expected internal environment."
        }
        $environmentJson = & az resource show --ids $EnvironmentId --api-version '2024-03-01' --subscription $subscription --output json --only-show-errors
        if ($LASTEXITCODE -ne 0) { throw "Unable to verify $Stage Enrollments environment." }
        $environment = $environmentJson | ConvertFrom-Json -AsHashtable
        if ($environment.id -ine $EnvironmentId -or $environment.type -ine 'Microsoft.App/managedEnvironments' -or
            $environment.tags.'adlc-stack' -ne $stack -or $environment.tags.'adlc-generation' -ne $generation -or
            $environment.tags.'adlc-stage' -ne $Stage.ToLowerInvariant() -or
            $environment.properties.vnetConfiguration.internal -ne $true) {
            throw "$Stage Enrollments environment is not stack-owned and internal."
        }
    }
}

$values = Get-AzdValues
$subscription = Get-RequiredValue $values 'AZURE_SUBSCRIPTION_ID'
$tenant = Get-RequiredValue $values 'AZURE_TENANT_ID'
$stack = Get-RequiredValue $values 'ADLC_STACK_NAME'
$generation = Get-RequiredValue $values 'ADLC_STACK_GENERATION'
$sharedGroup = Get-RequiredValue $values 'ADLC_SHARED_RESOURCE_GROUP'
$storageId = Get-RequiredValue $values 'ADLC_EXECUTION_STORAGE_ID'
$subnetId = Get-RequiredValue $values 'ADLC_RUNNER_SUBNET_ID'
if (-not [guid]::TryParse($subscription, [ref] [guid]::Empty) -or
    -not [guid]::TryParse($tenant, [ref] [guid]::Empty)) {
    throw 'Tenant and subscription must be GUIDs.'
}
Assert-ResourceId $storageId $subscription $sharedGroup 'Microsoft.Storage/storageAccounts'
Assert-ResourceId $subnetId $subscription $sharedGroup 'Microsoft.Network/virtualNetworks'
if ($storageId -notmatch '(?i)/storageAccounts/[^/]+$' -or
    $subnetId -notmatch '(?i)/virtualNetworks/[^/]+/subnets/runner$') {
    throw 'Expected the stack execution storage account and runner subnet.'
}

$accountJson = & az account show --subscription $subscription --output json --only-show-errors
if ($LASTEXITCODE -ne 0) { throw 'Unable to verify the selected Azure account.' }
$account = $accountJson | ConvertFrom-Json
if ($account.id -ne $subscription -or $account.tenantId -ne $tenant -or $account.state -ne 'Enabled') {
    throw 'Azure account, tenant, or subscription does not match the azd environment.'
}

$groups = @($sharedGroup)
foreach ($stage in @('DEV', 'STAGING')) {
    $groups += Get-RequiredValue $values "ADLC_${stage}_RESOURCE_GROUP"
}
if (($groups | Select-Object -Unique).Count -ne 3) { throw 'Shared, dev, and staging groups must be distinct.' }
foreach ($group in $groups) {
    $groupJson = & az group show --name $group --subscription $subscription --output json --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw "Unable to verify resource group $group." }
    $groupInfo = $groupJson | ConvertFrom-Json
    if ($groupInfo.tags.'adlc-stack' -ne $stack -or $groupInfo.tags.'adlc-generation' -ne $generation) {
        throw "Resource group $group does not match the stack ownership tags."
    }
}

$template = Join-Path $PSScriptRoot '..\infra\modules\sql-grants.bicep'
$location = Get-RequiredValue $values 'AZURE_LOCATION'
$plans = @()
foreach ($stage in @('DEV', 'STAGING')) {
    $group = Get-RequiredValue $values "ADLC_${stage}_RESOURCE_GROUP"
    $identity = Get-RequiredValue $values "ADLC_${stage}_SQL_BOOTSTRAP_IDENTITY_ID"
    $client = Get-RequiredValue $values "ADLC_${stage}_SQL_BOOTSTRAP_CLIENT_ID"
    $server = Get-RequiredValue $values "ADLC_${stage}_SQL_SERVER_NAME"
    $workloads = ConvertFrom-Json -InputObject (Get-RequiredValue $values "ADLC_${stage}_WORKLOADS") -AsHashtable
    if ($workloads -isnot [System.Collections.IDictionary]) { throw "Invalid $stage workload outputs." }
    Assert-ResourceId $identity $subscription $group 'Microsoft.ManagedIdentity/userAssignedIdentities'
    if ($identity -notmatch '(?i)/userAssignedIdentities/[^/]+$') { throw "Invalid $stage bootstrap identity ID." }
    if (-not [guid]::TryParse($client, [ref] [guid]::Empty)) { throw "Invalid $stage bootstrap client ID." }
    if ($server -cnotmatch '^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$') { throw "Invalid $stage SQL server name." }
    $targets = @(
        foreach ($service in @('STUDENTS', 'ACADEMICS', 'ENROLLMENTS')) {
            @{
                database = $service.ToLowerInvariant()
                runtime = Get-RequiredValue $values "ADLC_${stage}_${service}_IDENTITY_NAME"
                migration = Get-RequiredValue $values "ADLC_${stage}_${service}_MIGRATION_IDENTITY_NAME"
            }
        }
    )
    $databases = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $identityNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $bootstrapName = ($identity -split '/')[-1]
    $bootstrap = Assert-StackIdentity $bootstrapName $group $stage
    if ($bootstrap.clientId -ne $client) { throw "Bootstrap identity client ID does not match $stage." }
    foreach ($target in $targets) {
        if ($target -isnot [hashtable] -or $target.Count -ne 3 -or
            -not $target.ContainsKey('database') -or -not $target.ContainsKey('runtime') -or
            -not $target.ContainsKey('migration') -or $target.database -cnotin @('students', 'academics', 'enrollments') -or
            -not $databases.Add([string] $target.database)) {
            throw "Invalid service database target for $stage."
        }
        foreach ($identityName in @($target.runtime, $target.migration)) {
            if ($identityName -isnot [string] -or $identityName -cnotmatch '^[A-Za-z0-9][A-Za-z0-9-]{0,58}[A-Za-z0-9]$' -or
                $identityName -ieq $bootstrapName -or -not $identityNames.Add($identityName)) {
                throw "Runtime, migration and bootstrap identities must be distinct for $stage."
            }
        }
        $runtimeInfo = Assert-StackIdentity $target.runtime $group $stage
        $migrationInfo = Assert-StackIdentity $target.migration $group $stage
        if ($runtimeInfo.clientId -eq $migrationInfo.clientId -or
            $runtimeInfo.clientId -eq $client -or $migrationInfo.clientId -eq $client) {
            throw "Bootstrap, runtime, and migration client IDs must be distinct for $stage."
        }
        $appId = switch ($target.database) {
            'students' { $workloads.studentsAppId }
            'academics' { $workloads.academicsAppId }
            'enrollments' { Get-RequiredValue $values "ADLC_${stage}_ENROLLMENTS_APP_ID" }
        }
        if ($appId -isnot [string] -or [string]::IsNullOrWhiteSpace($appId)) {
            throw "Missing $stage $($target.database) workload ID."
        }
        if ($target.database -eq 'enrollments' -and
            ($workloads.enrollmentsEnvironmentId -isnot [string] -or [string]::IsNullOrWhiteSpace($workloads.enrollmentsEnvironmentId))) {
            throw "Missing $stage Enrollments environment ID."
        }
        Assert-WorkloadIdentity $appId $group $stage $target.database $runtimeInfo.id $workloads.enrollmentsEnvironmentId
        $target.runtimeClientId = $runtimeInfo.clientId
        $target.migrationClientId = $migrationInfo.clientId
    }
    $plans += @{
        stage = $stage; group = $group; identity = $identity
        client = $client; server = $server; targets = $targets
    }
}

throw 'SQL grants are blocked: the grant script does not verify database principal SID against the managed identity client ID.'

foreach ($plan in $plans) {
    $stage = $plan.stage
    $group = $plan.group
    $parameters = @{
        '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
        contentVersion = '1.0.0.0'
        parameters = @{
            name = @{ value = "adlc-$($stage.ToLowerInvariant())-sql-grants" }
            location = @{ value = $location }
            bootstrapIdentityResourceId = @{ value = $plan.identity }
            bootstrapIdentityClientId = @{ value = $plan.client }
            storageAccountResourceId = @{ value = $storageId }
            runnerSubnetResourceId = @{ value = $subnetId }
            sqlServerName = @{ value = $plan.server }
            targets = @{ value = $plan.targets }
            tags = @{ value = @{ 'adlc-stack' = $stack; 'adlc-generation' = $generation; 'adlc-stage' = $stage.ToLowerInvariant() } }
        }
    }
    $parameterFile = [IO.Path]::GetTempFileName()
    try {
        [IO.File]::WriteAllText($parameterFile, ($parameters | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
        $deploymentJson = & az deployment group create --name "adlc-$($stage.ToLowerInvariant())-sql-grants" `
            --resource-group $group --subscription $subscription --template-file $template `
            --parameters "@$parameterFile" --output json --only-show-errors
        if ($LASTEXITCODE -ne 0) { throw "Private SQL grant deployment failed for $stage." }
        $deployment = $deploymentJson | ConvertFrom-Json
        if ($deployment.properties.provisioningState -ne 'Succeeded' -or
            $deployment.properties.outputs.result.value.result -ne 'granted' -or
            $deployment.properties.outputs.result.value.databaseCount -ne 3) {
            throw "Private SQL grant deployment did not confirm all service databases for $stage."
        }
    } finally {
        Remove-Item -LiteralPath $parameterFile -ErrorAction Stop
    }
}
Write-Output 'Private SQL grants completed for both stack environments.'
