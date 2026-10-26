# Guides you through creating the read-only fine-grained GitHub PAT the github-mcp server needs.
# GitHub has no API to mint PATs, so this opens the creation page pre-filled (name, owner, expiry, permissions),
# then validates the token you paste against the watched repo and optionally stores it in the azd environment.
#
#   ./scripts/create-github-pat.ps1 -Owner nampacx -Repo my-repo [-ExpiresInDays 90] [-Store]
#
# -Store saves it with `azd env set GITHUB_PAT` (.azure/<env>/.env, git-ignored).
param(
  [Parameter(Mandatory)] [string] $Owner,
  [Parameter(Mandatory)] [string] $Repo,
  [ValidateRange(1, 366)] [int] $ExpiresInDays = 90,
  [switch] $Store
)
$ErrorActionPreference = 'Stop'

$qs = @{
  name          = "foundry-gh-triage-$Repo"
  description   = "Read-only access for the Foundry GH triage agent (GitHub MCP Function App)"
  target_name   = $Owner
  expires_in    = $ExpiresInDays
  contents      = 'read'
  issues        = 'read'
  metadata      = 'read'
}
$query = ($qs.GetEnumerator() | ForEach-Object { "$($_.Key)=$([uri]::EscapeDataString([string]$_.Value))" }) -join '&'
$url = "https://github.com/settings/personal-access-tokens/new?$query"

Write-Host "Opening GitHub's fine-grained token page (permissions pre-filled: Contents, Issues, Metadata = read)."
Write-Host "On the page: under 'Repository access' choose 'Only select repositories' -> $Owner/$Repo, then 'Generate token' and copy it."
Write-Host $url
Start-Process $url

$secure = Read-Host 'Paste the token (input hidden)' -AsSecureString
$pat = [System.Net.NetworkCredential]::new('', $secure).Password
if (-not $pat) { throw 'No token provided.' }

$headers = @{ Authorization = "Bearer $pat"; 'X-GitHub-Api-Version' = '2022-11-28'; 'User-Agent' = 'create-github-pat' }
try {
  $r = Invoke-RestMethod "https://api.github.com/repos/$Owner/$Repo" -Headers $headers
  Invoke-RestMethod "https://api.github.com/repos/$Owner/$Repo/issues?per_page=1" -Headers $headers | Out-Null
} catch {
  throw "Token check failed for $Owner/$Repo (wrong repo selected, or Contents/Issues read missing): $($_.Exception.Message)"
}
if ($r.permissions.push -or $r.permissions.admin) {
  Write-Warning 'This token can WRITE to the repo. The agent only needs read access; consider regenerating it with read-only permissions.'
}
Write-Host "Token works for $Owner/$Repo (read access confirmed)."

if ($Store) {
  azd env set GITHUB_PAT $pat
  if ($LASTEXITCODE -ne 0) { throw 'azd env set failed.' }
  Write-Host 'Stored as GITHUB_PAT in the azd environment. Apply it with: azd provision'
} else {
  Write-Host "Not stored. To use it: azd env set GITHUB_PAT <token>; azd provision   (or rerun with -Store)"
}
