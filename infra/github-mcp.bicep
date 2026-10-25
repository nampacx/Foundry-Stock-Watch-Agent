// GitHub REST -> MCP wrapper: Function App (Flex Consumption, .NET 10 isolated) + Key Vault holding the PAT.
// The app's system-assigned identity reads the secret through a Key Vault reference; no secret is in the template.
targetScope = 'resourceGroup'

@description('Base name; a unique suffix is appended.')
param baseName string = 'ghmcp'
param location string = resourceGroup().location

@description('Object id of the person/pipeline that stores the PAT (gets Key Vault Secrets Officer). Optional.')
param secretsOfficerPrincipalId string = ''

var suffix = take(uniqueString(resourceGroup().id, baseName), 6)
var funcName = '${baseName}-${suffix}'
var kvName = take('kv-${baseName}-${suffix}', 24)
var storageName = take('st${baseName}${suffix}', 24)
var deployContainer = 'app-package'
var patSecretName = 'github-pat'

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageName
  location: location
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
  properties: { sku: { name: 'PerGB2018' }, retentionInDays: 30 }
}

resource appi 'Microsoft.Insights/components@2020-02-02' = {
  name: 'appi-${funcName}'
  location: location
  kind: 'web'
  properties: { Application_Type: 'web', WorkspaceResourceId: logs.id }
}

resource plan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: 'plan-${funcName}'
  location: location
  kind: 'functionapp'
  sku: { name: 'FC1', tier: 'FlexConsumption' }
  properties: { reserved: true }
}

resource func 'Microsoft.Web/sites@2024-04-01' = {
  name: funcName
  location: location
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
      runtime: { name: 'dotnet-isolated', version: '10.0' }
    }
    siteConfig: {
      appSettings: [
        { name: 'AzureWebJobsStorage__accountName', value: storage.name }
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: appi.properties.ConnectionString }
        // Key Vault reference, unversioned so a rotated secret is picked up automatically (within ~24h, or on restart).
        { name: 'GITHUB_PAT', value: '@Microsoft.KeyVault(VaultName=${kv.name};SecretName=${patSecretName})' }
      ]
    }
  }
}

// --- RBAC ---
var roles = {
  kvSecretsUser: '4633458b-17de-408a-b874-0445c86b69e6'
  kvSecretsOfficer: 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7'
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
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.kvSecretsOfficer)
  }
}

output functionAppName string = func.name
output keyVaultName string = kv.name
output mcpEndpoint string = 'https://${func.properties.defaultHostName}/runtime/webhooks/mcp'
