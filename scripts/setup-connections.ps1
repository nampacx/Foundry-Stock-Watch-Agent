# azd postprovision hook: creates the GitHub connector the routine's
# github_issue trigger uses (OAuth2, one-time interactive consent; registering the issue webhook needs it).
# The agent's code access is NOT this connector: that is the github-rest-mcp connection, see
# scripts/register-github-mcp.ps1. The routine itself is created later by `azd deploy`.
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path -Parent $PSScriptRoot)

function Test-Connected([string]$Name) {
    $json = (& azd ai connection show $Name -o json 2>$null) -join "`n"
    return ($json -match '"overallStatus"\s*:\s*"Connected"')
}

$name = 'github-conn'
if (Test-Connected $name) { Write-Host "Connection '$name' is already Connected."; return }

Write-Host "Creating connection '$name' (connector 'github')..."
& azd ai connection create $name --auth-type oauth2 --connector-name github --force
if ($LASTEXITCODE -ne 0) { throw "azd ai connection create failed (exit $LASTEXITCODE)" }

for ($i = 0; $i -lt 60; $i++) {
    if (Test-Connected $name) { Write-Host "Connection '$name' is Connected."; return }
    if ($i -eq 0) {
        Write-Host ""
        Write-Host "== Authorize GitHub for connection '$name' ==" -ForegroundColor Yellow
        Write-Host "Open the consent URL below in a browser, sign in to GitHub and approve."
        Write-Host "(The account needs admin rights on the watched repo to register the issue webhook.)"
        & azd ai connection show $name
    }
    Start-Sleep -Seconds 5
}
throw "Timed out waiting for consent on connection '$name'. Re-run: azd hooks run postprovision"
