// azd layer "github-mcp": resource group + Function App (GitHub REST -> MCP) + Key Vault for the PAT.
// Outputs are written to the azd environment and consumed by azure.yaml (service github-mcp) and the hook scripts.
targetScope = 'subscription'

@minLength(1)
@maxLength(40)
param environmentName string
param location string
@description('Object id of the signed-in user/pipeline; granted Key Vault Secrets Officer to store the PAT.')
param principalId string = ''
param principalType string = 'User'

var tags = { 'azd-env-name': environmentName }
var resourceToken = toLower(uniqueString(subscription().id, environmentName, location))

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: 'rg-${environmentName}-github-mcp'
  location: location
  tags: tags
}

module app 'resources.bicep' = {
  name: 'github-mcp-resources'
  scope: rg
  params: {
    location: location
    resourceToken: resourceToken
    tags: tags
    secretsOfficerPrincipalId: principalId
    secretsOfficerPrincipalType: principalType
  }
}

// Distinct names so they do not collide with the Foundry layer's AZURE_RESOURCE_GROUP.
output GITHUB_MCP_RESOURCE_GROUP string = rg.name
output GITHUB_MCP_FUNCTION_NAME string = app.outputs.functionAppName
output GITHUB_MCP_KEY_VAULT_NAME string = app.outputs.keyVaultName
output GITHUB_MCP_ENDPOINT string = app.outputs.mcpEndpoint
