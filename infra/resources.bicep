// Everything in one resource group: Foundry (account, project, model deployments, ACR), a Storage account
// (Tables 'watchlist' and 'reports'), Application Insights and the report viewer (Static Web App + linked Function app API).
targetScope = 'resourceGroup'

param location string
param tags object = {}
param environmentName string
param resourceTokenSalt string = ''
param foundryProjectName string
param deployments array = []

@description('Object id of the signed-in user/pipeline; gets Azure AI User on the account and data rights on the storage account (seed the watchlist, read reports). Optional.')
param userPrincipalId string = ''
#disable-next-line secure-secrets-in-params // 'User' | 'ServicePrincipal', not a secret
param userPrincipalType string = 'User'

@description('Table holding the watchlist.')
param watchlistTable string = 'watchlist'
@description('Table receiving the reports: PartitionKey = ticker, RowKey = inverted run time.')
param reportsTable string = 'reports'
@description('Region of the Static Web App (only a few regions offer it; the linked Function app stays in the main region).')
param staticWebAppLocation string = 'westeurope'

// Same formula the former Foundry layer used, so existing Foundry resource names are kept.
var foundryToken = empty(resourceTokenSalt)
  ? uniqueString(subscription().id, resourceGroup().id, location)
  : uniqueString(subscription().id, resourceGroup().id, location, resourceTokenSalt)
var foundryAccountName = 'aif-stockwatch-${foundryToken}'
var acrName = 'crstockwatch${foundryToken}'

var resourceToken = toLower(uniqueString(subscription().id, environmentName, location))
var storageName = 'ststockwatch${take(resourceToken, 10)}'
var monitorName = 'stockwatch-${take(resourceToken, 8)}'
var funcStorageName = 'stfunc${take(resourceToken, 12)}'
var deploymentContainer = 'app-package'

// --- Foundry ---
resource foundryAccount 'Microsoft.CognitiveServices/accounts@2025-06-01' = {
  name: foundryAccountName
  location: location
  tags: tags
  sku: { name: 'S0' }
  kind: 'AIServices'
  identity: { type: 'SystemAssigned' }
  properties: {
    allowProjectManagement: true
    customSubDomainName: foundryAccountName
    publicNetworkAccess: 'Enabled'
    disableLocalAuth: true
    networkAcls: { defaultAction: 'Allow', virtualNetworkRules: [], ipRules: [] }
  }

  // Sequential: ARM throttles concurrent deployments on the same account.
  @batchSize(1)
  resource modelDeployments 'deployments' = [
    for d in deployments: {
      name: d.name
      properties: { model: d.model }
      sku: d.sku
    }
  ]

  resource project 'projects' = {
    name: foundryProjectName
    location: location
    identity: { type: 'SystemAssigned' }
    properties: {
      description: '${foundryProjectName} Project'
      displayName: foundryProjectName
    }
    // The project does not reference the deployments, so Bicep cannot infer this ordering.
    dependsOn: [ modelDeployments ]

    resource acrConnection 'connections' = {
      name: '${acrName}-conn'
      properties: {
        category: 'ContainerRegistry'
        target: registry.properties.loginServer
        authType: 'ManagedIdentity'
        credentials: { clientId: project.identity.principalId, resourceId: registry.id }
        isSharedToAll: true
        metadata: { ResourceId: registry.id }
      }
      dependsOn: [ foundryAcrPull ]
    }

    // Lets the project's agents and routines send traces to Application Insights.
    resource appInsightsConnection 'connections' = {
      name: '${appi.name}-conn'
      properties: {
        category: 'AppInsights'
        target: appi.id
        authType: 'ApiKey' // the portal creates ProjectManagedIdentity, which the Bicep type definitions do not list yet
        credentials: { key: appi.properties.ConnectionString }
        isSharedToAll: false
        metadata: {
          ApiType: 'Azure'
          ResourceId: appi.id
          ApplicationInsightsConnectionString: appi.properties.ConnectionString
        }
      }
    }
  }
}

resource registry 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: acrName
  location: location
  tags: tags
  sku: { name: 'Basic' } // remote image builds (ACR Tasks) work on Basic
  identity: { type: 'SystemAssigned' }
  properties: { adminUserEnabled: false, publicNetworkAccess: 'Enabled', zoneRedundancy: 'Disabled' }
}

