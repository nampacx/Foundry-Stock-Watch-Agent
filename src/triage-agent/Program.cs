// Hosted bug-triage agent: Microsoft Agent Framework + Foundry hosted agent (Responses protocol).
//
// A Foundry routine fires on "GitHub issue opened" and posts the issue payload to this agent.
// The agent reads the repository through a Foundry toolbox (our own GitHub REST MCP server on Azure
// Functions) using read-only tools and answers with a structured triage report.

using Azure.AI.Projects;
using Azure.Core;
using Azure.Identity;
using DotNetEnv;
using Microsoft.Agents.AI;
using Microsoft.Agents.AI.Foundry.Hosting;
using Microsoft.Extensions.AI;
using ModelContextProtocol.Client;
using TriageAgent;

// Local development only; in Foundry the platform injects the environment.
Env.NoClobber().TraversePath().Load();

string projectEndpoint = Config.Required("FOUNDRY_PROJECT_ENDPOINT");
string deployment = Config.Required("AZURE_AI_MODEL_DEPLOYMENT_NAME");
string toolboxName = Config.Required("TOOLBOX_NAME");
string owner = Config.Required("GITHUB_OWNER");
string repository = Config.Required("GITHUB_REPOSITORY");
string modelApi = Config.Optional("MODEL_API", "chat") ?? "chat";

// The platform-injected (agent) managed identity in Foundry; developer credentials locally.
TokenCredential credential = new DefaultAzureCredential();

// --- Tools: the Foundry toolbox MCP endpoint (GitHub REST MCP server), read-only subset only. ---
using var toolboxHttp = new HttpClient(new BearerTokenHandler(credential, "https://ai.azure.com/.default"));
string toolboxUrl = $"{projectEndpoint.TrimEnd('/')}/toolboxes/{toolboxName}/mcp?api-version=v1";

await using McpClient mcpClient = await McpClient.CreateAsync(
    new HttpClientTransport(
        new HttpClientTransportOptions
        {
            Endpoint = new Uri(toolboxUrl),
            Name = toolboxName,
            TransportMode = HttpTransportMode.StreamableHttp,
        },
        toolboxHttp));

IList<McpClientTool> allTools = await mcpClient.ListToolsAsync();
List<AITool> tools = allTools.Where(t => ReadOnlyTools.IsAllowed(t.Name)).Cast<AITool>().ToList();
Console.WriteLine($"Toolbox '{toolboxName}': {allTools.Count} tools, {tools.Count} allowed (read-only): {string.Join(", ", tools.Select(t => t.Name))}");
if (tools.Count == 0)
    Console.Error.WriteLine($"WARNING: no allowed tools. Toolbox offered: {string.Join(", ", allTools.Select(t => t.Name))}");

// --- Model client ---
IChatClient chatClient = modelApi.Equals("chat", StringComparison.OrdinalIgnoreCase)
    ? ChatClientFactory.CreateMaiChatClient(projectEndpoint, deployment, credential)
    : new AIProjectClient(new Uri(projectEndpoint), credential)
        .GetProjectOpenAIClient()
        .GetProjectResponsesClientForModel(deployment)
        .AsIChatClient();

AIAgent agent = chatClient.AsAIAgent(
    instructions: Instructions.Build(owner, repository),
    name: "triage-agent",
    description: "Triages GitHub issues by inspecting repository code.",
    tools: tools);

var builder = WebApplication.CreateBuilder(args);
builder.Services.AddFoundryResponses(agent);

var app = builder.Build();
app.MapFoundryResponses();
app.Run();
