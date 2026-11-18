targetScope = 'resourceGroup'

param name string
param location string = resourceGroup().location
param bootstrapIdentityResourceId string
param bootstrapIdentityClientId string
param storageAccountResourceId string
param runnerSubnetResourceId string
param sqlServerName string

@description('Entries with database, runtime and migration identity names and client IDs.')
@minLength(3)
@maxLength(3)
param targets array
param tags object

module grants 'br/public:avm/res/resources/deployment-script:0.5.2' = {
  name: '${name}-deployment'
  params: {
    name: name
    location: location
    kind: 'AzureCLI'
    azCliVersion: '2.89.1'
    managedIdentities: {
      userAssignedResourceIds: [
        bootstrapIdentityResourceId
      ]
    }
    storageAccountResourceId: storageAccountResourceId
    subnetResourceIds: [
      runnerSubnetResourceId
    ]
    environmentVariables: [
      {
        name: 'SQL_SERVER'
        value: sqlServerName
      }
      {
        name: 'BOOTSTRAP_CLIENT_ID'
        value: bootstrapIdentityClientId
      }
      {
        name: 'GRANT_TARGETS'
        value: string(targets)
      }
    ]
    scriptContent: concat('set -eu\npython3 - <<\'PY\'\n', loadTextContent('sql-grants.py'), '\nPY\n')
    cleanupPreference: 'Always'
    retentionInterval: 'P1D'
    timeout: 'PT20M'
    tags: tags
    enableTelemetry: false
  }
}

output result object = grants.outputs.outputs
