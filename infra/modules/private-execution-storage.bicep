targetScope = 'resourceGroup'

@description('Azure region of the stack-owned execution resources.')
param location string = resourceGroup().location

@description('Globally unique storage account name owned by this stack.')
@minLength(3)
@maxLength(24)
param storageAccountName string

@description('Name of the dedicated deployment-script identity.')
param identityName string

@description('Delegated deployment-script subnet with the Microsoft.Storage service endpoint enabled.')
param runnerSubnetResourceId string

@description('Stack-owned subnet for the Azure Files private endpoint.')
param privateEndpointSubnetResourceId string

@description('Stack-owned privatelink.file.core.windows.net zone linked to the runner VNet.')
param filePrivateDnsZoneResourceId string

@description('Stack ownership tags.')
param tags object

module identity 'br/public:avm/res/managed-identity/user-assigned-identity:0.6.0' = {
  name: '${identityName}-deployment'
  params: {
    name: identityName
    location: location
    tags: tags
    enableTelemetry: false
  }
}

module scriptStorage 'br/public:avm/res/storage/storage-account:0.9.1' = {
  name: '${storageAccountName}-deployment'
  params: {
    name: storageAccountName
    location: location
    kind: 'StorageV2'
    skuName: 'Standard_LRS'
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: true
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Deny'
      virtualNetworkRules: [
        {
          id: runnerSubnetResourceId
          action: 'Allow'
        }
      ]
    }
    privateEndpoints: [
      {
        service: 'file'
        subnetResourceId: privateEndpointSubnetResourceId
        privateDnsZoneResourceIds: [
          filePrivateDnsZoneResourceId
        ]
      }
    ]
    roleAssignments: [
      {
        principalId: identity.outputs.principalId
        principalType: 'ServicePrincipal'
        roleDefinitionIdOrName: '69566ab7-960f-475b-8e7c-b3118f30c6bd'
      }
    ]
    tags: tags
    enableTelemetry: false
  }
}

output identityResourceId string = identity.outputs.resourceId
output storageAccountResourceId string = scriptStorage.outputs.resourceId