resource foundryAcrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: registry
  name: guid(registry.id, foundryAccount::project.id, roles.acrPull)
  properties: {
    principalId: foundryAccount::project.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.acrPull)
  }
}

// --- Storage: watchlist + reports tables ---
resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageName
  location: location
  tags: tags
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
  }
  resource table 'tableServices' = {
    name: 'default'
    resource watchlist 'tables' = {
      name: watchlistTable
    }
    resource reports 'tables' = {
      name: reportsTable
    }
  }
}

resource logs 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: 'log-${monitorName}'
  location: location
  tags: tags
  properties: { sku: { name: 'PerGB2018' }, retentionInDays: 30 }
}

resource appi 'Microsoft.Insights/components@2020-02-02' = {
  name: 'appi-${monitorName}'
  location: location
  tags: tags
  kind: 'web'
  properties: { Application_Type: 'web', WorkspaceResourceId: logs.id }
}

// --- RBAC ---
var roles = {
  acrPull: '7f951dda-4ed3-4680-a7ca-43fe172d538d'
  azureAiUser: '53ca6127-db72-4b80-b1b0-d745d6d5456d'
  monitoringReader: '43d0d8ad-25c7-4714-9337-8ba259a9fe05'
  storageTableReader: '76199698-9eea-4c19-bc75-cec21354c6b6'
  storageTableContributor: '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3'
  storageBlobOwner: 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
  storageQueueContributor: '974c5e8b-45b9-4653-ba55-5f855dd0fb88'
}

// The Insights tab in Foundry queries the connected Application Insights as the project's managed identity.
resource foundryReadsAppInsights 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: appi
  name: guid(appi.id, foundryAccount::project.id, roles.monitoringReader)
  properties: {
    principalId: foundryAccount::project.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.monitoringReader)
  }
}

// The hosted agent's own identity (created at deploy time) gets its storage roles from scripts/grant-agent-access.ps1.

// The user maintains the watchlist (seed script); Table Data Contributor also lets them read the reports table.
resource userEditsWatchlist 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(userPrincipalId)) {
  scope: storage
  name: guid(storage.id, userPrincipalId, roles.storageTableContributor)
  properties: {
    principalId: userPrincipalId
    principalType: userPrincipalType
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.storageTableContributor)
  }
}

// The deploying user creates agents and routines in the project (azd ai ...), which needs data-plane rights on the Foundry account.
resource userAzureAiUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(userPrincipalId)) {
  scope: foundryAccount
  name: guid(foundryAccount.id, userPrincipalId, roles.azureAiUser)
  properties: {
    principalId: userPrincipalId
    principalType: userPrincipalType
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.azureAiUser)
  }
}

// --- Report viewer: Static Web App (React) -> /api -> Function app (C#) -> reports table ---
// A Static Web App cannot use a managed identity to call storage, and managed functions have no identity either, so
// the API is a separate Function app (Flex Consumption) linked as the SWA backend. It reads the tables with its own
// user-assigned identity; no keys or connection strings anywhere.
resource apiIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-api-${monitorName}'
  location: location
  tags: tags
}

// Runtime storage of the function app (deployment package, host state), separate from the data account.
resource funcStorage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: funcStorageName
  location: location
  tags: tags
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
  }
  resource blob 'blobServices' = {
    name: 'default'
    resource deployment 'containers' = {
      name: deploymentContainer
    }
  }
}

resource apiPlan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: 'plan-api-${monitorName}'
  location: location
  tags: tags
  kind: 'functionapp'
  sku: { name: 'FC1', tier: 'FlexConsumption' }
  properties: { reserved: true }
}

