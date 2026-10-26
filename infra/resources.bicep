// Everything in one resource group: Foundry (account, project, model deployments, ACR) and the
// GitHub REST -> MCP wrapper (Function App on Flex Consumption + Key Vault holding the PAT).
// The app's system-assigned identity reads the secret through a Key Vault reference; no secret is in the template.
// The secret itself (github-pat) is written by the postprovision hook, never via template parameters.
targetScope = 'resourceGroup'

param location string
param tags object = {}
param environmentName string
param resourceTokenSalt string = ''
param foundryProjectName string
param deployments array = []

@description('Object id of the person/pipeline that stores the PAT (gets Key Vault Secrets Officer). Optional.')
#disable-next-line secure-secrets-in-params // an object id, not a secret
param secretsOfficerPrincipalId string = ''
#disable-next-line secure-secrets-in-params // 'User' | 'ServicePrincipal', not a secret
param secretsOfficerPrincipalType string = 'User'

@description('Optional "owner/repo" the MCP server is restricted to (ALLOWED_REPO). Empty = any repository the PAT can read.')
param allowedRepo string = ''

// Same formula the former Foundry layer used, so existing Foundry resource names are kept.
var foundryToken = empty(resourceTokenSalt)
  ? uniqueString(subscription().id, resourceGroup().id, location)
  : uniqueString(subscription().id, resourceGroup().id, location, resourceTokenSalt)
var foundryAccountName = 'cog-${foundryToken}'
var acrName = 'cr${foundryToken}'

var resourceToken = toLower(uniqueString(subscription().id, environmentName, location))
var funcName = 'func-ghmcp-${resourceToken}'
var kvName = 'kv-ghmcp-${take(resourceToken, 8)}'
var storageName = 'stghmcp${take(resourceToken, 10)}'
var deployContainer = 'app-package'
var patSecretName = 'github-pat' // written by scripts/store-github-pat.*

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
  }
}

resource registry 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: acrName
  location: location
  tags: tags
  sku: { name: 'Basic' } // remote image builds (ACR Tasks) work on Basic; Premium is not needed for a demo
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

// --- GitHub MCP ---
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
    resource pkg 'containers' = {
      name: deployContainer
    }
  }
}

resource kv 'Microsoft.KeyVault/vaults@2024-11-01' = {
  name: kvName
  location: location
  tags: tags
  properties: {
    sku: { family: 'A', name: 'standard' }
    tenantId: subscription().tenantId
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
  }
}

resource logs 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: 'log-${funcName}'
  location: location
  tags: tags
  properties: { sku: { name: 'PerGB2018' }, retentionInDays: 30 }
}

resource appi 'Microsoft.Insights/components@2020-02-02' = {
  name: 'appi-${funcName}'
  location: location
  tags: tags
  kind: 'web'
  properties: { Application_Type: 'web', WorkspaceResourceId: logs.id }
}

resource plan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: 'plan-${funcName}'
  location: location
  tags: tags
  kind: 'functionapp'
  sku: { name: 'FC1', tier: 'FlexConsumption' }
  properties: { reserved: true }
}

resource func 'Microsoft.Web/sites@2024-04-01' = {
  name: funcName
  location: location
  // azd matches the azure.yaml service 'github-mcp' to this resource by this tag.
  tags: union(tags, { 'azd-service-name': 'github-mcp' })
  kind: 'functionapp,linux'
  identity: { type: 'SystemAssigned' }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    keyVaultReferenceIdentity: 'SystemAssigned'
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: '${storage.properties.primaryEndpoints.blob}${deployContainer}'
          authentication: { type: 'SystemAssignedIdentity' }
        }
      }
      scaleAndConcurrency: { maximumInstanceCount: 40, instanceMemoryMB: 2048 }
      runtime: { name: 'dotnet-isolated', version: '10' }
    }
    siteConfig: {
      appSettings: [
        { name: 'AzureWebJobsStorage__accountName', value: storage.name }
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: appi.properties.ConnectionString }
        // Key Vault reference, unversioned so a rotated secret is picked up automatically (within ~24h, or on restart).
        { name: 'ALLOWED_REPO', value: allowedRepo }
        { name: 'GITHUB_PAT', value: '@Microsoft.KeyVault(VaultName=${kv.name};SecretName=${patSecretName})' }
      ]
    }
  }
}

// --- RBAC ---
var roles = {
  acrPull: '7f951dda-4ed3-4680-a7ca-43fe172d538d'
  kvSecretsUser: '4633458b-17de-408a-b874-0445c86b69e6'
  kvSecretsOfficer: 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7'
  azureAiUser: '53ca6127-db72-4b80-b1b0-d745d6d5456d'
  storageBlobOwner: 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
}

resource funcReadsSecret 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: kv
  name: guid(kv.id, func.id, roles.kvSecretsUser)
  properties: {
    principalId: func.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.kvSecretsUser)
  }
}

resource funcUsesStorage 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: storage
  name: guid(storage.id, func.id, roles.storageBlobOwner)
  properties: {
    principalId: func.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.storageBlobOwner)
  }
}

resource officer 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(secretsOfficerPrincipalId)) {
  scope: kv
  name: guid(kv.id, secretsOfficerPrincipalId, roles.kvSecretsOfficer)
  properties: {
    principalId: secretsOfficerPrincipalId
    principalType: secretsOfficerPrincipalType
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.kvSecretsOfficer)
  }
}

// The deploying user creates agents, connections, toolboxes and routines in the project (azd ai ...), which
// needs data-plane rights on the Foundry account.
resource userAzureAiUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(secretsOfficerPrincipalId)) {
  scope: foundryAccount
  name: guid(foundryAccount.id, secretsOfficerPrincipalId, roles.azureAiUser)
  properties: {
    principalId: secretsOfficerPrincipalId
    principalType: secretsOfficerPrincipalType
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.azureAiUser)
  }
}

output functionAppName string = func.name
output keyVaultName string = kv.name
output mcpEndpoint string = 'https://${func.properties.defaultHostName}/runtime/webhooks/mcp'

output AZURE_AI_PROJECT_ID string = foundryAccount::project.id
output AZURE_AI_ACCOUNT_NAME string = foundryAccount.name
output AZURE_AI_PROJECT_NAME string = foundryAccount::project.name
output AZURE_OPENAI_ENDPOINT string = 'https://${foundryAccount.name}.openai.azure.com/'
output FOUNDRY_PROJECT_ENDPOINT string = 'https://${foundryAccount.name}.services.ai.azure.com/api/projects/${foundryAccount::project.name}'
output AZURE_CONTAINER_REGISTRY_ENDPOINT string = registry.properties.loginServer
output AZURE_CONTAINER_REGISTRY_RESOURCE_ID string = registry.id
output AZURE_AI_PROJECT_ACR_CONNECTION_NAME string = foundryAccount::project::acrConnection.name
