// Single azd deployment: one resource group holding the Foundry account/project/model/ACR, the storage account
// (watchlist table + report container) and Application Insights. Outputs are written to the azd environment and
// consumed by azure.yaml and the scripts.
targetScope = 'subscription'

@minLength(1)
@maxLength(40)
param environmentName string
param location string

@description('Resource group to create and deploy everything into.')
@minLength(1)
@maxLength(90)
param resourceGroupName string

@description('Foundry project name. 3-32 alphanumeric/hyphen chars.')
@minLength(3)
@maxLength(32)
param foundryProjectName string

@description('Model deployments on the Foundry account.')
param deployments array = []

@description('Object id of the signed-in user/pipeline; granted Azure AI User and storage data rights.')
param principalId string = ''
param principalType string = 'User'

@description('Optional salt to vary resource names across re-provisions.')
param resourceTokenSalt string = ''

var tags = { 'azd-env-name': environmentName, workload: 'stock-watch' }

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceGroupName
  location: location
  tags: tags
}

module resources 'resources.bicep' = {
  name: 'resources'
  scope: rg
  params: {
    location: location
    tags: tags
    environmentName: environmentName
    resourceTokenSalt: resourceTokenSalt
    foundryProjectName: foundryProjectName
    deployments: deployments
    userPrincipalId: principalId
    userPrincipalType: principalType
  }
}

output AZURE_RESOURCE_GROUP string = rg.name
output AZURE_FOUNDRY_RESOURCE_GROUP string = rg.name
output AZURE_AI_PROJECT_ID string = resources.outputs.AZURE_AI_PROJECT_ID
output AZURE_AI_ACCOUNT_NAME string = resources.outputs.AZURE_AI_ACCOUNT_NAME
output AZURE_AI_PROJECT_NAME string = resources.outputs.AZURE_AI_PROJECT_NAME
output AZURE_OPENAI_ENDPOINT string = resources.outputs.AZURE_OPENAI_ENDPOINT
output FOUNDRY_PROJECT_ENDPOINT string = resources.outputs.FOUNDRY_PROJECT_ENDPOINT
output AZURE_CONTAINER_REGISTRY_ENDPOINT string = resources.outputs.AZURE_CONTAINER_REGISTRY_ENDPOINT
output AZURE_CONTAINER_REGISTRY_RESOURCE_ID string = resources.outputs.AZURE_CONTAINER_REGISTRY_RESOURCE_ID
output AZURE_AI_PROJECT_ACR_CONNECTION_NAME string = resources.outputs.AZURE_AI_PROJECT_ACR_CONNECTION_NAME
output STORAGE_ACCOUNT_NAME string = resources.outputs.STORAGE_ACCOUNT_NAME
output WATCHLIST_TABLE string = resources.outputs.WATCHLIST_TABLE
output REPORTS_CONTAINER string = resources.outputs.REPORTS_CONTAINER
