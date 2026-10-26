#!/bin/sh
# azd postprovision hook: creates the GitHub connector the routine's
# github_issue trigger uses (OAuth2, one-time interactive consent; registering the issue webhook needs it).
# The agent's code access is NOT this connector: that is the github-rest-mcp connection, see
# scripts/register-github-mcp.sh. The routine itself is created later by `azd deploy`.
set -eu
cd "$(dirname "$0")/.."

is_connected() {
  azd ai connection show "$1" -o json 2>/dev/null | grep -Eq '"overallStatus"[[:space:]]*:[[:space:]]*"Connected"'
}

name="github-conn"
if is_connected "$name"; then
  echo "Connection '$name' is already Connected."
  exit 0
fi

echo "Creating connection '$name' (connector 'github')..."
azd ai connection create "$name" --auth-type oauth2 --connector-name github --force

i=0
while [ "$i" -lt 60 ]; do
  if is_connected "$name"; then echo "Connection '$name' is Connected."; exit 0; fi
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
exit 1
