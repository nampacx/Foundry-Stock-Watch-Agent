// Read-only API in front of the reports table, linked to the Static Web App as its /api backend.
// Storage access uses the function app's managed identity (Storage Table Data Reader); there are no keys or connection strings.

using Azure.Data.Tables;
using Azure.Identity;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Builder;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using StockWatchApi;

var builder = FunctionsApplication.CreateBuilder(args);

builder.ConfigureFunctionsWebApplication();
builder.Services
    .AddApplicationInsightsTelemetryWorkerService()
    .ConfigureFunctionsApplicationInsights();

string storageAccount = Config.Required("STORAGE_ACCOUNT_NAME");
// DefaultAzureCredential picks up the managed identity (AZURE_CLIENT_ID selects the user-assigned one); developer login locally.
var credential = new DefaultAzureCredential();
Uri tableEndpoint = new($"https://{storageAccount}.table.core.windows.net");

builder.Services.AddSingleton(new ReportReader(
    new TableClient(tableEndpoint, Config.Optional("WATCHLIST_TABLE", "watchlist"), credential),
    new TableClient(tableEndpoint, Config.Optional("REPORTS_TABLE", "reports"), credential),
    Config.Optional("WATCHLIST_PARTITION", "stocks")!));

builder.Build().Run();
