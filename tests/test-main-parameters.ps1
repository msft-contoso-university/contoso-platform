$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$sample = @{
    AZURE_ENV_NAME = 'ci-stack'
    ADLC_STACK_GENERATION = 'test-generation'
    AZURE_LOCATION = 'eastus2'
    ADLC_VNET_PREFIX = '10.60.0.0/16'
    ADLC_RUNNER_SUBNET_PREFIX = '10.60.0.0/24'
    ADLC_ENDPOINT_SUBNET_PREFIX = '10.60.1.0/24'
    ADLC_APPLICATION_SUBNETS = '[{"name":"dev-apps","addressPrefix":"10.60.2.0/24","delegation":"Microsoft.Web/serverFarms"},{"name":"staging-apps","addressPrefix":"10.60.3.0/24","delegation":"Microsoft.Web/serverFarms"},{"name":"dev-containers","addressPrefix":"10.60.4.0/24","delegation":"Microsoft.App/environments"},{"name":"staging-containers","addressPrefix":"10.60.5.0/24","delegation":"Microsoft.App/environments"}]'
    ADLC_DEV_APP_SUBNET_NAME = 'dev-apps'
    ADLC_STAGING_APP_SUBNET_NAME = 'staging-apps'
    ADLC_DEV_CONTAINER_SUBNET_NAME = 'dev-containers'
    ADLC_STAGING_CONTAINER_SUBNET_NAME = 'staging-containers'
    ADLC_DEV_STUDENTS_AUDIENCE = 'api://dev-students'
    ADLC_DEV_ACADEMICS_AUDIENCE = 'api://dev-academics'
    ADLC_STAGING_STUDENTS_AUDIENCE = 'api://staging-students'
    ADLC_STAGING_ACADEMICS_AUDIENCE = 'api://staging-academics'
    ADLC_DEV_WEB_CLIENT_ID = '11111111-1111-4111-8111-111111111111'
    ADLC_DEV_STUDENTS_READ_SCOPE = 'api://dev-students/students.read'
    ADLC_DEV_ACADEMICS_READ_SCOPE = 'api://dev-academics/academics.read'
    ADLC_DEV_ENROLLMENTS_READ_SCOPE = 'api://dev-enrollments/enrollments.read'
    ADLC_DEV_ENROLLMENTS_WRITE_SCOPE = 'api://dev-enrollments/enrollments.write'
    ADLC_STAGING_WEB_CLIENT_ID = '22222222-2222-4222-8222-222222222222'
    ADLC_STAGING_STUDENTS_READ_SCOPE = 'api://staging-students/students.read'
    ADLC_STAGING_ACADEMICS_READ_SCOPE = 'api://staging-academics/academics.read'
    ADLC_STAGING_ENROLLMENTS_READ_SCOPE = 'api://staging-enrollments/enrollments.read'
    ADLC_STAGING_ENROLLMENTS_WRITE_SCOPE = 'api://staging-enrollments/enrollments.write'
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
    $parameters.applicationSubnets.value.Count -ne 4 -or
    $parameters.devWebClientId.value -ne $sample.ADLC_DEV_WEB_CLIENT_ID -or
    $parameters.stagingWebClientId.value -ne $sample.ADLC_STAGING_WEB_CLIENT_ID -or
    $parameters.devEnrollmentsWriteScope.value -ne $sample.ADLC_DEV_ENROLLMENTS_WRITE_SCOPE -or
    $parameters.stagingEnrollmentsWriteScope.value -ne $sample.ADLC_STAGING_ENROLLMENTS_WRITE_SCOPE -or
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
