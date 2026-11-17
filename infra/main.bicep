targetScope = 'subscription'

@description('The single azd environment name for this disposable stack.')
param environmentName string

@description('An explicit stack generation identifier; never reuse an unrelated stack.')
param generation string

@description('The explicitly selected Azure region.')
param location string

@description('Shared VNet address space and non-overlapping subnet prefixes.')
param addressPrefix string
param runnerSubnetPrefix string
param endpointSubnetPrefix string
param applicationSubnets array

@description('Names of distinct, Microsoft.Web/serverFarms-delegated application subnets in the shared VNet.')
param devAppSubnetName string
param stagingAppSubnetName string

@description('Explicit audiences of the registered Students and Academics APIs for each environment.')
@minLength(1)
param devStudentsAudience string
@minLength(1)
param devAcademicsAudience string
@minLength(1)
param stagingStudentsAudience string
@minLength(1)
param stagingAcademicsAudience string

@description('Verified explicit public CIDRs permitted for runner HTTPS egress.')
@minLength(1)
param runnerHttpsEgressPrefixes array

@description('Explicit service database SKU.')
param databaseSku object

@description('Daily shared Log Analytics ingestion limit in GB; -1 means no cap.')
param dailyQuotaGb int

var suffix = uniqueString(subscription().id, environmentName, generation)
var sharedGroupName = 'rg-adlc-${suffix}-shared'
var devGroupName = 'rg-adlc-${suffix}-dev'
var stagingGroupName = 'rg-adlc-${suffix}-staging'
var tags = {
  'adlc-stack': environmentName
  'adlc-generation': generation
  'azd-env-name': environmentName
}
var sharedStorageName = 'adlc${suffix}'

resource sharedGroup 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: sharedGroupName
  location: location
  tags: union(tags, { 'adlc-stage': 'shared' })
}

resource devGroup 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: devGroupName
  location: location
  tags: union(tags, { 'adlc-stage': 'dev' })
}

resource stagingGroup 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: stagingGroupName
  location: location
  tags: union(tags, { 'adlc-stage': 'staging' })
}

module shared './modules/shared-foundation.bicep' = {
  name: 'adlc-shared-foundation'
  scope: sharedGroup
  params: {
    location: location
    networkName: 'vnet-adlc-${suffix}'
    runnerSecurityGroupName: 'nsg-adlc-runner-${suffix}'
    natGatewayName: 'nat-adlc-${suffix}'
    natPublicIpName: 'pip-adlc-${suffix}'
    storageAccountName: sharedStorageName
    identityName: 'id-adlc-execution-${suffix}'
    workspaceName: 'log-adlc-${suffix}'
    devInsightsName: 'appi-adlc-${suffix}-dev'
    stagingInsightsName: 'appi-adlc-${suffix}-staging'
    registryName: 'adlc${suffix}'
    dailyQuotaGb: dailyQuotaGb
    addressPrefix: addressPrefix
    runnerSubnetPrefix: runnerSubnetPrefix
    endpointSubnetPrefix: endpointSubnetPrefix
    applicationSubnets: applicationSubnets
    runnerHttpsEgressPrefixes: runnerHttpsEgressPrefixes
    tags: union(tags, { 'adlc-stage': 'shared' })
  }
}

module devDatabases './modules/environment-databases.bicep' = {
  name: 'adlc-dev-databases'
  scope: devGroup
  params: {
    location: location
    serverName: 'sql-adlc-${suffix}-dev'
    bootstrapIdentityName: 'id-adlc-${suffix}-dev-bootstrap'
    executionStorageResourceGroupName: sharedGroupName
    executionStorageAccountName: sharedStorageName
    endpointSubnetResourceId: shared.outputs.endpointSubnetResourceId
    sqlPrivateDnsZoneResourceId: shared.outputs.sqlPrivateDnsZoneResourceId
    databaseSku: databaseSku
    tags: union(tags, { 'adlc-stage': 'dev' })
  }
}

module stagingDatabases './modules/environment-databases.bicep' = {
  name: 'adlc-staging-databases'
  scope: stagingGroup
  params: {
    location: location
    serverName: 'sql-adlc-${suffix}-staging'
    bootstrapIdentityName: 'id-adlc-${suffix}-staging-bootstrap'
    executionStorageResourceGroupName: sharedGroupName
    executionStorageAccountName: sharedStorageName
    endpointSubnetResourceId: shared.outputs.endpointSubnetResourceId
    sqlPrivateDnsZoneResourceId: shared.outputs.sqlPrivateDnsZoneResourceId
    databaseSku: databaseSku
    tags: union(tags, { 'adlc-stage': 'staging' })
  }
}

module devApis './modules/private-api-hosting.bicep' = {
  name: 'adlc-dev-private-apis'
  scope: devGroup
  params: {
    suffix: '${suffix}-dev'
    location: location
    appSubnetId: '${shared.outputs.networkResourceId}/subnets/${devAppSubnetName}'
    endpointSubnetId: shared.outputs.endpointSubnetResourceId
    appServiceDnsZoneId: shared.outputs.appServicePrivateDnsZoneResourceId
    insightsResourceGroup: sharedGroupName
    insightsName: 'appi-adlc-${suffix}-dev'
    sqlServerName: 'sql-adlc-${suffix}-dev'
    studentsAudience: devStudentsAudience
    academicsAudience: devAcademicsAudience
    tags: union(tags, { 'adlc-stage': 'dev' })
  }
}

