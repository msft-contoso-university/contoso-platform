$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$sample = @{
    AZURE_ENV_NAME = 'ci-stack'
    ADLC_STACK_GENERATION = 'test-generation'
    AZURE_LOCATION = 'eastus2'
    ADLC_VNET_PREFIX = '10.60.0.0/16'
    ADLC_RUNNER_SUBNET_PREFIX = '10.60.0.0/24'
    ADLC_ENDPOINT_SUBNET_PREFIX = '10.60.1.0/24'
    ADLC_APPLICATION_SUBNETS = '[{"name":"dev-apps","addressPrefix":"10.60.2.0/24","delegation":"Microsoft.Web/serverFarms"},{"name":"staging-apps","addressPrefix":"10.60.3.0/24","delegation":"Microsoft.Web/serverFarms"}]'
    ADLC_DEV_APP_SUBNET_NAME = 'dev-apps'
    ADLC_STAGING_APP_SUBNET_NAME = 'staging-apps'
    ADLC_DEV_STUDENTS_AUDIENCE = 'api://dev-students'
    ADLC_DEV_ACADEMICS_AUDIENCE = 'api://dev-academics'
    ADLC_STAGING_STUDENTS_AUDIENCE = 'api://staging-students'
    ADLC_STAGING_ACADEMICS_AUDIENCE = 'api://staging-academics'
    ADLC_RUNNER_HTTPS_EGRESS_PREFIXES = '["20.0.0.0/8"]'
    ADLC_DATABASE_SKU = '{"name":"Basic","tier":"Basic"}'
    ADLC_LOG_DAILY_QUOTA_GB = '1'
}
foreach ($key in $sample.Keys) { [Environment]::SetEnvironmentVariable($key, $sample[$key], 'Process') }
$path = Join-Path $PSScriptRoot '..\infra\main.bicepparam'
$raw = & az bicep build-params --file $path --stdout
if ($LASTEXITCODE -ne 0) { throw 'Bicep parameters did not compile.' }
$output = ($raw | Out-String) | ConvertFrom-Json
$parameters = ($output.parametersJson | ConvertFrom-Json).parameters
if ($parameters.environmentName.value -ne 'ci-stack' -or
    $parameters.location.value -ne 'eastus2' -or
    $parameters.applicationSubnets.value.Count -ne 2 -or
    $parameters.runnerHttpsEgressPrefixes.value.Count -ne 1 -or
    $parameters.databaseSku.value.name -ne 'Basic' -or
    $parameters.dailyQuotaGb.value -ne 1) {
    throw 'Bicep parameters did not preserve the supplied input types or values.'
}
[Environment]::SetEnvironmentVariable('AZURE_LOCATION', $null, 'Process')
$missing = & az bicep build-params --file $path --stdout
if ($LASTEXITCODE -eq 0) {
    $missingOutput = ($missing | Out-String) | ConvertFrom-Json
    $missingParameters = ($missingOutput.parametersJson | ConvertFrom-Json).parameters
    if (-not [string]::IsNullOrEmpty($missingParameters.location.value)) {
        throw 'Missing location unexpectedly selected a default.'
    }
}
$global:LASTEXITCODE = 0
Write-Output 'Parameter bindings compile with explicit inputs and do not supply a default location.'
