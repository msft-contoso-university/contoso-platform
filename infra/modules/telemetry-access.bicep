targetScope = 'resourceGroup'

param insightsName string
param principalId string

resource insights 'Microsoft.Insights/components@2020-02-02' existing = {
  name: insightsName
}

resource telemetryPublisher 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(insights.id, principalId, '3913510d-42f4-4e42-8a64-420c390055eb')
  scope: insights
  properties: {
    principalId: principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '3913510d-42f4-4e42-8a64-420c390055eb')
  }
}

output connectionString string = insights.properties.ConnectionString
