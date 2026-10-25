#!/bin/sh
# azd postprovision hook of the "github-mcp" layer: puts the GitHub PAT into Key Vault (secret 'github-pat').
# The Function App reads it through a Key Vault reference with its managed identity.
#   GITHUB_PAT  fine-grained PAT, read-only (Contents, Issues, Metadata) on the watched repo.
#               If unset you are prompted, unless the secret already exists (re-provision keeps it).
# The PAT is piped straight into Key Vault; it is never written to disk or the azd environment.
set -eu

: "${GITHUB_MCP_KEY_VAULT_NAME:?not set (provision the github-mcp layer first)}"
VAULT="$GITHUB_MCP_KEY_VAULT_NAME"

if [ -z "${GITHUB_PAT:-}" ]; then
  if az keyvault secret show --vault-name "$VAULT" --name github-pat --query id -o tsv >/dev/null 2>&1; then
    echo "Secret 'github-pat' already in Key Vault '$VAULT'; keeping it (set GITHUB_PAT to replace)."
    exit 0
  fi
  printf "GitHub PAT (read-only, input hidden): " >&2
  stty -echo 2>/dev/null || true
  read -r GITHUB_PAT
  stty echo 2>/dev/null || true
  echo >&2
fi
[ -n "$GITHUB_PAT" ] || { echo "No PAT provided." >&2; exit 1; }

echo "Storing PAT in Key Vault '$VAULT' (secret 'github-pat')..."
i=0
until printf '%s' "$GITHUB_PAT" | az keyvault secret set --vault-name "$VAULT" --name github-pat \
        --file /dev/stdin --encoding utf-8 -o none 2>/dev/null; do
  i=$((i + 1))
  [ "$i" -lt 12 ] || { echo "Could not write the secret (RBAC still propagating, or you lack Key Vault Secrets Officer)." >&2; exit 1; }
  echo "  waiting for role assignment to propagate..."; sleep 10
done
echo "Done."
