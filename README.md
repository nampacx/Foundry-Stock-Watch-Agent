# Foundry Routines sample: GitHub issue bug triage

A new GitHub issue fires a **Microsoft Foundry routine**. The routine invokes a **hosted agent** (C#, Microsoft Agent Framework) that reads the repository's code and replies with a structured triage report. Everything, including the routine, is deployed with the Azure Developer CLI (`azd`).

```
GitHub issue opened
      │  (github-conn: GitHub connector, OAuth2)
      ▼
Foundry routine "on-issue-opened"  ── issue payload as input ─▶  hosted agent "triage-agent"
                                                                   │  Responses protocol, C# / Agent Framework
                                                                   │  model: MAI-Thinking-1
                                                                   ▼
                                           toolbox "gh-triage-tools" (MCP)  ──▶  Azure Function MCP server (github-rest-mcp)
                                                                   │                                     │  PAT from Key Vault (managed identity)
                                                                   │                                     ▼  GitHub REST API
                                                                   │  read-only tools only (get_/list_/search_)
                                                                   ▼
                                                   triage report → routine run history
```

| Piece | Where |
| --- | --- |
| Foundry account, project, model deployment | `azure.yaml` (`ai-project` service, `foundry` layer with the `microsoft.foundry` provider), no Bicep needed |
| Hosted agent | `src/triage-agent` (`Program.cs`, `Support.cs`, `Dockerfile`) |
| GitHub MCP server (REST wrapper) | `src/github-mcp` (Azure Functions MCP extension), `infra/github-mcp/` (Bicep layer: Function App, Key Vault, RBAC), `scripts/store-github-pat.*`, `scripts/register-github-mcp.*` |
| GitHub connection + toolbox | `scripts/setup-connections.*`, `scripts/register-github-mcp.*`, `routines/toolbox.yaml` |
| Routine | `routines/on-issue-opened.yaml`, registered as azd service `on-issue-opened` (`host: azure.ai.routine`) |

## About the identity model

The original idea was to use the project **managed identity** for the GitHub connection. GitHub cannot validate Entra tokens, so a managed identity cannot authenticate to GitHub directly. This sample therefore uses Foundry's **managed GitHub connectors with OAuth2** (one-time consent by a GitHub user). Managed identity is still used everywhere Azure supports it: the hosted agent calls the model and the toolbox with its platform-provided identity (`DefaultAzureCredential`), and the image build/pull uses the project's Azure resources. If you need a managed-identity-only path, store a GitHub App key in Key Vault and have the agent read it with its identity.

## GitHub access for the agent: REST wrapper + PAT in Key Vault

The Foundry-managed GitHub MCP connector (`foundrygithubmcp`, OAuth) reported *unauthenticated* in practice, and MCP calls only worked through a toolbox connection. So the agent no longer uses it. Instead `src/github-mcp` is an **MCP server on Azure Functions** that wraps the GitHub REST API:

- Tools (read-only): `get_file_contents`, `search_code`, `get_issue`, `list_issues`, `search_issues`, `list_commits`.
- The **GitHub PAT lives in Key Vault** (`github-pat`). The Function App reads it through a Key Vault reference with its system-assigned managed identity (`Key Vault Secrets User`); the PAT is not in code, app settings values, the azd environment or the repo.
- The Function endpoint (`/runtime/webhooks/mcp`) is protected by the MCP extension system key. After `azd deploy` of the function, the `postdeploy` hook registers it as Foundry connection `github-rest-mcp` (`custom-keys`, header `x-functions-key`) and creates the toolbox that exposes it to the agent. The agent code is unchanged.
- The routine trigger still uses the OAuth connector `github-conn`: registering the issue webhook needs it and it is unrelated to the MCP path.

Everything is driven by azd (`azure.yaml`):

| Step | What |
| --- | --- |
| `infra.layers.foundry` | Foundry account/project/model (microsoft.foundry provider); hook creates `github-conn` (consent) |
| `infra.layers.github-mcp` | `infra/github-mcp`: resource group, Function App (Flex Consumption), Key Vault, RBAC; hook `store-github-pat` writes the PAT |
| service `github-mcp` (`host: function`) | `azd deploy` publishes `src/github-mcp`; `postdeploy` hook `register-github-mcp` creates the connection + toolbox |
| service `triage-agent` | `uses` `github-mcp`, so it deploys after the toolbox exists |

Create a **fine-grained PAT** limited to the watched repo with read-only *Contents*, *Issues* and *Metadata*. `azd up` prompts for it (or set `GITHUB_PAT` first); on later runs an existing secret is kept. To rotate: `GITHUB_PAT=... azd provision github-mcp`, or add a new version of `github-pat` yourself; the app picks it up within about a day, or restart the Function App to apply it immediately.

Run it locally: copy `src/github-mcp/local.settings.json.example` to `local.settings.json`, set `GITHUB_PAT`, `func start`, and point an MCP client at `http://localhost:7071/runtime/webhooks/mcp`.

## Prerequisites

- Azure subscription, `Owner` on the target resource group/subscription (azd creates it), region **not** one of: UK West, Switzerland West, Japan West, UAE North, Norway East (routines unavailable). Default region to pick: `swedencentral`.
- [azd](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd) ≥ 1.27.1 (tested with 1.31.1) and the extensions:
  ```bash
  azd extension install microsoft.foundry azure.ai.agents azure.ai.connections azure.ai.toolboxes azure.ai.routines
  ```
- Azure CLI (`az`, logged in; the hooks use it for Key Vault and the Function key) and the [Azure Functions Core Tools](https://learn.microsoft.com/azure/azure-functions/functions-run-local) only for local runs.
- [.NET 10 SDK](https://dotnet.microsoft.com/download/dotnet/10.0) for local builds. Docker is **not** required: the image is built remotely in ACR (`remoteBuild: true`).
- A GitHub account with **admin rights on the watched repository** (needed to register the issue webhook).
- **Quota for `MAI-Thinking-1`** (preview, Global Standard). The default tier is 0 TPM, so request quota first. Fallback: see "Switching models".

## Deploy

```bash
azd auth login
azd env new triage-demo                 # pick swedencentral when prompted for location
azd up
```

`azd up` does the following:

1. **provision**: creates the Foundry account, project, and the model deployment.
2. **postprovision hooks**: the `foundry` layer creates `github-conn` (routine trigger; prints a GitHub consent URL to open and approve); the `github-mcp` layer provisions the Function App + Key Vault and stores your PAT.
3. **deploy**: publishes the GitHub MCP function, then its hook registers the `github-rest-mcp` connection and the `gh-triage-tools` toolbox; then builds and publishes the hosted agent `triage-agent` and creates the routine `on-issue-opened`.

To watch a different repo, edit `owner`/`repository` in `routines/on-issue-opened.yaml` and `GITHUB_OWNER`/`GITHUB_REPOSITORY` in `azure.yaml`.

## Try it

Manual dispatch with a sample payload (no GitHub event needed):

```bash
azd ai routine dispatch on-issue-opened --input "$(cat scripts/sample-issue.json)"
azd ai routine run list on-issue-opened
```

Then open a real issue in the watched repo and check the run history again. The triage report is the agent's response in the run record. This sample does **not** write back to GitHub.

Run the agent locally against the deployed project (needs `az login` and a `.env` based on `src/triage-agent/.env.example`):

```bash
cd src/triage-agent && dotnet run
```

## Switching models

`MAI-Thinking-1` supports Chat Completions only (served at `{account}/mai/v1`), so the agent uses `MODEL_API=chat`. To use another model, e.g. `gpt-6-luna` (2026-09-22): replace the deployment in `azure.yaml`, set `AZURE_AI_MODEL_DEPLOYMENT_NAME: gpt-6-luna` and `MODEL_API: responses`, then `azd up`. A commented example is in `azure.yaml`.

## Safety notes

- Issue text is untrusted input. The agent instructions tell it to ignore embedded instructions, and the agent only receives tools whose names start with `get_`, `list_`, `search_` or `read_` (`ReadOnlyTools` in `Support.cs`). The Function exposes read tools only and the PAT should be read-only too.
- The GitHub OAuth consent is tied to the consenting user. If that user loses access to the repo, the trigger stops firing.

## Clean up

```bash
azd down --purge   # both layers; --purge also purges the soft-deleted Key Vault
```

## Status

Routines, hosted agents, toolboxes and the `azd ai` extensions are in preview; flags and manifest field names change between releases (for example the azd routine manifest uses `connectionId`/`issueEvent`/`agentName`, not the REST snake_case names). This sample has been statically checked only (the Function project and Bicep were not compiled in the authoring environment); a full `azd up` against a subscription has not been run yet.