resource api 'Microsoft.Web/sites@2024-04-01' = {
  name: 'func-api-${monitorName}'
  location: location
  tags: union(tags, { 'azd-service-name': 'api' })
  kind: 'functionapp,linux'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${apiIdentity.id}': {} }
  }
  properties: {
    serverFarmId: apiPlan.id
    httpsOnly: true
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: '${funcStorage.properties.primaryEndpoints.blob}${deploymentContainer}'
          authentication: { type: 'UserAssignedIdentity', userAssignedIdentityResourceId: apiIdentity.id }
        }
      }
      scaleAndConcurrency: { maximumInstanceCount: 40, instanceMemoryMB: 2048 }
      runtime: { name: 'dotnet-isolated', version: '10.0' }
    }
    siteConfig: {
      minTlsVersion: '1.2'
      ftpsState: 'Disabled'
      appSettings: [
        { name: 'AzureWebJobsStorage__accountName', value: funcStorage.name }
        { name: 'AzureWebJobsStorage__credential', value: 'managedidentity' }
        { name: 'AzureWebJobsStorage__clientId', value: apiIdentity.properties.clientId }
        { name: 'AZURE_CLIENT_ID', value: apiIdentity.properties.clientId }
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: appi.properties.ConnectionString }
        { name: 'STORAGE_ACCOUNT_NAME', value: storage.name }
        { name: 'WATCHLIST_TABLE', value: watchlistTable }
        { name: 'REPORTS_TABLE', value: reportsTable }
      ]
    }
  }
}

var apiRuntimeRoles = [
  roles.storageBlobOwner
  roles.storageQueueContributor
  roles.storageTableContributor
]

resource apiRuntimeStorageAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for role in apiRuntimeRoles: {
    scope: funcStorage
    name: guid(funcStorage.id, apiIdentity.id, role)
    properties: {
      principalId: apiIdentity.properties.principalId
      principalType: 'ServicePrincipal'
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', role)
    }
  }
]

// Read-only on the data account: the API can read the watchlist and reports tables, nothing else.
resource apiReadsTables 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: storage
  name: guid(storage.id, apiIdentity.id, roles.storageTableReader)
  properties: {
    principalId: apiIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.storageTableReader)
  }
}

// Linking a backend requires the Standard plan.
resource web 'Microsoft.Web/staticSites@2024-04-01' = {
  name: 'swa-${monitorName}'
  location: staticWebAppLocation
  tags: union(tags, { 'azd-service-name': 'web' })
  sku: { name: 'Standard', tier: 'Standard' }
  properties: {}

  // Puts the SWA in front of the function app: /api is proxied to it and App Service authentication on the function app
  // only accepts calls that come through the SWA.
  resource backend 'linkedBackends' = {
    name: 'api'
    properties: {
      backendResourceId: api.id
      region: location
    }
    dependsOn: [ apiRuntimeStorageAccess, apiReadsTables ]
  }
}

output STORAGE_ACCOUNT_NAME string = storage.name
output WATCHLIST_TABLE string = watchlistTable
output REPORTS_TABLE string = reportsTable
output API_FUNCTION_APP_NAME string = api.name
output STATIC_WEB_APP_NAME string = web.name
output STATIC_WEB_APP_URL string = 'https://${web.properties.defaultHostname}'

output AZURE_AI_PROJECT_ID string = foundryAccount::project.id
output AZURE_AI_ACCOUNT_NAME string = foundryAccount.name
output AZURE_AI_PROJECT_NAME string = foundryAccount::project.name
output AZURE_OPENAI_ENDPOINT string = 'https://${foundryAccount.name}.openai.azure.com/'
output FOUNDRY_PROJECT_ENDPOINT string = 'https://${foundryAccount.name}.services.ai.azure.com/api/projects/${foundryAccount::project.name}'
output AZURE_CONTAINER_REGISTRY_ENDPOINT string = registry.properties.loginServer
output AZURE_CONTAINER_REGISTRY_RESOURCE_ID string = registry.id
output AZURE_AI_PROJECT_ACR_CONNECTION_NAME string = foundryAccount::project::acrConnection.name
output APPLICATIONINSIGHTS_NAME string = appi.name
// Ingestion settings, not a data-plane credential; the hosted agent needs it to export telemetry.
#disable-next-line outputs-should-not-contain-secrets
output APPLICATIONINSIGHTS_CONNECTION_STRING string = appi.properties.ConnectionString
output AZURE_AI_PROJECT_APPINSIGHTS_CONNECTION_NAME string = foundryAccount::project::appInsightsConnection.name
