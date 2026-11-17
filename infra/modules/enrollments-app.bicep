targetScope = 'resourceGroup'

param suffix string
param location string
param environmentId string
param runtimeIdentityId string
param runtimeIdentityClientId string
param insightsResourceGroup string
param insightsName string
param registryLoginServer string
@description('64 hexadecimal characters of the approved immutable SHA-256 image digest.')
@minLength(64)
@maxLength(64)
param imageSha256Hex string
param sqlServerName string
@minLength(1)
param apiAudience string
param studentsHost string
param studentsScope string
param academicsHost string
param academicsScope string
param tags object

resource insights 'Microsoft.Insights/components@2020-02-02' existing = {
  scope: resourceGroup(insightsResourceGroup)
  name: insightsName
}

resource app 'Microsoft.App/containerApps@2024-03-01' = {
  name: 'ca-adlc-${suffix}-enrollments'
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${runtimeIdentityId}': {}
    }
  }
  properties: {
    managedEnvironmentId: environmentId
    workloadProfileName: 'Consumption'
    configuration: {
      activeRevisionsMode: 'Single'
      registries: [
        {
          server: registryLoginServer
          identity: runtimeIdentityId
        }
      ]
      ingress: {
        external: true
        targetPort: 8080
        transport: 'auto'
        allowInsecure: false
      }
    }
    template: {
      containers: [
        {
          name: 'enrollments'
          image: '${registryLoginServer}/contoso-enrollments@sha256:${imageSha256Hex}'
          resources: {
            cpu: json('0.5')
            memory: '1Gi'
          }
          env: [
            { name: 'ASPNETCORE_URLS', value: 'http://+:8080' }
            { name: 'AzureAd__TenantId', value: tenant().tenantId }
            { name: 'AzureAd__Audience', value: apiAudience }
            { name: 'AZURE_CLIENT_ID', value: runtimeIdentityClientId }
            { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: insights.properties.ConnectionString }
            { name: 'ConnectionStrings__Enrollments', value: 'Server=tcp:${sqlServerName}.database.windows.net,1433;Database=enrollments;Authentication=Active Directory Managed Identity;User Id=${runtimeIdentityClientId};Encrypt=True;TrustServerCertificate=False' }
            { name: 'Students__BaseUrl', value: 'https://${studentsHost}/' }
            { name: 'Students__Scope', value: studentsScope }
            { name: 'Academics__BaseUrl', value: 'https://${academicsHost}/' }
            { name: 'Academics__Scope', value: academicsScope }
          ]
          probes: [
            {
              type: 'Liveness'
              httpGet: {
                path: '/health/live'
                port: 8080
                scheme: 'HTTP'
              }
            }
            {
              type: 'Readiness'
              httpGet: {
                path: '/health/ready'
                port: 8080
                scheme: 'HTTP'
              }
            }
          ]
        }
      ]
      scale: {
        minReplicas: 1
        maxReplicas: 2
      }
    }
  }
}

output appId string = app.id
output appFqdn string = app.properties.configuration.ingress.fqdn
