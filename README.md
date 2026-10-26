# Stock Watch: a demo for Microsoft Foundry routines and hosted agents

> **This is a demo repository.** It shows how to run a **recurring, agent-driven job in Microsoft Foundry without hosting or operating anything yourself**. The stock analyst review is only a realistic, easy-to-follow workload to put behind it. It is not a production system and not investment advice.

## The point of the demo

A **routine** triggers an agent on a schedule, and a **hosted agent** runs it. Foundry provides the scheduler and the agent runtime, so there is no server, container host, cron box or queue for you to maintain.

This repo shows, end to end:

- a **routine** (cron schedule) that invokes a **hosted agent**,
- how little you need around it: one `azd up` and a Bicep template,
- the agent reaching Azure Storage with its **own Entra identity** (no keys, no connection strings),
- a model with the **web search tool** doing the actual research,
- **OpenTelemetry** from the agent into Application Insights,
- a result you can actually look at when the run is done.

The workload is swappable: replace the stock research with any job you want to run on a schedule.

## What the example job does

Every weekday morning the routine wakes the agent, which

1. loads a watchlist of companies from a Table storage table,
2. researches the **analyst news of the last 24h** per company (rating changes, price targets, commentary) with Foundry's web search tool,
3. writes one report row per company and run to a second table.

```
Foundry routine (cron, weekdays 07:00 Europe/Berlin)
        │  Responses API
        ▼
Hosted agent  ──▶  Table "watchlist"  ──▶  per company: model + web search
        │
        ▼
Table "reports"   ◀── read by a small viewer (React on Static Web Apps + Functions API)
```

The viewer and its API exist only so the output is visible in a browser. They are plain tooling around the demo, not part of what it is about. You can skip them and read the `reports` table in the portal instead.

## Repository layout

| What | Where |
| --- | --- |
| Routine (the schedule) | `routines/stockwatch-daily-review.yaml` |
| Hosted agent (C#, Microsoft Agent Framework) | `src/stockwatch-agent` |
| Infrastructure (Foundry, model, storage, RBAC, App Insights, viewer hosting) | `infra/` |
| Viewer: React app and read-only Functions API | `src/web`, `src/api` |
| Watchlist seeding | `scripts/seed-watchlist.ps1`, `watchlist.example.csv` |

The orchestration is plain C# (`ReviewRunner` in `src/stockwatch-agent/Support.cs`), exposed to the agent as a single tool, so the run does not depend on the model remembering to loop over every company. One failing company becomes a failed row and does not stop the others.

## Prerequisites

- Azure subscription with `Owner`, in a region where routines are available (not UK West, Switzerland West, Japan West, UAE North, Norway East). Suggested: `swedencentral`.
- [azd](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd) ≥ 1.27.1 with the extensions:
  ```bash
  azd extension install microsoft.foundry azure.ai.agents azure.ai.routines
  ```
- Azure CLI (`az login`), [.NET 10 SDK](https://dotnet.microsoft.com/download/dotnet/10.0) and Node.js 20+ (`azd deploy` builds the agent and the viewer). Docker is not needed; the agent image is built remotely in ACR.
- Quota for `gpt-6-luna` (Global Standard, capacity 230).

## Deploy

```bash
azd auth login
azd env new stock-watch
azd up
./scripts/seed-watchlist.ps1
```

`azd up` provisions everything and deploys the hosted agent, the routine and the viewer. It prints `STATIC_WEB_APP_URL`, the address of the viewer.

## Try it

Don't wait for the schedule, dispatch the routine now:

```bash
azd ai routine dispatch stockwatch-daily-review
azd ai routine run list stockwatch-daily-review
```

Then open the viewer at `STATIC_WEB_APP_URL`, or browse the `reports` table (portal → Storage account → Storage browser → Tables).

To run the agent locally against the deployed project (needs `az login` and a `.env` based on `src/stockwatch-agent/.env.example`):

```bash
cd src/stockwatch-agent && dotnet run
```

## Configuration

| What | Where |
| --- | --- |
| Schedule | `cronExpression` / `timeZone` in `routines/stockwatch-daily-review.yaml` |
| Model | `infra/main.parameters.json` + `azure.yaml` (`AZURE_AI_MODEL_DEPLOYMENT_NAME`) |
| Parallelism | env `MAX_PARALLEL_COMPANIES` (default 1) |
| Analyst prompt / report format | `AnalystResearcher.Instructions`, `ReportStore` in `Support.cs` |

## Data model

- **`watchlist`**: `PartitionKey` = `stocks`, `RowKey` = ticker, plus `Name`, optional `Exchange`, optional `Active` (`false` skips the company). Seed it from a CSV (`Ticker,Name,Exchange`) with the script above, or edit rows in the portal.
- **`reports`**: one row per company and run. `PartitionKey` = ticker, `RowKey` = inverted run time (newest first), plus `RunUtc`, `Sentiment` (`bullish`, `neutral`, `bearish`, `none`, `failed`), `Failed` and `Markdown` (the report, truncated at 30,000 characters).

## Notes and caveats

- **Data quality:** analyst info comes from web search, not a licensed data feed. Every item carries its source link; check before acting. Not investment advice.
- **Identity:** storage access is Entra only (shared keys are disabled). The hosted agent's identity exists only after `azd deploy`, so the `postdeploy` hook `scripts/grant-agent-access.ps1` grants it *Storage Table Data Contributor* and *Azure AI User*. Re-run it by hand on 403s (needs Owner or User Access Administrator). The viewer's API uses its own managed identity with read-only table access.
- **Run time:** roughly (companies ÷ `MAX_PARALLEL_COMPANIES`) × a few minutes. For long watchlists raise the parallelism, mind model rate limits, and check the routine/agent request timeout.
- **Telemetry:** the agent exports OpenTelemetry to the project's Application Insights (the platform injects `APPLICATIONINSIGHTS_CONNECTION_STRING`; don't set it in `azure.yaml`). You get `gen_ai.*` spans, custom spans `analyst_review` and `research_company`, and metrics `stockwatch.companies.researched`, `stockwatch.companies.failed`, `stockwatch.company.duration`, `stockwatch.run.duration`. Prompt/response content is not captured. Try: `customMetrics | where name startswith "stockwatch"`.
- **Preview:** routines, hosted agents and the `azd ai` extensions are in preview and manifest field names change between releases. This repo uses `agentName`/`timeZone`; if `azd deploy` rejects the routine, try `agent_name`/`time_zone` as in the docs.
- **Viewer is public:** anyone with the URL can read the reports. To restrict it, add `allowedRoles` routes and a login redirect in `src/web/public/staticwebapp.config.json`.
- **Viewer pinning:** `Microsoft.ApplicationInsights.WorkerService` is pinned to 2.x in `src/api/StockWatchApi.csproj`; 3.x crashes the Functions worker on startup (502 on `/api`). Reproduce locally with `func start`.

## Clean up

```bash
azd down --purge
```
