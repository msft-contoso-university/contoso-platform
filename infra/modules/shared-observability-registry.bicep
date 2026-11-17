targetScope = 'resourceGroup'

param location string = resourceGroup().location
param workspaceName string
param devInsightsName string
param stagingInsightsName string
@minLength(5)
@maxLength(50)
param registryName string
param endpointSubnetResourceId string
param registryPrivateDnsZoneResourceId string

@description('Daily Log Analytics ingestion cap in GB. A cap can drop telemetry.')
param dailyQuotaGb int

param tags object

module workspace 'br/public:avm/res/operational-insights/workspace:0.9.1' = {
  name: 'shared-log-analytics'
  params: {
    name: workspaceName
    location: location
    dailyQuotaGb: dailyQuotaGb
    dataRetention: 30
    tags: tags
    enableTelemetry: false
  }
}

module devInsights 'br/public:avm/res/insights/component:0.8.0' = {
  name: 'dev-application-insights'
  params: {
    name: devInsightsName
    location: location
    workspaceResourceId: workspace.outputs.resourceId
    retentionInDays: 30
    disableLocalAuth: true
    tags: tags
    enableTelemetry: false
  }
}

module stagingInsights 'br/public:avm/res/insights/component:0.8.0' = {
  name: 'staging-application-insights'
  params: {
    name: stagingInsightsName
    location: location
    workspaceResourceId: workspace.outputs.resourceId
    retentionInDays: 30
    disableLocalAuth: true
    tags: tags
    enableTelemetry: false
  }
}

module registry 'br/public:avm/res/container-registry/registry:0.9.3' = {
  name: 'shared-container-registry'
  params: {
    name: registryName
    location: location
    acrSku: 'Premium'
    acrAdminUserEnabled: false
    publicNetworkAccess: 'Disabled'
    networkRuleBypassOptions: 'None'
    privateEndpoints: [
      {
        subnetResourceId: endpointSubnetResourceId
        privateDnsZoneGroup: {
          privateDnsZoneGroupConfigs: [
            {
              privateDnsZoneResourceId: registryPrivateDnsZoneResourceId
            }
          ]
        }
      }
    ]
    tags: tags
    enableTelemetry: false
  }
}

output workspaceResourceId string = workspace.outputs.resourceId
output devInsightsResourceId string = devInsights.outputs.resourceId
output stagingInsightsResourceId string = stagingInsights.outputs.resourceId
output registryResourceId string = registry.outputs.resourceId
output registryLoginServer string = registry.outputs.loginServer
