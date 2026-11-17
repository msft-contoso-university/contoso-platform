$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$json = & az bicep build --file (Join-Path $PSScriptRoot '..\infra\modules\web-hosting.bicep') --stdout
if ($LASTEXITCODE -ne 0) { throw 'Web hosting template did not compile.' }
$template = ($json | Out-String) | ConvertFrom-Json
$sites = @($template.resources | Where-Object type -eq 'Microsoft.Web/sites')
$identities = @($template.resources | Where-Object type -eq 'Microsoft.ManagedIdentity/userAssignedIdentities')
if ($sites.Count -ne 1 -or $identities.Count -ne 1) { throw 'Expected one Web app and one managed identity.' }
$site = $sites[0]
if ($site.identity.type -ne 'UserAssigned' -or
    @($site.identity.userAssignedIdentities.PSObject.Properties).Count -ne 1 -or
    -not $site.properties.httpsOnly -or $site.properties.publicNetworkAccess -ne 'Enabled' -or
    $site.properties.siteConfig.minTlsVersion -ne '1.2' -or
    $site.properties.siteConfig.ftpsState -ne 'Disabled' -or
    -not $site.properties.siteConfig.vnetRouteAllEnabled -or
    $site.properties.siteConfig.scmIpSecurityRestrictionsUseMain -or
    $site.properties.siteConfig.scmIpSecurityRestrictionsDefaultAction -ne 'Deny') {
    throw 'Web public HTTPS, private SCM or managed identity configuration is incomplete.'
}
$policies = @($template.resources | Where-Object type -eq 'Microsoft.Web/sites/basicPublishingCredentialsPolicies')
$endpoints = @($template.resources | Where-Object type -eq 'Microsoft.Network/privateEndpoints')
$zones = @($template.resources | Where-Object type -eq 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups')
if ($policies.Count -ne 2 -or @($policies | Where-Object { $_.properties.allow }).Count -ne 0 -or
    $endpoints.Count -ne 1 -or $zones.Count -ne 1 -or
    $endpoints[0].properties.privateLinkServiceConnections[0].properties.groupIds[0] -ne 'sites') {
    throw 'Expected disabled basic publishing and an App Service private endpoint with DNS.'
}
$settings = @{}
foreach ($setting in $site.properties.siteConfig.appSettings) { $settings[$setting.name] = $setting.value }
if ($settings['AzureAd__ClientCredentials__0__SourceType'] -ne 'SignedAssertionFromManagedIdentity' -or
    $settings['WEBSITES_ENABLE_APP_SERVICE_STORAGE'] -ne 'true' -or
    $settings['DataProtection__KeyPath'] -ne '/home/data-protection-keys' -or
    $settings['Hosting__AppServiceHttpsOnly'] -ne 'true' -or
    $settings['ASPNETCORE_FORWARDEDHEADERS_ENABLED'] -ne 'false' -or
    $settings.ContainsKey('WEBSITE_SITE_NAME') -or $settings.ContainsKey('WEBSITE_HOSTNAME') -or
    $settings['Services__Enrollments__WriteScopes__0'] -ne $settings['Services__Enrollments__ReadScopes__0'] -or
    -not $settings.ContainsKey('Services__Enrollments__WriteScopes__1') -or
    -not $settings.ContainsKey('AllowedHosts') -or
    @($settings.Keys | Where-Object { $_ -match '(?i)secret|password|connectionstrings__' }).Count -ne 0) {
    throw 'Web identity, persistent key path, scopes or secretless configuration is incomplete.'
}
Write-Output 'Compiled Web hosting invariants passed; network, identity and storage behavior remain unverified.'
