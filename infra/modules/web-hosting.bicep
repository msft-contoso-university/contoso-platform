targetScope = 'resourceGroup'

param suffix string
param location string
param servicePlanId string
param appSubnetId string
param endpointSubnetId string
param appServiceDnsZoneId string
param insightsResourceGroup string
param insightsName string
@minLength(1)
param webClientId string
@minLength(1)
param studentsHost string
@minLength(1)
param academicsHost string
@minLength(1)
param enrollmentsHost string
@minLength(1)
param studentsReadScope string
@minLength(1)
param academicsReadScope string
@minLength(1)
param enrollmentsReadScope string
@minLength(1)
param enrollmentsWriteScope string
param tags object

var appName = 'app-adlc-${suffix}-web'
var appHostName = '${appName}.azurewebsites.net'

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-adlc-${suffix}-web'
  location: location
  tags: tags
}

module telemetry './telemetry-access.bicep' = {
  name: '${appName}-telemetry'
  scope: resourceGroup(insightsResourceGroup)
  params: {
    insightsName: insightsName
    principalId: identity.properties.principalId
  }
}

resource app 'Microsoft.Web/sites@2023-12-01' = {
  name: appName
  location: location
  kind: 'app,linux'
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${identity.id}': {}
    }
  }
  properties: {
    serverFarmId: servicePlanId
    httpsOnly: true
    publicNetworkAccess: 'Enabled'
    virtualNetworkSubnetId: appSubnetId
    siteConfig: {
      linuxFxVersion: 'DOTNETCORE|10.0'
      appCommandLine: 'dotnet Contoso.Web.dll'
      minTlsVersion: '1.2'
      ftpsState: 'Disabled'
      alwaysOn: true
      vnetRouteAllEnabled: true
      healthCheckPath: '/health/live'
      ipSecurityRestrictionsDefaultAction: 'Allow'
      scmIpSecurityRestrictionsUseMain: false
      scmIpSecurityRestrictionsDefaultAction: 'Deny'
      appSettings: [
        { name: 'AzureAd__TenantId', value: tenant().tenantId }
        { name: 'AzureAd__ClientId', value: webClientId }
        { name: 'AzureAd__ClientCredentials__0__SourceType', value: 'SignedAssertionFromManagedIdentity' }
        { name: 'AzureAd__ClientCredentials__0__ManagedIdentityClientId', value: identity.properties.clientId }
        { name: 'AZURE_CLIENT_ID', value: identity.properties.clientId }
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: telemetry.outputs.connectionString }
        { name: 'Services__Students__BaseUrl', value: 'https://${studentsHost}/' }
        { name: 'Services__Students__ReadScopes__0', value: studentsReadScope }
        { name: 'Services__Academics__BaseUrl', value: 'https://${academicsHost}/' }
        { name: 'Services__Academics__ReadScopes__0', value: academicsReadScope }
        { name: 'Services__Enrollments__BaseUrl', value: 'https://${enrollmentsHost}/' }
        { name: 'Services__Enrollments__ReadScopes__0', value: enrollmentsReadScope }
        { name: 'Services__Enrollments__WriteScopes__0', value: enrollmentsReadScope }
        { name: 'Services__Enrollments__WriteScopes__1', value: enrollmentsWriteScope }
        { name: 'WEBSITES_ENABLE_APP_SERVICE_STORAGE', value: 'true' }
        { name: 'DataProtection__KeyPath', value: '/home/data-protection-keys' }
        { name: 'AllowedHosts', value: appHostName }
        { name: 'Hosting__AppServiceHttpsOnly', value: 'true' }
        { name: 'ASPNETCORE_FORWARDEDHEADERS_ENABLED', value: 'false' }
      ]
    }
  }
}

resource ftpPublishing 'Microsoft.Web/sites/basicPublishingCredentialsPolicies@2023-12-01' = {
  parent: app
  name: 'ftp'
  properties: {
    allow: false
  }
}

resource scmPublishing 'Microsoft.Web/sites/basicPublishingCredentialsPolicies@2023-12-01' = {
  parent: app
  name: 'scm'
  properties: {
    allow: false
  }
}

resource endpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: 'pe-${appName}'
  location: location
  tags: tags
  properties: {
    subnet: {
      id: endpointSubnetId
    }
    privateLinkServiceConnections: [
      {
        name: 'app'
        properties: {
          privateLinkServiceId: app.id
          groupIds: [
            'sites'
          ]
        }
      }
    ]
  }
}

resource dnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: endpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'appservice'
        properties: {
          privateDnsZoneId: appServiceDnsZoneId
        }
      }
    ]
  }
}

output appResourceId string = app.id
output appHostName string = app.properties.defaultHostName
output identityResourceId string = identity.id
output identityPrincipalId string = identity.properties.principalId
output identityClientId string = identity.properties.clientId
