# Grants the hosted agent's own identity access to the storage account (watchlist table + report container)
# and the Foundry account. The identity only exists once the agent is deployed, so this runs as the
# postdeploy hook of the stockwatch-agent service (and can be re-run by hand). Needs Owner or
# User Access Administrator on the resource group.
$ErrorActionPreference = 'Stop'

$vals = @{}
azd env get-values | ForEach-Object { if ($_ -match '^([^=]+)="?(.*?)"?$') { $vals[$Matches[1]] = $Matches[2] } }
$sub = $vals['AZURE_SUBSCRIPTION_ID']; $rg = $vals['AZURE_RESOURCE_GROUP']
$storage = $vals['STORAGE_ACCOUNT_NAME']; $account = $vals['AZURE_AI_ACCOUNT_NAME']

$agent = azd ai agent show --output json | ConvertFrom-Json
$principal = $agent.instance_identity.principal_id
if (-not $principal) { throw 'Agent instance identity not found. Is the agent deployed?' }

$base = "/subscriptions/$sub/resourceGroups/$rg/providers"
$grants = @(
    @{ Role = '76199698-9eea-4c19-bc75-cec21354c6b6'; Scope = "$base/Microsoft.Storage/storageAccounts/$storage" }        # Storage Table Data Reader
    @{ Role = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'; Scope = "$base/Microsoft.Storage/storageAccounts/$storage" }        # Storage Blob Data Contributor
    @{ Role = '53ca6127-db72-4b80-b1b0-d745d6d5456d'; Scope = "$base/Microsoft.CognitiveServices/accounts/$account" }      # Azure AI User
)
foreach ($g in $grants) {
    az role assignment create --subscription $sub --assignee-object-id $principal --assignee-principal-type ServicePrincipal `
        --role $g.Role --scope $g.Scope -o none
    Write-Host "Granted $($g.Role) to agent identity $principal on $($g.Scope.Split('/')[-1])"
}
