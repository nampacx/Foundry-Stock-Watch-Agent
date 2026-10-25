#!/bin/sh
# Deploys the GitHub REST -> MCP wrapper (Azure Function + Key Vault), stores the GitHub PAT in
# Key Vault and registers the MCP endpoint as Foundry connection "github-rest-mcp".
#
# Needs: az (logged in), .NET 10 SDK, zip, azd (with the azure.ai.connections extension), and
#   GITHUB_PAT  fine-grained PAT, read-only (Contents, Issues, Metadata) on the watched repo.
#               If unset you are prompted. It is piped straight into Key Vault, never written to disk.
# azd provides AZURE_RESOURCE_GROUP / AZURE_LOCATION; export them yourself when running standalone.
set -eu
cd "$(dirname "$0")/.."

: "${AZURE_RESOURCE_GROUP:?AZURE_RESOURCE_GROUP is not set (run via azd, or export it)}"
LOCATION="${AZURE_LOCATION:-swedencentral}"
CONNECTION="github-rest-mcp"

if [ -z "${GITHUB_PAT:-}" ]; then
  printf "GitHub PAT (read-only, input hidden): " >&2
  stty -echo 2>/dev/null || true
  read -r GITHUB_PAT
  stty echo 2>/dev/null || true
  echo >&2
fi
[ -n "$GITHUB_PAT" ] || { echo "No PAT provided." >&2; exit 1; }

# Whoever runs this stores the secret, so grant them Key Vault Secrets Officer (empty if not a user, e.g. CI).
ME="$(az ad signed-in-user show --query id -o tsv 2>/dev/null || true)"

echo "Deploying Function App + Key Vault..."
az deployment group create -g "$AZURE_RESOURCE_GROUP" -f infra/github-mcp.bicep \
  -n github-mcp -p location="$LOCATION" secretsOfficerPrincipalId="$ME" -o none
out() { az deployment group show -g "$AZURE_RESOURCE_GROUP" -n github-mcp --query "properties.outputs.$1.value" -o tsv; }
FUNC="$(out functionAppName)"
VAULT="$(out keyVaultName)"
ENDPOINT="$(out mcpEndpoint)"

echo "Storing PAT in Key Vault '$VAULT' (secret 'github-pat')..."
i=0
until printf '%s' "$GITHUB_PAT" | az keyvault secret set --vault-name "$VAULT" --name github-pat \
        --file /dev/stdin --encoding utf-8 -o none 2>/dev/null; do
  i=$((i + 1))
  [ "$i" -lt 12 ] || { echo "Could not write the secret (RBAC still propagating or no permission)." >&2; exit 1; }
  echo "  waiting for role assignment to propagate..."; sleep 10
done
unset GITHUB_PAT

echo "Building and publishing the function..."
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
dotnet publish src/github-mcp -c Release -o "$WORK/publish" --nologo -v q
(cd "$WORK/publish" && zip -qr "$WORK/app.zip" .)
az functionapp deployment source config-zip -g "$AZURE_RESOURCE_GROUP" -n "$FUNC" --src "$WORK/app.zip" -o none

echo "Reading the MCP system key..."
KEY=""
i=0
while [ -z "$KEY" ] && [ "$i" -lt 12 ]; do
  KEY="$(az functionapp keys list -g "$AZURE_RESOURCE_GROUP" -n "$FUNC" --query systemKeys.mcp_extension -o tsv 2>/dev/null || true)"
  [ -n "$KEY" ] || { i=$((i + 1)); sleep 10; }
done
[ -n "$KEY" ] || { echo "mcp_extension key not available yet; wait a minute and re-run." >&2; exit 1; }

echo "Creating Foundry connection '$CONNECTION' -> $ENDPOINT"
azd ai connection create "$CONNECTION" --kind remote-tool --target "$ENDPOINT" \
  --auth-type custom-keys --custom-key "x-functions-key=$KEY" --force
