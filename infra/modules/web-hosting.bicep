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
    }
  }
}

resource appSettings 'Microsoft.Web/sites/config@2023-12-01' = {
  parent: app
  name: 'appsettings'
  properties: {
    AzureAd__TenantId: tenant().tenantId
    AzureAd__ClientId: webClientId
    AzureAd__ClientCredentials__0__SourceType: 'SignedAssertionFromManagedIdentity'
    AzureAd__ClientCredentials__0__ManagedIdentityClientId: identity.properties.clientId
    AZURE_CLIENT_ID: identity.properties.clientId
    APPLICATIONINSIGHTS_CONNECTION_STRING: telemetry.outputs.connectionString
    Services__Students__BaseUrl: 'https://${studentsHost}/'
    Services__Students__ReadScopes__0: studentsReadScope
    Services__Academics__BaseUrl: 'https://${academicsHost}/'
    Services__Academics__ReadScopes__0: academicsReadScope
    Services__Enrollments__BaseUrl: 'https://${enrollmentsHost}/'
    Services__Enrollments__ReadScopes__0: enrollmentsReadScope
    Services__Enrollments__WriteScopes__0: enrollmentsReadScope
    Services__Enrollments__WriteScopes__1: enrollmentsWriteScope
    WEBSITES_ENABLE_APP_SERVICE_STORAGE: 'true'
    DataProtection__KeyPath: '/home/data-protection-keys'
    AllowedHosts: app.properties.defaultHostName
    Hosting__AppServiceHttpsOnly: 'true'
    ASPNETCORE_FORWARDEDHEADERS_ENABLED: 'false'
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
