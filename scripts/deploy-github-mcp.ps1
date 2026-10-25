# PowerShell twin of deploy-github-mcp.sh. See that file for the description.
$ErrorActionPreference = 'Stop'
Set-Location (Join-Path $PSScriptRoot '..')

if (-not $env:AZURE_RESOURCE_GROUP) { throw 'AZURE_RESOURCE_GROUP is not set (run via azd, or set it yourself).' }
$location = if ($env:AZURE_LOCATION) { $env:AZURE_LOCATION } else { 'swedencentral' }
$connection = 'github-rest-mcp'

$pat = $env:GITHUB_PAT
if (-not $pat) {
  $secure = Read-Host 'GitHub PAT (read-only)' -AsSecureString
  $pat = [System.Net.NetworkCredential]::new('', $secure).Password
}
if (-not $pat) { throw 'No PAT provided.' }

$me = (az ad signed-in-user show --query id -o tsv 2>$null)

Write-Host 'Deploying Function App + Key Vault...'
az deployment group create -g $env:AZURE_RESOURCE_GROUP -f infra/github-mcp.bicep -n github-mcp `
  -p location=$location secretsOfficerPrincipalId=$me -o none
if ($LASTEXITCODE) { throw 'Deployment failed.' }
function Get-Output($name) { az deployment group show -g $env:AZURE_RESOURCE_GROUP -n github-mcp --query "properties.outputs.$name.value" -o tsv }
$func = Get-Output functionAppName
$vault = Get-Output keyVaultName
$endpoint = Get-Output mcpEndpoint

Write-Host "Storing PAT in Key Vault '$vault' (secret 'github-pat')..."
$stored = $false
for ($i = 0; $i -lt 12 -and -not $stored; $i++) {
  az keyvault secret set --vault-name $vault --name github-pat --value $pat -o none 2>$null
  if ($LASTEXITCODE -eq 0) { $stored = $true } else { Write-Host '  waiting for role assignment to propagate...'; Start-Sleep 10 }
}
if (-not $stored) { throw 'Could not write the secret (RBAC still propagating or no permission).' }
$pat = $null

Write-Host 'Building and publishing the function...'
$work = Join-Path ([IO.Path]::GetTempPath()) ([IO.Path]::GetRandomFileName())
try {
  dotnet publish src/github-mcp -c Release -o "$work/publish" --nologo -v q
  if ($LASTEXITCODE) { throw 'dotnet publish failed.' }
  Compress-Archive -Path "$work/publish/*" -DestinationPath "$work/app.zip"
  az functionapp deployment source config-zip -g $env:AZURE_RESOURCE_GROUP -n $func --src "$work/app.zip" -o none
  if ($LASTEXITCODE) { throw 'Zip deploy failed.' }
} finally { Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue }

Write-Host 'Reading the MCP system key...'
$key = $null
for ($i = 0; $i -lt 12 -and -not $key; $i++) {
  $key = az functionapp keys list -g $env:AZURE_RESOURCE_GROUP -n $func --query systemKeys.mcp_extension -o tsv 2>$null
  if (-not $key) { Start-Sleep 10 }
}
if (-not $key) { throw 'mcp_extension key not available yet; wait a minute and re-run.' }

Write-Host "Creating Foundry connection '$connection' -> $endpoint"
azd ai connection create $connection --kind remote-tool --target $endpoint --auth-type custom-keys --custom-key "x-functions-key=$key" --force
if ($LASTEXITCODE) { throw 'Connection creation failed.' }
