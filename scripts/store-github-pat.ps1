# PowerShell twin of store-github-pat.sh (see there for the description).
$ErrorActionPreference = 'Stop'
if (-not $env:GITHUB_MCP_KEY_VAULT_NAME) { throw 'GITHUB_MCP_KEY_VAULT_NAME is not set (provision the github-mcp layer first).' }
$vault = $env:GITHUB_MCP_KEY_VAULT_NAME

$pat = $env:GITHUB_PAT
if (-not $pat) {
  az keyvault secret show --vault-name $vault --name github-pat --query id -o tsv *> $null
  if ($LASTEXITCODE -eq 0) { Write-Host "Secret 'github-pat' already in Key Vault '$vault'; keeping it (set GITHUB_PAT to replace)."; return }
  $secure = Read-Host 'GitHub PAT (read-only)' -AsSecureString
  $pat = [System.Net.NetworkCredential]::new('', $secure).Password
}
if (-not $pat) { throw 'No PAT provided.' }

Write-Host "Storing PAT in Key Vault '$vault' (secret 'github-pat')..."
$stored = $false
for ($i = 0; $i -lt 12 -and -not $stored; $i++) {
  az keyvault secret set --vault-name $vault --name github-pat --value $pat -o none 2>$null
  if ($LASTEXITCODE -eq 0) { $stored = $true } else { Write-Host '  waiting for role assignment to propagate...'; Start-Sleep 10 }
}
if (-not $stored) { throw 'Could not write the secret (RBAC still propagating, or you lack Key Vault Secrets Officer).' }
Write-Host 'Done.'
