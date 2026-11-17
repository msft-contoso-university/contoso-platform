targetScope = 'resourceGroup'

@allowed([
  'students'
  'academics'
])
param service string
param suffix string
param location string
param servicePlanId string
param appSubnetId string
param endpointSubnetId string
param appServiceDnsZoneId string
param insightsResourceGroup string
param insightsName string
param sqlServerName string
@minLength(1)
param apiAudience string
param tags object

var appName = 'app-adlc-${suffix}-${service}'
var identityName = 'id-adlc-${suffix}-${service}'

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: identityName
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
    publicNetworkAccess: 'Disabled'
    virtualNetworkSubnetId: appSubnetId
    siteConfig: {
      linuxFxVersion: 'DOTNETCORE|10.0'
      minTlsVersion: '1.2'
      ftpsState: 'Disabled'
      alwaysOn: true
      vnetRouteAllEnabled: true
      appSettings: [
        {
          name: 'AzureAd__TenantId'
          value: tenant().tenantId
        }
        {
          name: 'AzureAd__Audience'
          value: apiAudience
        }
        {
          name: 'ConnectionStrings__${service == 'students' ? 'Students' : 'Academics'}'
          value: 'Server=tcp:${sqlServerName}.database.windows.net,1433;Database=${service};Authentication=Active Directory Managed Identity;User Id=${identity.properties.clientId};Encrypt=True;TrustServerCertificate=False'
        }
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: telemetry.outputs.connectionString
        }
        {
          name: 'AZURE_CLIENT_ID'
          value: identity.properties.clientId
        }
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
output runtimeIdentityName string = identity.name
output runtimeIdentityPrincipalId string = identity.properties.principalId
output runtimeIdentityClientId string = identity.properties.clientId
