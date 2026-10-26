#!/bin/sh
# azd preprovision hook: makes sure GITHUB_PAT is set in the azd environment so Bicep can put it into the
# Function App's settings (infra/main.parameters.json -> githubPat). It is stored in .azure/<env>/.env
# (git-ignored, plain text); to rotate: `azd env set GITHUB_PAT <new>` then `azd provision`.
set -eu
if [ -n "${GITHUB_PAT:-}" ]; then echo "GITHUB_PAT is set."; exit 0; fi
printf "GitHub PAT (fine-grained, read-only Contents/Issues/Metadata; input hidden): " >&2
stty -echo 2>/dev/null || true
read -r pat
stty echo 2>/dev/null || true
echo >&2
[ -n "$pat" ] || { echo "No PAT provided." >&2; exit 1; }
azd env set GITHUB_PAT "$pat"
