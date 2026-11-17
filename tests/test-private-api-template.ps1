$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$json = & az bicep build --file (Join-Path $PSScriptRoot '..\infra\modules\private-api-app.bicep') --stdout
if ($LASTEXITCODE -ne 0) { throw 'Private API template did not compile.' }
$template = ($json | Out-String) | ConvertFrom-Json
$sites = @($template.resources | Where-Object type -eq 'Microsoft.Web/sites')
if ($sites.Count -ne 1) { throw 'Expected exactly one App Service.' }
$site = $sites[0]
if ($site.identity.type -ne 'UserAssigned' -or
    -not $site.properties.httpsOnly -or
    $site.properties.publicNetworkAccess -ne 'Disabled' -or
    $site.properties.siteConfig.minTlsVersion -ne '1.2' -or
    $site.properties.siteConfig.ftpsState -ne 'Disabled' -or
    -not $site.properties.siteConfig.vnetRouteAllEnabled) {
    throw 'Private API security configuration is incomplete.'
}
$policies = @($template.resources | Where-Object type -eq 'Microsoft.Web/sites/basicPublishingCredentialsPolicies')
if ($policies.Count -ne 2 -or @($policies | Where-Object { $_.properties.allow }).Count -ne 0) {
    throw 'FTP and SCM basic publishing credentials must both be disabled.'
}
$endpoints = @($template.resources | Where-Object type -eq 'Microsoft.Network/privateEndpoints')
$zones = @($template.resources | Where-Object type -eq 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups')
if ($endpoints.Count -ne 1 -or $zones.Count -ne 1 -or
    $endpoints[0].properties.privateLinkServiceConnections[0].properties.groupIds[0] -ne 'sites') {
    throw 'Expected an App Service private endpoint and DNS zone group.'
}
$sqlSetting = @($site.properties.siteConfig.appSettings | Where-Object { $_.value -like '*Authentication=Active Directory Managed Identity*' })
if ($sqlSetting.Count -ne 1 -or $sqlSetting[0].value -notlike '*TrustServerCertificate=False*') {
    throw 'Expected an encrypted managed-identity SQL connection.'
}
$json = & az bicep build --file (Join-Path $PSScriptRoot '..\infra\modules\telemetry-access.bicep') --stdout
if ($LASTEXITCODE -ne 0) { throw 'Telemetry access template did not compile.' }
$telemetry = ($json | Out-String) | ConvertFrom-Json
$roles = @($telemetry.resources | Where-Object type -eq 'Microsoft.Authorization/roleAssignments')
if ($roles.Count -ne 1 -or $roles[0].scope -notlike "*Microsoft.Insights/components*" -or
    $roles[0].properties.roleDefinitionId -notlike '*3913510d-42f4-4e42-8a64-420c390055eb*' -or
    $roles[0].properties.principalType -ne 'ServicePrincipal') {
    throw 'Expected the monitoring publisher role scoped to one Application Insights component.'
}
Write-Output 'Compiled private API security invariants passed; Azure behavior remains unverified.'
