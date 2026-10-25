using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Extensions.Mcp;

namespace GitHubMcp;

/// <summary>
/// MCP tools exposed at /runtime/webhooks/mcp. Names deliberately use the get_/list_/search_
/// prefixes so the triage agent's read-only filter (ReadOnlyTools in Support.cs) lets them through.
/// There are no write tools: the PAT should be read-only anyway, this is defence in depth.
/// </summary>
public sealed class GitHubTools(GitHubRestClient github)
{
    private const string Owner = "owner";
    private const string Repo = "repo";

    [Function(nameof(get_file_contents))]
    public Task<string> get_file_contents(
        [McpToolTrigger("get_file_contents", "Read a file (decoded text) or list a directory in a GitHub repository.")] ToolInvocationContext context,
        [McpToolProperty(Owner, "Repository owner (user or organisation).", true)] string owner,
        [McpToolProperty(Repo, "Repository name.", true)] string repo,
        [McpToolProperty("path", "File or directory path; use '' or '/' for the repository root.", true)] string path,
        [McpToolProperty("ref", "Branch, tag or commit SHA. Defaults to the default branch.", false)] string? @ref) =>
        github.GetFileContents(owner, repo, path ?? "", @ref, CancellationToken.None);

    [Function(nameof(search_code))]
    public Task<string> search_code(
        [McpToolTrigger("search_code", "Search code in one repository (GitHub code search syntax).")] ToolInvocationContext context,
        [McpToolProperty(Owner, "Repository owner.", true)] string owner,
        [McpToolProperty(Repo, "Repository name.", true)] string repo,
        [McpToolProperty("query", "Search terms, e.g. an error message, identifier or 'language:cs Foo'.", true)] string query,
        [McpToolProperty("per_page", "Results to return (1-50, default 20).", false)] int perPage) =>
        github.SearchCode(owner, repo, query, perPage, CancellationToken.None);

    [Function(nameof(get_issue))]
    public Task<string> get_issue(
        [McpToolTrigger("get_issue", "Get a single issue (title, body, labels, state).")] ToolInvocationContext context,
        [McpToolProperty(Owner, "Repository owner.", true)] string owner,
        [McpToolProperty(Repo, "Repository name.", true)] string repo,
        [McpToolProperty("issue_number", "Issue number.", true)] int issueNumber) =>
        github.GetIssue(owner, repo, issueNumber, CancellationToken.None);

    [Function(nameof(list_issues))]
    public Task<string> list_issues(
        [McpToolTrigger("list_issues", "List issues (and pull requests) of a repository.")] ToolInvocationContext context,
        [McpToolProperty(Owner, "Repository owner.", true)] string owner,
        [McpToolProperty(Repo, "Repository name.", true)] string repo,
        [McpToolProperty("state", "open, closed or all (default open).", false)] string? state,
        [McpToolProperty("per_page", "Results to return (1-50, default 20).", false)] int perPage) =>
        github.ListIssues(owner, repo, state is "closed" or "all" ? state : "open", perPage, CancellationToken.None);

    [Function(nameof(search_issues))]
    public Task<string> search_issues(
        [McpToolTrigger("search_issues", "Search issues and pull requests in one repository, e.g. to find duplicates.")] ToolInvocationContext context,
        [McpToolProperty(Owner, "Repository owner.", true)] string owner,
        [McpToolProperty(Repo, "Repository name.", true)] string repo,
        [McpToolProperty("query", "Search terms, e.g. 'timeout in:title is:issue'.", true)] string query,
        [McpToolProperty("per_page", "Results to return (1-50, default 20).", false)] int perPage) =>
        github.SearchIssues(owner, repo, query, perPage, CancellationToken.None);

    [Function(nameof(list_commits))]
    public Task<string> list_commits(
        [McpToolTrigger("list_commits", "List recent commits, optionally for a path or branch.")] ToolInvocationContext context,
        [McpToolProperty(Owner, "Repository owner.", true)] string owner,
        [McpToolProperty(Repo, "Repository name.", true)] string repo,
        [McpToolProperty("path", "Only commits touching this path.", false)] string? path,
        [McpToolProperty("sha", "Branch name or commit SHA to start from.", false)] string? sha,
        [McpToolProperty("per_page", "Results to return (1-50, default 20).", false)] int perPage) =>
        github.ListCommits(owner, repo, path, sha, perPage, CancellationToken.None);
}