module stagingApis './modules/private-api-hosting.bicep' = {
  name: 'adlc-staging-private-apis'
  scope: stagingGroup
  params: {
    suffix: '${suffix}-staging'
    location: location
    appSubnetId: '${shared.outputs.networkResourceId}/subnets/${stagingAppSubnetName}'
    endpointSubnetId: shared.outputs.endpointSubnetResourceId
    appServiceDnsZoneId: shared.outputs.appServicePrivateDnsZoneResourceId
    insightsResourceGroup: sharedGroupName
    insightsName: 'appi-adlc-${suffix}-staging'
    sqlServerName: 'sql-adlc-${suffix}-staging'
    studentsAudience: stagingStudentsAudience
    academicsAudience: stagingAcademicsAudience
    tags: union(tags, { 'adlc-stage': 'staging' })
  }
}

output ADLC_STACK_NAME string = environmentName
output ADLC_STACK_GENERATION string = generation
output ADLC_SHARED_RESOURCE_GROUP string = sharedGroup.name
output ADLC_DEV_RESOURCE_GROUP string = devGroup.name
output ADLC_STAGING_RESOURCE_GROUP string = stagingGroup.name
output ADLC_EXECUTION_STORAGE_ID string = shared.outputs.executionStorageAccountResourceId
output ADLC_RUNNER_SUBNET_ID string = shared.outputs.runnerSubnetResourceId
output ADLC_DEV_SQL_BOOTSTRAP_IDENTITY_ID string = devDatabases.outputs.bootstrapIdentityResourceId
output ADLC_DEV_SQL_BOOTSTRAP_CLIENT_ID string = devDatabases.outputs.bootstrapIdentityClientId
output ADLC_DEV_SQL_SERVER_NAME string = 'sql-adlc-${suffix}-dev'
output ADLC_DEV_SQL_SERVER_IDENTITY_PRINCIPAL_ID string = devDatabases.outputs.sqlServerIdentityPrincipalId
output ADLC_STAGING_SQL_BOOTSTRAP_IDENTITY_ID string = stagingDatabases.outputs.bootstrapIdentityResourceId
output ADLC_STAGING_SQL_BOOTSTRAP_CLIENT_ID string = stagingDatabases.outputs.bootstrapIdentityClientId
output ADLC_STAGING_SQL_SERVER_NAME string = 'sql-adlc-${suffix}-staging'
output ADLC_STAGING_SQL_SERVER_IDENTITY_PRINCIPAL_ID string = stagingDatabases.outputs.sqlServerIdentityPrincipalId
output ADLC_REGISTRY_RESOURCE_ID string = shared.outputs.registryResourceId
output ADLC_REGISTRY_LOGIN_SERVER string = shared.outputs.registryLoginServer
output ADLC_WORKSPACE_RESOURCE_ID string = shared.outputs.workspaceResourceId
output ADLC_DEV_INSIGHTS_RESOURCE_ID string = shared.outputs.devInsightsResourceId
output ADLC_STAGING_INSIGHTS_RESOURCE_ID string = shared.outputs.stagingInsightsResourceId
output ADLC_DEV_STUDENTS_APP_ID string = devApis.outputs.studentsAppId
output ADLC_DEV_STUDENTS_HOST string = devApis.outputs.studentsHostName
output ADLC_DEV_STUDENTS_IDENTITY_NAME string = devApis.outputs.studentsIdentityName
output ADLC_DEV_STUDENTS_IDENTITY_PRINCIPAL_ID string = devApis.outputs.studentsIdentityPrincipalId
output ADLC_DEV_ACADEMICS_APP_ID string = devApis.outputs.academicsAppId
output ADLC_DEV_ACADEMICS_HOST string = devApis.outputs.academicsHostName
output ADLC_DEV_ACADEMICS_IDENTITY_NAME string = devApis.outputs.academicsIdentityName
output ADLC_DEV_ACADEMICS_IDENTITY_PRINCIPAL_ID string = devApis.outputs.academicsIdentityPrincipalId
output ADLC_STAGING_STUDENTS_APP_ID string = stagingApis.outputs.studentsAppId
output ADLC_STAGING_STUDENTS_HOST string = stagingApis.outputs.studentsHostName
output ADLC_STAGING_STUDENTS_IDENTITY_NAME string = stagingApis.outputs.studentsIdentityName
output ADLC_STAGING_STUDENTS_IDENTITY_PRINCIPAL_ID string = stagingApis.outputs.studentsIdentityPrincipalId
output ADLC_STAGING_ACADEMICS_APP_ID string = stagingApis.outputs.academicsAppId
output ADLC_STAGING_ACADEMICS_HOST string = stagingApis.outputs.academicsHostName
output ADLC_STAGING_ACADEMICS_IDENTITY_NAME string = stagingApis.outputs.academicsIdentityName
output ADLC_STAGING_ACADEMICS_IDENTITY_PRINCIPAL_ID string = stagingApis.outputs.academicsIdentityPrincipalId
