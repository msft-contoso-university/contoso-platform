targetScope = 'resourceGroup'

@description('Name of the stack-owned probe deployment script.')
param name string

@description('Azure region of the deployment script.')
param location string = resourceGroup().location

@description('Resource ID of the stack-owned user-assigned execution identity.')
param identityResourceId string

@description('Resource ID of the stack-owned private script storage account.')
param storageAccountResourceId string

@description('Resource ID of the delegated ACI subnet in the stack VNet.')
param subnetResourceId string

@description('Private SCM, SQL, and registry endpoints to verify. Each entry has host and kind (https or sql).')
@minLength(1)
@maxLength(8)
param endpoints array

@description('Stack ownership tags.')
param tags object

module probe 'br/public:avm/res/resources/deployment-script:0.5.2' = {
  name: '${name}-deployment'
  params: {
    name: name
    location: location
    kind: 'AzureCLI'
    azCliVersion: '2.89.1'
    managedIdentities: {
      userAssignedResourceIds: [
        identityResourceId
      ]
    }
    storageAccountResourceId: storageAccountResourceId
    subnetResourceIds: [
      subnetResourceId
    ]
    environmentVariables: [
      {
        name: 'PROBE_ENDPOINTS'
        value: string(endpoints)
      }
    ]
    scriptContent: concat('set -eu\npython3 - <<\'PY\'\n', loadTextContent('private-probe.py'), '\nPY\n')
    cleanupPreference: 'Always'
    retentionInterval: 'P1D'
    timeout: 'PT10M'
    tags: tags
    enableTelemetry: false
  }
}

@description('Probe status produced by the awaited deployment script, not proof of application deployment.')
output result object = probe.outputs.outputs
