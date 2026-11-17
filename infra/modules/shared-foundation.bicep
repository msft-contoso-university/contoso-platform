targetScope = 'resourceGroup'

param location string = resourceGroup().location
param networkName string
param runnerSecurityGroupName string
param natGatewayName string
param natPublicIpName string
param storageAccountName string
param identityName string
param workspaceName string
param devInsightsName string
param stagingInsightsName string
param registryName string
param dailyQuotaGb int
param addressPrefix string
param runnerSubnetPrefix string
param endpointSubnetPrefix string
param applicationSubnets array
@minLength(1)
param runnerHttpsEgressPrefixes array
param tags object

module network './shared-network.bicep' = {
  name: 'shared-network'
  params: {
    location: location
    networkName: networkName
    runnerSecurityGroupName: runnerSecurityGroupName
    natGatewayName: natGatewayName
    natPublicIpName: natPublicIpName
    addressPrefix: addressPrefix
    runnerSubnetPrefix: runnerSubnetPrefix
    endpointSubnetPrefix: endpointSubnetPrefix
    applicationSubnets: applicationSubnets
    runnerHttpsEgressPrefixes: runnerHttpsEgressPrefixes
    tags: tags
  }
}

module execution './private-execution-storage.bicep' = {
  name: 'private-execution-storage'
  params: {
    location: location
    storageAccountName: storageAccountName
    identityName: identityName
    runnerSubnetResourceId: network.outputs.runnerSubnetResourceId
    privateEndpointSubnetResourceId: network.outputs.endpointSubnetResourceId
    filePrivateDnsZoneResourceId: network.outputs.filePrivateDnsZoneResourceId
    tags: tags
  }
}

module sharedServices './shared-observability-registry.bicep' = {
  name: 'shared-observability-registry'
  params: {
    location: location
    workspaceName: workspaceName
    devInsightsName: devInsightsName
    stagingInsightsName: stagingInsightsName
    registryName: registryName
    dailyQuotaGb: dailyQuotaGb
    endpointSubnetResourceId: network.outputs.endpointSubnetResourceId
    registryPrivateDnsZoneResourceId: network.outputs.registryPrivateDnsZoneResourceId
    tags: tags
  }
}

output networkResourceId string = network.outputs.networkResourceId
output runnerSubnetResourceId string = network.outputs.runnerSubnetResourceId
output endpointSubnetResourceId string = network.outputs.endpointSubnetResourceId
output filePrivateDnsZoneResourceId string = network.outputs.filePrivateDnsZoneResourceId
output sqlPrivateDnsZoneResourceId string = network.outputs.sqlPrivateDnsZoneResourceId
output appServicePrivateDnsZoneResourceId string = network.outputs.appServicePrivateDnsZoneResourceId
output registryPrivateDnsZoneResourceId string = network.outputs.registryPrivateDnsZoneResourceId
output executionIdentityResourceId string = execution.outputs.identityResourceId
output executionStorageAccountResourceId string = execution.outputs.storageAccountResourceId
output workspaceResourceId string = sharedServices.outputs.workspaceResourceId
output devInsightsResourceId string = sharedServices.outputs.devInsightsResourceId
output stagingInsightsResourceId string = sharedServices.outputs.stagingInsightsResourceId
output registryResourceId string = sharedServices.outputs.registryResourceId
output registryLoginServer string = sharedServices.outputs.registryLoginServer
