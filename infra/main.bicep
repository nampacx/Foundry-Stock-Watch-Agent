// Single azd deployment: one resource group holding the Foundry account/project/model/ACR and the
// GitHub REST -> MCP Function App. Outputs are written to the azd environment and
// consumed by azure.yaml (services, github-mcp service lookup) and the hook scripts.
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

@description('Object id of the signed-in user/pipeline; granted Azure AI User on the Foundry account.')
param principalId string = ''
param principalType string = 'User'

@secure()
@minLength(1)
@description('Read-only fine-grained GitHub PAT; stored as an app setting of the Function App.')
param githubPat string

@description('Optional "owner/repo" the GitHub MCP server is restricted to.')
param allowedRepo string = ''

@description('Optional salt to vary resource names across re-provisions.')
param resourceTokenSalt string = ''

var tags = { 'azd-env-name': environmentName }

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
    allowedRepo: allowedRepo
    githubPat: githubPat
    principalId: principalId
    principalType: principalType
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
output GITHUB_MCP_RESOURCE_GROUP string = rg.name
output GITHUB_MCP_FUNCTION_NAME string = resources.outputs.functionAppName
output GITHUB_MCP_ENDPOINT string = resources.outputs.mcpEndpoint
