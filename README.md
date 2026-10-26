# Stock Watch: daily analyst review agent

A scheduled **Microsoft Foundry routine** wakes a **hosted agent** (C#, Microsoft Agent Framework) every weekday morning. The agent

1. loads your watchlist from **Azure Table storage**,
2. researches the **analyst information of the last 24h** for each company (rating changes, price targets, commentary) using Foundry's web search tool,
3. consolidates everything into **one Markdown report** and stores it in **Blob storage** for later review.

```
Foundry routine "stockwatch-daily-review" (cron, weekdays 07:00 Europe/Berlin)
      │  Responses API
      ▼
hosted agent "stockwatch-agent"  ── tool: run_stock_watch ──┐
                                                                   │ (deterministic C# job)
  Table "companies" ──▶ for each company (sequential by default):      │
                         inner agent + web search ─▶ company report │
                                                                   ▼
                          consolidated report ─▶ Blob  stockwatch-reports/yyyy/MM/analyst-report-yyyyMMdd-HHmmZ.md
```

The orchestration is plain C# (`ReviewRunner` in `src/stockwatch-agent/Support.cs`), exposed to the hosted agent as a single tool, so the run does not depend on the model remembering to loop over every company. One failing company is recorded in the report and does not stop the others.

| Piece | Where |
| --- | --- |
| Foundry account, project, model, ACR, Storage (table + container), App Insights, RBAC | `infra/main.bicep`, `infra/resources.bicep` |
| Hosted agent | `src/stockwatch-agent` |
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

## Prerequisites

- Azure subscription with `Owner` on the target subscription/resource group; a region where routines are available (not UK West, Switzerland West, Japan West, UAE North, Norway East). Suggested: `swedencentral`.
- [azd](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd) ≥ 1.27.1 and the extensions:
  ```bash
  azd extension install microsoft.foundry azure.ai.agents azure.ai.routines
  ```
- Azure CLI (`az login`) for the seed script; [.NET 10 SDK](https://dotnet.microsoft.com/download/dotnet/10.0) for local builds. Docker is not needed (remote build in ACR).
- Quota for `gpt-6-luna` (Global Standard, capacity 230).

## Deploy

```bash
azd auth login
azd env new stock-watch
azd up
./scripts/seed-watchlist.ps1
```

## Try it

Run the job right away instead of waiting for the schedule:

```bash
azd ai routine dispatch stockwatch-daily-review
azd ai routine run list stockwatch-daily-review
```

Then open the newest blob in container `stockwatch-reports` (portal → Storage account → Containers, or `az storage blob list --auth-mode login --account-name <STORAGE_ACCOUNT_NAME> -c stockwatch-reports -o table`).

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
| Report format / analyst prompt | `AnalystResearcher.Instructions`, `ReportComposer` in `Support.cs` |

## Notes and caveats

- **Data quality:** analyst info comes from web search, not a licensed data feed. Every item carries its source link; check before acting. Reports are information for your own review, not investment advice. If you later want structured data, add a function tool for a provider (Finnhub, FMP) to `AnalystResearcher`.
- **Identity:** storage access uses Entra only (shared keys are disabled). The hosted agent runs under its own instance identity, which only exists after `azd deploy`; the `postdeploy` hook `scripts/grant-agent-access.ps1` grants it *Storage Table Data Reader*, *Storage Blob Data Contributor* and *Azure AI User*. Re-run it by hand if you get 403s (needs Owner or User Access Administrator).
- **Run time:** a run takes about (companies ÷ MAX_PARALLEL_COMPANIES) × a few minutes. For long watchlists raise `MAX_PARALLEL_COMPANIES`, mind model rate limits, and check the routine/agent request timeout.
- **Telemetry:** the agent exports OpenTelemetry to the project's Application Insights (the platform injects `APPLICATIONINSIGHTS_CONNECTION_STRING` into the container, it is reserved and must not be set in `azure.yaml`; for local runs copy the `azd env get-values` output into `.env`). You get the model/agent spans (`gen_ai.*`), custom spans `analyst_review` and `research_company` (tag `stockwatch.ticker`), and metrics `stockwatch.companies.researched`, `stockwatch.companies.failed`, `stockwatch.company.duration`, `stockwatch.run.duration`. Prompt/response content is not captured. Example query (Logs, `customMetrics`): `customMetrics | where name startswith "stockwatch"`.
- **Preview:** routines, hosted agents and the `azd ai` extensions are in preview; manifest field names change between releases (this repo uses `agentName`/`timeZone` camelCase as in the previous version's manifest; the docs' azd examples show `agent_name`/`time_zone`, so adjust if `azd deploy` rejects the routine). Only the C# project and the Bicep have been built locally; a full `azd up` has not been run.

## Clean up

```bash
azd down --purge
```
