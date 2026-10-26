using GitHubMcp;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Builder;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;

var builder = FunctionsApplication.CreateBuilder(args);

builder.Services.AddApplicationInsightsTelemetryWorkerService();
builder.Services.ConfigureFunctionsApplicationInsights();

// GITHUB_PAT is an app setting (local.settings.json locally; set by infra/resources.bicep in Azure).
builder.Services.AddHttpClient<GitHubRestClient>(client =>
{
    string pat = Environment.GetEnvironmentVariable("GITHUB_PAT")
        ?? throw new InvalidOperationException("GITHUB_PAT is not set.");
    client.BaseAddress = new Uri("https://api.github.com/");
    client.DefaultRequestHeaders.Authorization = new("Bearer", pat.Trim());
    client.DefaultRequestHeaders.UserAgent.ParseAdd("foundry-gh-triage-mcp/1.0");
    client.DefaultRequestHeaders.Accept.ParseAdd("application/vnd.github+json");
    client.DefaultRequestHeaders.Add("X-GitHub-Api-Version", "2022-11-28");
    client.Timeout = TimeSpan.FromSeconds(20);
});

builder.Build().Run();
