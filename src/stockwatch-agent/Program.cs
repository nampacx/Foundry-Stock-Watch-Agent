// Hosted stock-watch agent: Microsoft Agent Framework + Foundry hosted agent (Responses protocol).
//
// A Foundry routine fires on a schedule and sends a short prompt to this agent. The agent calls one tool,
// which reads the watchlist from Azure Table storage, researches the last 24h of analyst information per
// company (inner agent with web search) and stores one consolidated Markdown report in Blob storage.

using Azure.AI.Projects;
using Azure.Core;
using Azure.Data.Tables;
using Azure.Identity;
using Azure.Storage.Blobs;
using DotNetEnv;
using Microsoft.Agents.AI;
using Microsoft.Extensions.AI;
using Microsoft.Agents.AI.Foundry.Hosting;
using StockWatchAgent;

// Local development only; in Foundry the platform injects the environment.
Env.NoClobber().TraversePath().Load();

string projectEndpoint = Config.Required("FOUNDRY_PROJECT_ENDPOINT");
string deployment = Config.Required("AZURE_AI_MODEL_DEPLOYMENT_NAME");
string storageAccount = Config.Required("STORAGE_ACCOUNT_NAME");
string tableName = Config.Optional("WATCHLIST_TABLE", "watchlist")!;
string partition = Config.Optional("WATCHLIST_PARTITION", "stocks")!;
string reportsContainer = Config.Optional("REPORTS_CONTAINER", "stockwatch-reports")!;
int maxParallel = int.Parse(Config.Optional("MAX_PARALLEL_COMPANIES", "3")!);

// The platform-provided identity in Foundry; developer credentials locally.
TokenCredential credential = new DefaultAzureCredential();

var companies = new CompanyStore(
    new TableClient(new Uri($"https://{storageAccount}.table.core.windows.net"), tableName, credential), partition);
var reports = new ReportStore(
    new BlobContainerClient(new Uri($"https://{storageAccount}.blob.core.windows.net/{reportsContainer}"), credential));

IChatClient chatClient = new AIProjectClient(new Uri(projectEndpoint), credential)
    .GetProjectOpenAIClient()
    .GetProjectResponsesClientForModel(deployment)
    .AsIChatClient()
    // The Responses API requires "model" on every request; the project client does not add it by itself.
    .AsBuilder()
    .ConfigureOptions(o => o.ModelId ??= deployment)
    .Build();

var runner = new ReviewRunner(companies, new AnalystResearcher(chatClient), reports, maxParallel);

AIFunction reviewTool = AIFunctionFactory.Create(
    runner.RunAsync,
    name: "run_stock_watch",
    description: "Runs the complete daily analyst review: loads the watchlist, researches the last 24h of analyst " +
                 "information for every company, and saves one consolidated report to blob storage. Returns a status line with the report location.");

AIAgent agent = chatClient.AsAIAgent(
    instructions: """
        You run the user's daily stock-watch job. For every request, call run_stock_watch exactly once,
        then reply with its status line and nothing else. If the tool fails, report the error; do not retry.
        """,
    name: "stockwatch-agent",
    description: "Daily analyst-information review for the user's stock watchlist.",
    tools: [reviewTool]);

var builder = WebApplication.CreateBuilder(args);
builder.Services.AddFoundryResponses(agent);

var app = builder.Build();
app.MapFoundryResponses();
app.Run();
