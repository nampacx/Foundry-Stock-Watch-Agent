# azd postprovision hook: creates the GitHub connector connection the routine's github_issue trigger uses
# (OAuth2, one-time interactive consent; registering the issue webhook needs it).
# The agent's code access is NOT this connector: that is the github-rest-mcp connection, see
# scripts/register-github-mcp.ps1. The routine itself is created later by `azd deploy`.
#
# `azd ai connection create --connector-name github` (connections extension beta.11) does not attach the
# connector gateway metadata, so the connection can never be consented. This script therefore follows the
# documented REST flow: look the connector up in the Foundry Tools Catalog, PUT the connection with
# metadata.type=gateway_connector, register the GitHub issue operations (metadata.mcpserverConfigProperties),
# then mint the consent link. Without the registered operations the platform never provisions the connector
# gateway (target stays https://placeholder) and the github_issue trigger silently never fires.
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path -Parent $PSScriptRoot)

foreach ($v in 'AZURE_SUBSCRIPTION_ID', 'AZURE_RESOURCE_GROUP', 'AZURE_AI_ACCOUNT_NAME', 'AZURE_AI_PROJECT_NAME', 'AZURE_TENANT_ID') {
    if (-not (Get-Item "env:$v" -ErrorAction SilentlyContinue)) { throw "$v is not set (run azd provision first)." }
}

$name = 'github-conn'
$connector = 'github'
$apiVersion = '2025-04-01-preview'
$base = "https://management.azure.com/subscriptions/$env:AZURE_SUBSCRIPTION_ID/resourceGroups/$env:AZURE_RESOURCE_GROUP" +
    "/providers/Microsoft.CognitiveServices/accounts/$env:AZURE_AI_ACCOUNT_NAME/projects/$env:AZURE_AI_PROJECT_NAME" +
    "/connections/$name"
$url = "${base}?api-version=$apiVersion"
$tmp = Join-Path ([IO.Path]::GetTempPath()) "setup-connections-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null

function Get-Status {
    $s = az rest --method get --url $url --query properties.overallStatus -o tsv 2>$null
    return $(if ($LASTEXITCODE -eq 0) { $s } else { $null })
}

# Operations the github_issue trigger needs registered on the connection (names as the Foundry portal lists them).
function Get-McpConfig {
    $ops = foreach ($op in @(
            @{ name = 'IssueOpened'; displayName = 'When a new issue is opened and assigned to me' }
            @{ name = 'IssueClosed'; displayName = 'When an issue assigned to me is closed' })) {
        @{ name = $op.name; displayName = $op.displayName; description = ''; userParameters = @(); agentParameters = @() }
    }
    @{
        description = ''
        state       = 'Enabled'
        connectors  = @(@{ name = $connector; connectionName = $name; displayName = $connector; description = ''; operations = @($ops) })
    } | ConvertTo-Json -Depth 8 -Compress
}

# PUT the connection; -Register adds the operations. ConnectionProperties keeps what the platform already stored.
function Set-Connection([string]$EntityId, [string]$ConnectionProperties, [switch]$Register) {
    $metadata = [ordered]@{
        type                 = 'gateway_connector'
        toolEntityId         = $EntityId
        connectionproperties = $ConnectionProperties
    }
    if ($Register) { $metadata.mcpserverConfigProperties = Get-McpConfig }
    @{
        properties = @{
            authType      = 'OAuth2'
            category      = 'RemoteTool'
            connectorName = $connector
            target        = 'https://placeholder'
            credentials   = @{}
            peRequirement = 'NotRequired'
            metadata      = $metadata
        }
    } | ConvertTo-Json -Depth 8 | Set-Content "$tmp/conn.json" -Encoding utf8
    az rest --method put --url $url --headers 'Content-Type=application/json' --body "@$tmp/conn.json" -o none
    if ($LASTEXITCODE -ne 0) { throw 'Connection creation failed.' }
}

