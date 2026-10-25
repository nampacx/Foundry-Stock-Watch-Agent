#!/bin/sh
# azd postprovision hook: creates the two GitHub connections and the toolbox.
#   github-conn : GitHub connector the routine's github_issue trigger uses (OAuth2)
#   github-mcp  : Foundry-managed GitHub MCP server (OAuth2) the agent reads code with
# Both need a one-time interactive GitHub consent, so this hook is interactive.
# The routine itself is created later by `azd deploy` (service "on-issue-opened").
set -eu
cd "$(dirname "$0")/.."

wait_for_consent() {
  name="$1"
  i=0
  while [ "$i" -lt 60 ]; do
    if azd ai connection show "$name" -o json 2>/dev/null | grep -Eq '"overallStatus"[[:space:]]*:[[:space:]]*"Connected"'; then
      echo "Connection '$name' is Connected."
      return 0
    fi
    if [ "$i" -eq 0 ]; then
      echo ""
      echo "== Authorize GitHub for connection '$name' =="
      echo "Open the consent URL below in a browser, sign in to GitHub and approve."
      echo "(The account needs admin rights on the watched repo to register the issue webhook.)"
      azd ai connection show "$name"
    fi
    i=$((i + 1))
    sleep 5
  done
  echo "Timed out waiting for consent on '$name'. Re-run: azd hooks run postprovision" >&2
  return 1
}

for pair in "github-conn:github" "github-mcp:foundrygithubmcp"; do
  name="${pair%%:*}"
  connector="${pair##*:}"
  echo "Creating connection '$name' (connector '$connector')..."
  azd ai connection create "$name" --connector-name "$connector" --force
  wait_for_consent "$name"
done

if azd ai toolbox show gh-triage-tools >/dev/null 2>&1; then
  echo "Toolbox 'gh-triage-tools' already exists, skipping."
else
  echo "Creating toolbox 'gh-triage-tools'..."
  azd ai toolbox create gh-triage-tools --from-file ./routines/toolbox.yaml
fi
