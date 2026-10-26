#!/bin/sh
# azd postprovision hook: creates the GitHub connector connection the routine's github_issue trigger uses
# (OAuth2, one-time interactive consent; registering the issue webhook needs it).
# The agent's code access is NOT this connector: that is the github-rest-mcp connection, see
# scripts/register-github-mcp.sh. The routine itself is created later by `azd deploy`.
#
# `azd ai connection create --connector-name github` (connections extension beta.11) does not attach the
# connector gateway metadata, so the connection can never be consented. This script therefore follows the
# documented REST flow: look the connector up in the Foundry Tools Catalog, PUT the connection with
# metadata.type=gateway_connector, mint the consent link, and once consented register the GitHub issue operations
# (metadata.mcpserverConfigProperties), as the Foundry portal does. Without the registered operations the platform
# never provisions the connector gateway (target stays https://placeholder) and the github_issue trigger silently
# never fires.
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
# Escape a JSON document so it can be embedded as a string value inside another JSON document.
jstr() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

# Operations the github_issue trigger needs registered on the connection (names as the Foundry portal lists them).
mcp_config='{"description":"","state":"Enabled","connectors":[{"name":"'"$connector"'","connectionName":"'"$name"'","displayName":"'"$connector"'","description":"","operations":[{"name":"IssueOpened","displayName":"When a new issue is opened and assigned to me","description":"","userParameters":[],"agentParameters":[]},{"name":"IssueClosed","displayName":"When an issue assigned to me is closed","description":"","userParameters":[],"agentParameters":[]}]}]}'

# PUT the connection. $1 = entity id, $2 = connectionproperties string, $3 = "register" to include the operations.
put_connection() {
  extra=""
  if [ "${3:-}" = "register" ]; then extra=',"mcpserverConfigProperties":"'"$(jstr "$mcp_config")"'"'; fi
  cat > "$tmp/conn.json" <<JSON
{"properties":{"authType":"OAuth2","category":"RemoteTool","connectorName":"$connector","target":"https://placeholder",
 "credentials":{},"peRequirement":"NotRequired",
 "metadata":{"type":"gateway_connector","toolEntityId":"$1","connectionproperties":"$(jstr "$2")"$extra}}}
JSON
  az rest --method put --url "$base?api-version=$api" --headers 'Content-Type=application/json' --body "@$tmp/conn.json" -o none
}

# Register the issue operations on an existing, consented connection. Like the Foundry portal, this runs after
# consent and echoes back the connectionproperties the platform stored (they gain the consent parameterValues).
# No-op when the operations are already registered.
register_operations() {
  if [ -n "$(az rest --method get --url "$base?api-version=$api" --query properties.metadata.mcpserverConfigProperties -o tsv 2>/dev/null)" ]; then return 0; fi
  echo "Registering GitHub issue operations on '$name'..."
  entity="$(az rest --method get --url "$base?api-version=$api" --query properties.metadata.toolEntityId -o tsv)"
  props="$(az rest --method get --url "$base?api-version=$api" --query properties.metadata.connectionproperties -o tsv)"
  put_connection "$entity" "$props" register
}

if [ "$(status)" = "Connected" ]; then
  # Also repairs a connection that was consented before the operations were registered: it is Connected but
  # has no connector gateway (target stays https://placeholder) and its trigger never fires.
  register_operations
  echo "Connection '$name' is already Connected."; exit 0
fi

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
conn_props='{"connectorName":"'"$connector"'"}'
put_connection "$entity" "$conn_props"

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
  if [ "$(status)" = "Connected" ]; then
    echo "Connection '$name' is Connected."
    register_operations
    exit 0
  fi
  i=$((i + 1)); sleep 5
done
# Not consented yet. Do not fail the deployment; a routine on an unconsented connection is created but its
# trigger never fires. Re-running the hook registers the operations once consent is recorded.
echo "WARNING: connection '$name' still reports '$(status)' after 5 minutes. Continuing; if routine creation fails, re-run: azd hooks run postprovision" >&2
