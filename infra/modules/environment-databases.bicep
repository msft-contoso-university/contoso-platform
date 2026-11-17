targetScope = 'resourceGroup'

param location string = resourceGroup().location
param serverName string
param bootstrapIdentityName string
param executionStorageResourceGroupName string
param executionStorageAccountName string
param endpointSubnetResourceId string
param sqlPrivateDnsZoneResourceId string
param databaseSku object
param tags object

module bootstrapIdentity 'br/public:avm/res/managed-identity/user-assigned-identity:0.6.0' = {
  name: '${bootstrapIdentityName}-deployment'
  params: {
    name: bootstrapIdentityName
    location: location
    tags: tags
    enableTelemetry: false
  }
}

module storageAccess './execution-storage-access.bicep' = {
  scope: resourceGroup(executionStorageResourceGroupName)
  name: '${bootstrapIdentityName}-file-access'
  params: {
    storageAccountName: executionStorageAccountName
    principalId: bootstrapIdentity.outputs.principalId
  }
}

module databases './service-databases.bicep' = {
  name: '${serverName}-databases'
  params: {
    location: location
    serverName: serverName
    bootstrapPrincipalId: bootstrapIdentity.outputs.principalId
    bootstrapPrincipalName: bootstrapIdentityName
    endpointSubnetResourceId: endpointSubnetResourceId
    sqlPrivateDnsZoneResourceId: sqlPrivateDnsZoneResourceId
    databaseSku: databaseSku
    tags: tags
  }
}

output bootstrapIdentityResourceId string = bootstrapIdentity.outputs.resourceId
output bootstrapIdentityClientId string = bootstrapIdentity.outputs.clientId
output storageRoleAssignmentResourceId string = storageAccess.outputs.roleAssignmentResourceId
output sqlServerResourceId string = databases.outputs.serverResourceId
output sqlServerIdentityPrincipalId string = databases.outputs.serverIdentityPrincipalId
output sqlServerFqdn string = databases.outputs.serverFullyQualifiedDomainName
output databaseResourceIds array = databases.outputs.databaseResourceIds
