#!/bin/sh
# azd postprovision hook: creates the GitHub connector connection the routine's github_issue trigger uses
# (OAuth2, one-time interactive consent; registering the issue webhook needs it).
# The agent's code access is NOT this connector: that is the github-rest-mcp connection, see
# scripts/register-github-mcp.sh. The routine itself is created later by `azd deploy`.
#
# `azd ai connection create --connector-name github` (connections extension beta.11) does not attach the
# connector gateway metadata, so the connection can never be consented. This script therefore follows the
# documented REST flow: look the connector up in the Foundry Tools Catalog, PUT the connection with
# metadata.type=gateway_connector, then mint the consent link.
set -eu
cd "$(dirname "$0")/.."

: "${AZURE_SUBSCRIPTION_ID:?not set}" "${AZURE_RESOURCE_GROUP:?not set}" "${AZURE_AI_ACCOUNT_NAME:?not set}" \
  "${AZURE_AI_PROJECT_NAME:?not set}" "${AZURE_TENANT_ID:?not set}"

name="github-conn"
connector="github"
api="2025-04-01-preview"
base="https://management.azure.com/subscriptions/$AZURE_SUBSCRIPTION_ID/resourceGroups/$AZURE_RESOURCE_GROUP/providers/Microsoft.CognitiveServices/accounts/$AZURE_AI_ACCOUNT_NAME/projects/$AZURE_AI_PROJECT_NAME/connections/$name"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

status() { az rest --method get --url "$base?api-version=$api" --query properties.overallStatus -o tsv 2>/dev/null || true; }

if [ "$(status)" = "Connected" ]; then echo "Connection '$name' is already Connected."; exit 0; fi

echo "Looking up connector '$connector' in the Foundry Tools Catalog..."
cat > "$tmp/catalog.json" <<JSON
{"freeTextSearch":"*","filters":[
 {"field":"entityContainerId","operator":"eq","values":["connectors-registry-prod-bl"]},
 {"field":"type","operator":"eq","values":["tools"]},
 {"field":"kind","operator":"eq","values":["Versioned"]},
 {"field":"labels","operator":"eq","values":["latest"]},
 {"field":"annotations/name","operator":"eq","values":["$connector"]}],
 "includeTotalResultCount":true,"pageSize":1}
JSON
entity="$(az rest --method post --resource https://ai.azure.com --url https://eastus.api.azureml.ms/asset-gallery/v1.0/tools \
  --headers 'Content-Type=application/json' 'x-ms-user-agent=AzureMachineLearningWorkspacePortal/12.0' \
  --body "@$tmp/catalog.json" --query 'value[0].entityId' -o tsv)"
[ -n "$entity" ] || { echo "Connector '$connector' not found in the Foundry Tools Catalog." >&2; exit 1; }

echo "Creating connection '$name'..."
cat > "$tmp/conn.json" <<JSON
{"properties":{"authType":"OAuth2","category":"RemoteTool","connectorName":"$connector","target":"https://placeholder",
 "credentials":{},"peRequirement":"NotRequired",
 "metadata":{"type":"gateway_connector","toolEntityId":"$entity","connectionproperties":"{\"connectorName\":\"$connector\"}"}}}
JSON
az rest --method put --url "$base?api-version=$api" --headers 'Content-Type=application/json' --body "@$tmp/conn.json" -o none

oid="$(az ad signed-in-user show --query id -o tsv)"
cat > "$tmp/consent.json" <<JSON
{"parameters":[{"objectId":"$oid","parameterName":"token","redirectUrl":"https://ai.azure.com/nextgen/authConsentPopup","tenantId":"$AZURE_TENANT_ID"}]}
JSON
link="$(az rest --method post --url "$base/listConsentLinks?api-version=$api" --headers 'Content-Type=application/json' \
  --body "@$tmp/consent.json" --query 'value[0].link' -o tsv)"
[ -n "$link" ] || { echo "Could not get the GitHub consent link." >&2; exit 1; }

echo ""
echo "== Authorize GitHub for connection '$name' =="
echo "Open this URL in a browser, sign in to GitHub and approve (the page ends blank when it worked)."
echo "The account needs admin rights on the watched repo to register the issue webhook."
echo "$link"

i=0
while [ "$i" -lt 60 ]; do
  if [ "$(status)" = "Connected" ]; then echo "Connection '$name' is Connected."; exit 0; fi
  i=$((i + 1)); sleep 5
done
# The docs say the status only flips to Connected once actions are registered too, which a trigger-only
# connection never does, so do not fail the deployment here; the routine creation will show if consent is missing.
echo "WARNING: connection '$name' still reports '$(status)' after 5 minutes. Continuing; if routine creation fails, re-run: azd hooks run postprovision" >&2
