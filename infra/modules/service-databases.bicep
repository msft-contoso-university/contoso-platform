targetScope = 'resourceGroup'

param location string = resourceGroup().location
param serverName string
param bootstrapPrincipalId string
param bootstrapPrincipalName string
param endpointSubnetResourceId string
param sqlPrivateDnsZoneResourceId string
param databaseSku object
param tags object

var databaseNames = [
  'students'
  'academics'
  'enrollments'
]

resource server 'Microsoft.Sql/servers@2022-05-01-preview' = {
  name: serverName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  tags: tags
  properties: {
    administrators: {
      administratorType: 'ActiveDirectory'
      principalType: 'Application'
      login: bootstrapPrincipalName
      sid: bootstrapPrincipalId
      tenantId: subscription().tenantId
      azureADOnlyAuthentication: true
    }
    minimalTlsVersion: '1.2'
    publicNetworkAccess: 'Disabled'
  }
}

resource connectionPolicy 'Microsoft.Sql/servers/connectionPolicies@2021-11-01' = {
  parent: server
  name: 'default'
  properties: {
    connectionType: 'Proxy'
  }
}

resource databases 'Microsoft.Sql/servers/databases@2022-05-01-preview' = [
  for database in databaseNames: {
    parent: server
    name: database
    location: location
    sku: databaseSku
    tags: tags
    properties: {
      collation: 'SQL_Latin1_General_CP1_CI_AS'
    }
  }
]

module privateEndpoint 'br/public:avm/res/network/private-endpoint:0.9.1' = {
  name: '${serverName}-private-endpoint'
  params: {
    name: '${serverName}-pe'
    location: location
    subnetResourceId: endpointSubnetResourceId
    privateLinkServiceConnections: [
      {
        name: '${serverName}-connection'
        properties: {
          groupIds: [
            'sqlServer'
          ]
          privateLinkServiceId: server.id
        }
      }
    ]
    privateDnsZoneGroup: {
      name: 'default'
      privateDnsZoneGroupConfigs: [
        {
          name: 'sql'
          privateDnsZoneResourceId: sqlPrivateDnsZoneResourceId
        }
      ]
    }
    tags: tags
    enableTelemetry: false
  }
}

output serverResourceId string = server.id
output serverIdentityPrincipalId string = server.identity.principalId
output serverFullyQualifiedDomainName string = server.properties.fullyQualifiedDomainName
output databaseResourceIds array = [for (database, index) in databaseNames: databases[index].id]
