targetScope = 'resourceGroup'

param suffix string
param location string
param appSubnetId string
param endpointSubnetId string
param appServiceDnsZoneId string
param insightsResourceGroup string
param insightsName string
param sqlServerName string
param studentsAudience string
param academicsAudience string
param tags object

resource plan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: 'asp-adlc-${suffix}'
  location: location
  kind: 'linux'
  tags: tags
  sku: {
    name: 'P0v3'
    tier: 'PremiumV3'
    capacity: 1
  }
  properties: {
    reserved: true
  }
}

module students './private-api-app.bicep' = {
  name: 'students-api'
  params: {
    service: 'students'
    suffix: suffix
    location: location
    servicePlanId: plan.id
    appSubnetId: appSubnetId
    endpointSubnetId: endpointSubnetId
    appServiceDnsZoneId: appServiceDnsZoneId
    insightsResourceGroup: insightsResourceGroup
    insightsName: insightsName
    sqlServerName: sqlServerName
    apiAudience: studentsAudience
    tags: tags
  }
}

module academics './private-api-app.bicep' = {
  name: 'academics-api'
  params: {
    service: 'academics'
    suffix: suffix
    location: location
    servicePlanId: plan.id
    appSubnetId: appSubnetId
    endpointSubnetId: endpointSubnetId
    appServiceDnsZoneId: appServiceDnsZoneId
    insightsResourceGroup: insightsResourceGroup
    insightsName: insightsName
    sqlServerName: sqlServerName
    apiAudience: academicsAudience
    tags: tags
  }
}

output servicePlanId string = plan.id
output studentsAppId string = students.outputs.appResourceId
output studentsHostName string = students.outputs.appHostName
output studentsIdentityName string = students.outputs.runtimeIdentityName
output studentsIdentityPrincipalId string = students.outputs.runtimeIdentityPrincipalId
output academicsAppId string = academics.outputs.appResourceId
output academicsHostName string = academics.outputs.appHostName
output academicsIdentityName string = academics.outputs.runtimeIdentityName
output academicsIdentityPrincipalId string = academics.outputs.runtimeIdentityPrincipalId
