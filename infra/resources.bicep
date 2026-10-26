// Everything in one resource group: Foundry (account, project, model deployments, ACR), a Storage account
// (Table 'watchlist', Blob container 'stockwatch-reports' = consolidated reports) and Application Insights.
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
@description('Blob container receiving the consolidated reports.')
param reportsContainer string = 'stockwatch-reports'

// Same formula the former Foundry layer used, so existing Foundry resource names are kept.
var foundryToken = empty(resourceTokenSalt)
  ? uniqueString(subscription().id, resourceGroup().id, location)
  : uniqueString(subscription().id, resourceGroup().id, location, resourceTokenSalt)
var foundryAccountName = 'aif-stockwatch-${foundryToken}'
var acrName = 'crstockwatch${foundryToken}'

var resourceToken = toLower(uniqueString(subscription().id, environmentName, location))
var storageName = 'ststockwatch${take(resourceToken, 10)}'
var monitorName = 'stockwatch-${take(resourceToken, 8)}'

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

// --- Storage: watchlist table + report container ---
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
  resource blob 'blobServices' = {
    name: 'default'
    resource reports 'containers' = {
      name: reportsContainer
    }
  }
  resource table 'tableServices' = {
    name: 'default'
    resource watchlist 'tables' = {
      name: watchlistTable
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
  storageBlobReader: '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1'
  storageTableContributor: '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3'
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

// The user maintains the watchlist (seed script) and reviews the reports.
resource userEditsWatchlist 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(userPrincipalId)) {
  scope: storage
  name: guid(storage.id, userPrincipalId, roles.storageTableContributor)
  properties: {
    principalId: userPrincipalId
    principalType: userPrincipalType
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.storageTableContributor)
  }
}

resource userReadsReports 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(userPrincipalId)) {
  scope: storage
  name: guid(storage.id, userPrincipalId, roles.storageBlobReader)
  properties: {
    principalId: userPrincipalId
    principalType: userPrincipalType
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.storageBlobReader)
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

output STORAGE_ACCOUNT_NAME string = storage.name
output WATCHLIST_TABLE string = watchlistTable
output REPORTS_CONTAINER string = reportsContainer

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
