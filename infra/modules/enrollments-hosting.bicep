targetScope = 'resourceGroup'

param suffix string
param location string
param networkId string
param infrastructureSubnetId string
param infrastructureResourceGroupName string
param sharedResourceGroup string
param executionStorageName string
param workspaceResourceId string
param insightsName string
param registryName string
param tags object

resource runtimeIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-adlc-${suffix}-enrollments'
  location: location
  tags: tags
}

resource migrationIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-adlc-${suffix}-enrollments-migration'
  location: location
  tags: tags
}

module registryAccess './registry-pull-access.bicep' = {
  name: 'enrollments-registry-access'
  scope: resourceGroup(sharedResourceGroup)
  params: {
    registryName: registryName
    principalId: runtimeIdentity.properties.principalId
  }
}

module telemetry './telemetry-access.bicep' = {
  name: 'enrollments-telemetry'
  scope: resourceGroup(sharedResourceGroup)
  params: {
    insightsName: insightsName
    principalId: runtimeIdentity.properties.principalId
  }
}

module migrationStorage './execution-storage-access.bicep' = {
  name: 'enrollments-migration-storage'
  scope: resourceGroup(sharedResourceGroup)
  params: {
    storageAccountName: executionStorageName
    principalId: migrationIdentity.properties.principalId
  }
}

resource environment 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: 'cae-adlc-${suffix}'
  location: location
  tags: tags
  properties: {
    infrastructureResourceGroup: infrastructureResourceGroupName
    appLogsConfiguration: {
      destination: 'azure-monitor'
    }
    vnetConfiguration: {
      internal: true
      infrastructureSubnetId: infrastructureSubnetId
    }
    workloadProfiles: [
      {
        name: 'Consumption'
        workloadProfileType: 'Consumption'
      }
    ]
  }
}

resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'adlc-observability'
  scope: environment
  properties: {
    workspaceId: workspaceResourceId
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

module dns './container-dns.bicep' = {
  name: 'enrollments-private-dns'
  params: {
    domain: environment.properties.defaultDomain
    staticIp: environment.properties.staticIp
    networkId: networkId
    tags: tags
  }
}

output environmentId string = environment.id
output defaultDomain string = environment.properties.defaultDomain
output infrastructureResourceGroup string = infrastructureResourceGroupName
output runtimeIdentityName string = runtimeIdentity.name
output runtimeIdentityResourceId string = runtimeIdentity.id
output runtimeIdentityPrincipalId string = runtimeIdentity.properties.principalId
output runtimeIdentityClientId string = runtimeIdentity.properties.clientId
output registryPullRoleId string = registryAccess.outputs.roleAssignmentId
output migrationIdentityName string = migrationIdentity.name
output migrationIdentityResourceId string = migrationIdentity.id
output migrationIdentityClientId string = migrationIdentity.properties.clientId
output migrationStorageRoleId string = migrationStorage.outputs.roleAssignmentResourceId
