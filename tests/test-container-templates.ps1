$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$hostingJson = & az bicep build --file (Join-Path $PSScriptRoot '..\infra\modules\enrollments-hosting.bicep') --stdout
if ($LASTEXITCODE -ne 0) { throw 'Container Apps environment template did not compile.' }
$hosting = ($hostingJson | Out-String) | ConvertFrom-Json
$environments = @($hosting.resources | Where-Object type -eq 'Microsoft.App/managedEnvironments')
if ($environments.Count -ne 1 -or -not $environments[0].properties.vnetConfiguration.internal -or
    $environments[0].properties.appLogsConfiguration.destination -ne 'azure-monitor') {
    throw 'Expected an internal Container Apps environment with Azure Monitor logs.'
}
$diagnostics = @($hosting.resources | Where-Object type -eq 'Microsoft.Insights/diagnosticSettings')
if ($diagnostics.Count -ne 1 -or $diagnostics[0].properties.logs[0].categoryGroup -ne 'allLogs') {
    throw 'Expected diagnostic log routing for the Container Apps environment.'
}
if (@($hosting.resources | Where-Object type -eq 'Microsoft.App/containerApps').Count -ne 0) {
    throw 'Container app must be deployed only after its private registry image exists.'
}

$appJson = & az bicep build --file (Join-Path $PSScriptRoot '..\infra\modules\enrollments-app.bicep') --stdout
if ($LASTEXITCODE -ne 0) { throw 'Container app release template did not compile.' }
$release = ($appJson | Out-String) | ConvertFrom-Json
$apps = @($release.resources | Where-Object type -eq 'Microsoft.App/containerApps')
if ($apps.Count -ne 1 -or $apps[0].identity.type -ne 'UserAssigned' -or
    -not $apps[0].properties.configuration.ingress.external -or
    $apps[0].properties.configuration.ingress.allowInsecure -or
    $apps[0].properties.template.containers[0].image -notlike '*@sha256:{1}*') {
    throw 'Expected managed-identity image deployment with TLS ingress inside the internal environment.'
}
$digest = $release.parameters.imageSha256Hex
if ($digest.minLength -ne 64 -or $digest.maxLength -ne 64) {
    throw 'Expected an explicit immutable image digest.'
}
$probes = @($apps[0].properties.template.containers[0].probes)
if (@($probes | Where-Object { $_.type -eq 'Liveness' -and $_.httpGet.path -eq '/health/live' }).Count -ne 1 -or
    @($probes | Where-Object { $_.type -eq 'Readiness' -and $_.httpGet.path -eq '/health/ready' }).Count -ne 1) {
    throw 'Expected Enrollments liveness and readiness probes.'
}
Write-Output 'Container environment and release templates have expected security properties; Azure behavior remains unverified.'
