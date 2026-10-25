#!/bin/sh
# azd postdeploy hook of the "github-mcp" service: the MCP extension's system key only exists once the
# function code is running, so the Foundry wiring happens here, after `azd deploy` of the function.
#   1. connection "github-rest-mcp" (custom-keys: x-functions-key) -> the Function's MCP endpoint
#   2. toolbox "gh-triage-tools" exposing that connection to the agent (created once)
# The triage-agent service is deployed after this one (it `uses` github-mcp), so the toolbox exists when it starts.
set -eu
cd "$(dirname "$0")/.."

: "${GITHUB_MCP_FUNCTION_NAME:?not set}" "${GITHUB_MCP_RESOURCE_GROUP:?not set}" "${GITHUB_MCP_ENDPOINT:?not set}"

echo "Reading the MCP system key of '$GITHUB_MCP_FUNCTION_NAME'..."
KEY=""
i=0
while [ -z "$KEY" ] && [ "$i" -lt 18 ]; do
  KEY="$(az functionapp keys list -g "$GITHUB_MCP_RESOURCE_GROUP" -n "$GITHUB_MCP_FUNCTION_NAME" --query systemKeys.mcp_extension -o tsv 2>/dev/null || true)"
  [ -n "$KEY" ] || { i=$((i + 1)); sleep 10; }
done
[ -n "$KEY" ] || { echo "mcp_extension key not available (is the function code deployed and running?)." >&2; exit 1; }

echo "Creating Foundry connection 'github-rest-mcp' -> $GITHUB_MCP_ENDPOINT"
azd ai connection create github-rest-mcp --kind remote-tool --target "$GITHUB_MCP_ENDPOINT" \
  --auth-type custom-keys --custom-key "x-functions-key=$KEY" --force

if azd ai toolbox show gh-triage-tools >/dev/null 2>&1; then
  echo "Toolbox 'gh-triage-tools' already exists, skipping."
else
  echo "Creating toolbox 'gh-triage-tools'..."
  azd ai toolbox create gh-triage-tools --from-file ./routines/toolbox.yaml
fi