try {
    if ((Get-Status) -eq 'Connected') {
        # Repair a connection created before the operations were registered: it is Connected but has no gateway.
        $registered = az rest --method get --url $url --query properties.metadata.mcpserverConfigProperties -o tsv 2>$null
        if (-not $registered) {
            Write-Host "Connection '$name' is Connected but has no registered operations; registering them..."
            $entity = az rest --method get --url $url --query properties.metadata.toolEntityId -o tsv
            $props = az rest --method get --url $url --query properties.metadata.connectionproperties -o tsv
            Set-Connection $entity $props -Register
        }
        Write-Host "Connection '$name' is already Connected."; return
    }

    # 1. Catalog lookup (served from eastus regardless of the project region).
    Write-Host "Looking up connector '$connector' in the Foundry Tools Catalog..."
    @{
        freeTextSearch = '*'
        filters        = @(
            @{ field = 'entityContainerId'; operator = 'eq'; values = @('connectors-registry-prod-bl') }
            @{ field = 'type'; operator = 'eq'; values = @('tools') }
            @{ field = 'kind'; operator = 'eq'; values = @('Versioned') }
            @{ field = 'labels'; operator = 'eq'; values = @('latest') }
            @{ field = 'annotations/name'; operator = 'eq'; values = @($connector) }
        )
        includeTotalResultCount = $true
        pageSize               = 1
    } | ConvertTo-Json -Depth 6 | Set-Content "$tmp/catalog.json" -Encoding utf8
    $entityId = az rest --method post --resource https://ai.azure.com `
        --url 'https://eastus.api.azureml.ms/asset-gallery/v1.0/tools' `
        --headers 'Content-Type=application/json' 'x-ms-user-agent=AzureMachineLearningWorkspacePortal/12.0' `
        --body "@$tmp/catalog.json" --query 'value[0].entityId' -o tsv
    if ($LASTEXITCODE -ne 0 -or -not $entityId) { throw "Connector '$connector' not found in the Foundry Tools Catalog." }

    # 2. Create the connection (target is a placeholder the platform rewrites once actions are registered).
    Write-Host "Creating connection '$name'..."
    $connProps = (@{ connectorName = $connector } | ConvertTo-Json -Compress)
    Set-Connection $entityId $connProps

    # Register the issue operations. This is what makes the platform provision the connector gateway and rewrite
    # the placeholder target; consent can happen before or after it.
    Write-Host "Registering GitHub issue operations on '$name'..."
    Set-Connection $entityId $connProps -Register

    # 3. Consent link for the signed-in user.
    $oid = az ad signed-in-user show --query id -o tsv
    @{ parameters = @(@{ objectId = $oid; parameterName = 'token'; redirectUrl = 'https://ai.azure.com/nextgen/authConsentPopup'; tenantId = $env:AZURE_TENANT_ID }) } |
        ConvertTo-Json -Depth 6 | Set-Content "$tmp/consent.json" -Encoding utf8
    # POST .../connections/<name>/listConsentLinks (api-version via --url-parameters: az is a .cmd shim and
    # cmd.exe would split a literal "&" in the URL).
    $link = az rest --method post --url "$base/listConsentLinks" --url-parameters "api-version=$apiVersion" --headers 'Content-Type=application/json' `
        --body "@$tmp/consent.json" --query 'value[0].link' -o tsv
    if ($LASTEXITCODE -ne 0 -or -not $link) { throw 'Could not get the GitHub consent link.' }

    Write-Host ""
    Write-Host "== Authorize GitHub for connection '$name' ==" -ForegroundColor Yellow
    Write-Host "Open this URL in a browser, sign in to GitHub and approve (the page ends blank when it worked)."
    Write-Host "The account needs admin rights on the watched repo to register the issue webhook."
    Write-Host $link

    for ($i = 0; $i -lt 60; $i++) {
        if ((Get-Status) -eq 'Connected') { Write-Host "Connection '$name' is Connected."; return }
        Start-Sleep -Seconds 5
    }
    # The status only flips to Connected once consent AND the registered operations are both in place. Do not fail
    # the deployment here; a routine on an unconsented connection is created but its trigger never fires.
    Write-Warning "Connection '$name' still reports '$(Get-Status)' after 5 minutes. Continuing; if routine creation fails, re-run: azd hooks run postprovision"
}
finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
