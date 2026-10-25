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
                                           toolbox "gh-triage-tools" (MCP)  ──▶  Foundry-managed GitHub MCP (github-mcp, OAuth2)
                                                                   │  read-only tools only (get_/list_/search_)
                                                                   ▼
                                                   triage report → routine run history
```

| Piece | Where |
| --- | --- |
| Foundry account, project, model deployment | `azure.yaml` (`ai-project` service, `infra.provider: microsoft.foundry`), no Bicep needed |
| Hosted agent | `src/triage-agent` (`Program.cs`, `Support.cs`, `Dockerfile`) |
| GitHub connections + toolbox | `scripts/setup-connections.{ps1,sh}` (azd `postprovision` hook), `routines/toolbox.yaml` |
| Routine | `routines/on-issue-opened.yaml`, registered as azd service `on-issue-opened` (`host: azure.ai.routine`) |

## About the identity model

The original idea was to use the project **managed identity** for the GitHub connection. GitHub cannot validate Entra tokens, so a managed identity cannot authenticate to GitHub directly. This sample therefore uses Foundry's **managed GitHub connectors with OAuth2** (one-time consent by a GitHub user). Managed identity is still used everywhere Azure supports it: the hosted agent calls the model and the toolbox with its platform-provided identity (`DefaultAzureCredential`), and the image build/pull uses the project's Azure resources. If you need a managed-identity-only path, store a GitHub App key in Key Vault and have the agent read it with its identity.

## Prerequisites

- Azure subscription, `Owner` on the target resource group/subscription (azd creates it), region **not** one of: UK West, Switzerland West, Japan West, UAE North, Norway East (routines unavailable). Default region to pick: `swedencentral`.
- [azd](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd) ≥ 1.27.1 (tested with 1.31.1) and the extensions:
  ```bash
  azd extension install microsoft.foundry azure.ai.agents azure.ai.connections azure.ai.toolboxes azure.ai.routines
  ```
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
2. **postprovision hook**: creates `github-conn` (routine trigger) and `github-mcp` (agent code access), prints a GitHub consent URL for each (open it, sign in, approve), then creates the `gh-triage-tools` toolbox.
3. **deploy**: builds and publishes the hosted agent `triage-agent`, then creates the routine `on-issue-opened`.

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

- Issue text is untrusted input. The agent instructions tell it to ignore embedded instructions, and the agent only receives tools whose names start with `get_`, `list_`, `search_` or `read_` (`ReadOnlyTools` in `Support.cs`). Also select only read actions when you configure the GitHub connector.
- The GitHub OAuth consent is tied to the consenting user. If that user loses access to the repo, the trigger stops firing.

## Clean up

```bash
azd down --purge
```

## Status

Routines, hosted agents, toolboxes and the `azd ai` extensions are in preview; flags and manifest field names change between releases (for example the azd routine manifest uses `connectionId`/`issueEvent`/`agentName`, not the REST snake_case names). This sample has been built and statically checked; a full `azd up` against a subscription has not been run yet.
