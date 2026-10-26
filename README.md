# Stock Watch: a demo for Microsoft Foundry routines

> **This is a demo repository.** It exists to try out **routines in Microsoft Foundry** together with a **hosted agent**, using a daily stock analyst review as the example workload. It is not a production system and not investment advice.

## Motivation

I heard about **routines** in Microsoft Foundry and wanted to test them. The idea that appealed to me: a routine triggers an agent on a schedule, and a hosted agent runs it, so I can get a recurring, agent-driven job **without hosting or operating anything myself**. No server, scheduler, container host or cron box to maintain. Foundry runs the schedule and the agent runtime.

What this repo is meant to show:

- how a **routine** (cron schedule) invokes a **hosted agent** end to end,
- how little infrastructure is needed around it (Bicep + `azd up`),
- how the agent uses its own **Entra identity** to reach storage, plus telemetry in Application Insights,
- how the results can be browsed in a small **React** viewer on Azure Static Web Apps, served by a **C# Function app** that reads the data with a managed identity.

The stock analyst review is just a realistic, easy-to-follow job to put behind the routine; swap it for any recurring task.

## What the demo does

A scheduled **Microsoft Foundry routine** wakes a **hosted agent** (C#, Microsoft Agent Framework) every weekday morning. The agent

1. loads your watchlist from **Azure Table storage**,
2. researches the **analyst information of the last 24h** for each company (rating changes, price targets, commentary) using Foundry's web search tool,
3. stores **one row per company and run** in a **Table storage** table, which a small web app displays.

```
Foundry routine "stockwatch-daily-review"
(cron, weekdays 07:00 Europe/Berlin)
        │
        │ Responses API
        ▼
Hosted agent "stockwatch-agent"
        │
        │ tool: run_stock_watch (deterministic C# job)
        ▼
Table "watchlist" ──▶ for each company (sequential by default):
                        inner agent + web search ──▶ company report
        │
        ▼
Table "reports"   PartitionKey = ticker, RowKey = inverted run time
        ▲
        │ Storage Table Data Reader (managed identity)
Function app (C#, Flex Consumption)  ◀── linked as /api ──  Static Web App (React + Vite, public)
```

The orchestration is plain C# (`ReviewRunner` in `src/stockwatch-agent/Support.cs`), exposed to the hosted agent as a single tool, so the run does not depend on the model remembering to loop over every company. One failing company is recorded as a failed row and does not stop the others.

| Piece | Where |
| --- | --- |
| Foundry account, project, model, ACR, Storage (tables), App Insights, Function app, Static Web App, RBAC | `infra/main.bicep`, `infra/resources.bicep` |
| Hosted agent | `src/stockwatch-agent` |
| Read-only API (C#, Azure Functions) | `src/api` (azd service `api`) |
| Report viewer (React + Vite) | `src/web` (azd service `web`) |
| Schedule | `routines/stockwatch-daily-review.yaml` (azd service `stockwatch-daily-review`) |
| Watchlist seeding | `scripts/seed-watchlist.ps1`, `watchlist.example.csv` |

## Watchlist table

Table `watchlist`, one row per company:

| Column | Meaning |
| --- | --- |
| `PartitionKey` | `stocks` |
| `RowKey` | ticker, e.g. `MSFT` |
| `Name` | company name (falls back to the ticker) |
| `Exchange` | optional, helps disambiguate tickers |
| `Active` | optional bool; `false` skips the company |

Seed or update it from a CSV (`Ticker,Name,Exchange`):

```powershell
./scripts/seed-watchlist.ps1 -Csv watchlist.example.csv
```

Or edit rows in the Azure portal / Storage Explorer.

## Reports table

Table `reports`, one row per company and run (so a row stays far below the 64 KB property limit of Table storage):

| Column | Meaning |
| --- | --- |
| `PartitionKey` | ticker, e.g. `MSFT` |
| `RowKey` | inverted run time (`MaxTicks - runTicks`, 19 digits), so a query returns the newest report first |
| `Ticker`, `Name`, `Exchange` | company |
| `RunUtc`, `WindowStartUtc` | run time and start of the 24h window |
| `Sentiment` | `bullish`, `neutral`, `bearish`, `none` or `failed` |
| `Failed` | `true` if the research failed |
| `Markdown` | the analyst report of this company (truncated at 30,000 characters) |

## Report viewer

The viewer is a React + Vite app on **Azure Static Web Apps** (Standard plan, needed to link a backend). It calls `/api/companies` and `/api/companies/{ticker}/reports`, served by a separate **Function app**.

Why a Function app instead of the Static Web App's built-in (managed) API: managed functions have no managed identity, and the Static Web App's own identity is only used to read auth secrets from Key Vault. A linked Function app can have a managed identity, so the API reads the tables with *Storage Table Data Reader* and there are no keys or connection strings (shared keys are disabled on both storage accounts).

Access: the site is currently **public**, anyone with the URL can read the reports (`azd env get-values` shows `STATIC_WEB_APP_URL`). The Function app itself is only reachable through the Static Web App. To restrict it later, add `allowedRoles` routes and a login redirect to `src/web/public/staticwebapp.config.json` and invite users with `az staticwebapp users invite`.

Local development:

- API: in `src/api` copy `local.settings.json.example` to `local.settings.json` and set `STORAGE_ACCOUNT_NAME`. The Functions host needs a storage emulator for its own state (`npx azurite --silent --location ./azurite`, matching `AzureWebJobsStorage=UseDevelopmentStorage=true`); data access uses your `az login` identity, which needs a table role on the storage account (granted to the deploying user by Bicep). Then run `func start` (requires Azure Functions Core Tools).
- Web: `npm install && npm run dev` in `src/web`; Vite proxies `/api` to `localhost:7071` and there is no login.

To redeploy only the viewer after a change: `azd deploy api` and/or `azd deploy web`.

## Prerequisites

- Azure subscription with `Owner` on the target subscription/resource group; a region where routines are available (not UK West, Switzerland West, Japan West, UAE North, Norway East). Suggested: `swedencentral`.
- [azd](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd) ≥ 1.27.1 and the extensions:
  ```bash
  azd extension install microsoft.foundry azure.ai.agents azure.ai.routines
  ```
- Azure CLI (`az login`) for the seed script; [.NET 10 SDK](https://dotnet.microsoft.com/download/dotnet/10.0) and Node.js 20+ for local builds and the viewer (`azd deploy` builds both). Docker is not needed (remote build in ACR).
- Quota for `gpt-6-luna` (Global Standard, capacity 230).

## Deploy

```bash
azd auth login
azd env new stock-watch
azd up
./scripts/seed-watchlist.ps1
```

`azd up` provisions everything (Foundry, storage, Function app, Static Web App) and deploys all services: the hosted agent, the API (`api`), the React viewer (`web`) and the routine. It prints `STATIC_WEB_APP_URL`, the address of the viewer.

## Try it

Run the job right away instead of waiting for the schedule:

```bash
azd ai routine dispatch stockwatch-daily-review
azd ai routine run list stockwatch-daily-review
```

Then open the viewer at `STATIC_WEB_APP_URL`, or look at the rows in the `reports` table (portal → Storage account → Storage browser → Tables).

Locally against the deployed project (needs `az login`, a `.env` based on `src/stockwatch-agent/.env.example`):

```bash
cd src/stockwatch-agent && dotnet run
```

## Configuration

| What | Where |
| --- | --- |
| Schedule | `cronExpression` / `timeZone` in `routines/stockwatch-daily-review.yaml` |
| Model | `infra/main.parameters.json` + `azure.yaml` (`AZURE_AI_MODEL_DEPLOYMENT_NAME`) |
| Parallelism | env `MAX_PARALLEL_COMPANIES` (default 1) |
| Analyst prompt / report row format | `AnalystResearcher.Instructions`, `ReportStore` in `Support.cs` |

## Notes and caveats

- **Data quality:** analyst info comes from web search, not a licensed data feed. Every item carries its source link; check before acting. Reports are information for your own review, not investment advice. If you later want structured data, add a function tool for a provider (Finnhub, FMP) to `AnalystResearcher`.
- **Identity:** storage access uses Entra only (shared keys are disabled). The hosted agent runs under its own instance identity, which only exists after `azd deploy`; the `postdeploy` hook `scripts/grant-agent-access.ps1` grants it *Storage Table Data Contributor* and *Azure AI User*. The Function app uses a user-assigned identity with *Storage Table Data Reader* on the data account, created by Bicep. Re-run it by hand if you get 403s (needs Owner or User Access Administrator).
- **Run time:** a run takes about (companies ÷ MAX_PARALLEL_COMPANIES) × a few minutes. For long watchlists raise `MAX_PARALLEL_COMPANIES`, mind model rate limits, and check the routine/agent request timeout.
- **Telemetry:** the agent exports OpenTelemetry to the project's Application Insights (the platform injects `APPLICATIONINSIGHTS_CONNECTION_STRING` into the container, it is reserved and must not be set in `azure.yaml`; for local runs copy the `azd env get-values` output into `.env`). You get the model/agent spans (`gen_ai.*`), custom spans `analyst_review` and `research_company` (tag `stockwatch.ticker`), and metrics `stockwatch.companies.researched`, `stockwatch.companies.failed`, `stockwatch.company.duration`, `stockwatch.run.duration`. Prompt/response content is not captured. Example query (Logs, `customMetrics`): `customMetrics | where name startswith "stockwatch"`.
- **Preview:** routines, hosted agents and the `azd ai` extensions are in preview; manifest field names change between releases (this repo uses `agentName`/`timeZone` camelCase as in the previous version's manifest; the docs' azd examples show `agent_name`/`time_zone`, so adjust if `azd deploy` rejects the routine). The whole stack has been deployed with `azd up`: the linked *Flex Consumption* Function app works as the Static Web App backend, although the Static Web Apps docs only list Consumption, Premium and Dedicated plans for this; if linking ever fails, host the API on a Premium or Dedicated plan instead.
- **API package versions:** `Microsoft.ApplicationInsights.WorkerService` is pinned to 2.x in `src/api/StockWatchApi.csproj`. Version 3.x does not work with `Microsoft.Azure.Functions.Worker.ApplicationInsights` 2.x; the worker crashes on startup (`TypeLoadException ... ITelemetryInitializer`) and the Static Web App shows a 502 for `/api`. Reproduce such problems locally with `func start`.

## Clean up

```bash
azd down --purge
```
