targetScope = 'resourceGroup'

@description('Azure region for the stack-owned network.')
param location string = resourceGroup().location

@description('Name of the shared stack VNet.')
param networkName string

@description('Names for the runner network security group and NAT gateway.')
param runnerSecurityGroupName string
param natGatewayName string
param natPublicIpName string

@description('Non-overlapping address space and subnet prefixes selected for this stack.')
param addressPrefix string
param runnerSubnetPrefix string
param endpointSubnetPrefix string

@description('Additional application subnets in the same VNet, supplied by the stack composition.')
param applicationSubnets array

@description('Explicit public CIDRs required for trusted runner HTTPS egress. Never use a default route or wildcard.')
@minLength(1)
param runnerHttpsEgressPrefixes array

@description('Stack ownership tags.')
param tags object

module nat 'br/public:avm/res/network/nat-gateway:2.1.1' = {
  name: '${natGatewayName}-deployment'
  params: {
    name: natGatewayName
    location: location
    availabilityZone: -1
    publicIPAddresses: [
      {
        name: natPublicIpName
      }
    ]
    tags: tags
    enableTelemetry: false
  }
}

module runnerNsg 'br/public:avm/res/network/network-security-group:0.5.4' = {
  name: '${runnerSecurityGroupName}-deployment'
  params: {
    name: runnerSecurityGroupName
    location: location
    tags: tags
    enableTelemetry: false
    securityRules: [
      {
        name: 'Allow-Private-Endpoints'
        properties: {
          access: 'Allow'
          direction: 'Outbound'
          priority: 100
          protocol: 'Tcp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: endpointSubnetPrefix
          destinationPortRanges: [
            '443'
            '445'
            '1433'
          ]
        }
      }
      {
        name: 'Allow-Azure-DNS'
        properties: {
          access: 'Allow'
          direction: 'Outbound'
          priority: 110
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'AzurePlatformDNS'
          destinationPortRange: '53'
        }
      }
      {
        name: 'Allow-Storage'
        properties: {
          access: 'Allow'
          direction: 'Outbound'
          priority: 120
          protocol: 'Tcp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'Storage'
          destinationPortRanges: [
            '443'
            '445'
          ]
        }
      }
      {
        name: 'Allow-Explicit-HTTPS'
        properties: {
          access: 'Allow'
          direction: 'Outbound'
          priority: 130
          protocol: 'Tcp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefixes: runnerHttpsEgressPrefixes
          destinationPortRange: '443'
        }
      }
      {
        name: 'Deny-Other-Outbound'
        properties: {
          access: 'Deny'
          direction: 'Outbound'
          priority: 4096
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
      {
        name: 'Deny-Inbound'
        properties: {
          access: 'Deny'
          direction: 'Inbound'
          priority: 4096
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
    ]
  }
}

module network 'br/public:avm/res/network/virtual-network:0.9.0' = {
  name: '${networkName}-deployment'
  params: {
    name: networkName
    location: location
    addressPrefixes: [
      addressPrefix
    ]
    subnets: concat([
      {
        name: 'runner'
        addressPrefix: runnerSubnetPrefix
        delegation: 'Microsoft.ContainerInstance/containerGroups'
        serviceEndpoints: [
          'Microsoft.Storage'
        ]
        natGatewayResourceId: nat.outputs.resourceId
        networkSecurityGroupResourceId: runnerNsg.outputs.resourceId
        defaultOutboundAccess: false
      }
      {
        name: 'private-endpoints'
        addressPrefix: endpointSubnetPrefix
        privateEndpointNetworkPolicies: 'Disabled'
        defaultOutboundAccess: false
      }
    ], applicationSubnets)
    tags: tags
    enableTelemetry: false
  }
}

module privateDns 'br/public:avm/res/network/private-dns-zone:0.8.1' = [
  for (zone, index) in [
    'privatelink.file.core.windows.net'
    'privatelink.database.windows.net'
    'privatelink.azurewebsites.net'
    'privatelink.azurecr.io'
  ]: {
    name: 'private-dns-${index}'
    params: {
      name: zone
      virtualNetworkLinks: [
        {
          virtualNetworkResourceId: network.outputs.resourceId
          registrationEnabled: false
        }
      ]
      tags: tags
      enableTelemetry: false
    }
  }
]

output networkResourceId string = network.outputs.resourceId
output runnerSubnetResourceId string = '${network.outputs.resourceId}/subnets/runner'
output endpointSubnetResourceId string = '${network.outputs.resourceId}/subnets/private-endpoints'
output filePrivateDnsZoneResourceId string = privateDns[0].outputs.resourceId
output sqlPrivateDnsZoneResourceId string = privateDns[1].outputs.resourceId
output appServicePrivateDnsZoneResourceId string = privateDns[2].outputs.resourceId
output registryPrivateDnsZoneResourceId string = privateDns[3].outputs.resourceId
