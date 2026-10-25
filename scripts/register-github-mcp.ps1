# PowerShell twin of register-github-mcp.sh (see there for the description).
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path -Parent $PSScriptRoot)
foreach ($v in 'GITHUB_MCP_FUNCTION_NAME', 'GITHUB_MCP_RESOURCE_GROUP', 'GITHUB_MCP_ENDPOINT') {
  if (-not (Get-Item "env:$v" -ErrorAction SilentlyContinue)) { throw "$v is not set." }
}

Write-Host "Reading the MCP system key of '$env:GITHUB_MCP_FUNCTION_NAME'..."
$key = $null
for ($i = 0; $i -lt 18 -and -not $key; $i++) {
  $key = az functionapp keys list -g $env:GITHUB_MCP_RESOURCE_GROUP -n $env:GITHUB_MCP_FUNCTION_NAME --query systemKeys.mcp_extension -o tsv 2>$null
  if (-not $key) { Start-Sleep 10 }
}
if (-not $key) { throw 'mcp_extension key not available (is the function code deployed and running?).' }

Write-Host "Creating Foundry connection 'github-rest-mcp' -> $env:GITHUB_MCP_ENDPOINT"
azd ai connection create github-rest-mcp --kind remote-tool --target $env:GITHUB_MCP_ENDPOINT --auth-type custom-keys --custom-key "x-functions-key=$key" --force
if ($LASTEXITCODE) { throw 'Connection creation failed.' }

& azd ai toolbox show gh-triage-tools *> $null
if ($LASTEXITCODE -eq 0) {
  Write-Host "Toolbox 'gh-triage-tools' already exists, skipping."
} else {
  Write-Host "Creating toolbox 'gh-triage-tools'..."
  azd ai toolbox create gh-triage-tools --from-file ./routines/toolbox.yaml
  if ($LASTEXITCODE) { throw 'Toolbox creation failed.' }
}
