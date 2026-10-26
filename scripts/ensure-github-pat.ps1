# azd preprovision hook: makes sure GITHUB_PAT is set in the azd environment so Bicep can put it into the
# Function App's settings (infra/main.parameters.json -> githubPat). It is stored in .azure/<env>/.env
# (git-ignored, plain text); to rotate: `azd env set GITHUB_PAT <new>` then `azd provision`.
$ErrorActionPreference = 'Stop'
if ($env:GITHUB_PAT) { Write-Host 'GITHUB_PAT is set.'; return }
$secure = Read-Host 'GitHub PAT (fine-grained, read-only Contents/Issues/Metadata)' -AsSecureString
$pat = [System.Net.NetworkCredential]::new('', $secure).Password
if (-not $pat) { throw 'No PAT provided.' }
azd env set GITHUB_PAT $pat
if ($LASTEXITCODE -ne 0) { throw 'Could not store GITHUB_PAT in the azd environment.' }
$env:GITHUB_PAT = $pat
