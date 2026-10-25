# azd postprovision hook: creates the two GitHub connections and the toolbox.
#   github-conn : GitHub connector the routine's github_issue trigger uses (OAuth2)
#   github-mcp  : Foundry-managed GitHub MCP server (OAuth2) the agent reads code with
# Both need a one-time interactive GitHub consent, so this hook is interactive.
# The routine itself is created later by `azd deploy` (service "on-issue-opened").
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot

function Invoke-Azd {
    & azd @args
    if ($LASTEXITCODE -ne 0) { throw "azd $($args -join ' ') failed (exit $LASTEXITCODE)" }
}

function Wait-ConnectionConsent([string]$Name) {
    for ($i = 0; $i -lt 60; $i++) {
        $json = (& azd ai connection show $Name -o json 2>$null) -join "`n"
        if ($json -match '"overallStatus"\s*:\s*"Connected"') { Write-Host "Connection '$Name' is Connected."; return }
        if ($i -eq 0) {
            Write-Host ""
            Write-Host "== Authorize GitHub for connection '$Name' ==" -ForegroundColor Yellow
            Write-Host "Open the consent URL below in a browser, sign in to GitHub and approve."
            Write-Host "(The account needs admin rights on the watched repo to register the issue webhook.)"
            & azd ai connection show $Name
        }
        Start-Sleep -Seconds 5
    }
    throw "Timed out waiting for consent on connection '$Name'. Re-run: azd hooks run postprovision"
}

Push-Location $repoRoot
try {
    foreach ($c in @(@{ Name = 'github-conn'; Connector = 'github' }, @{ Name = 'github-mcp'; Connector = 'foundrygithubmcp' })) {
        Write-Host "Creating connection '$($c.Name)' (connector '$($c.Connector)')..."
        Invoke-Azd ai connection create $c.Name --connector-name $c.Connector --force
        Wait-ConnectionConsent $c.Name
    }

    & azd ai toolbox show gh-triage-tools *> $null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Toolbox 'gh-triage-tools' already exists, skipping."
    } else {
        Write-Host "Creating toolbox 'gh-triage-tools'..."
        Invoke-Azd ai toolbox create gh-triage-tools --from-file ./routines/toolbox.yaml
    }
}
finally {
    Pop-Location
}
