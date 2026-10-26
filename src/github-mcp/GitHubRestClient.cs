using System.Net;
using System.Text.Json;

namespace GitHubMcp;

/// <summary>
/// Thin read-only wrapper over the GitHub REST API. Every method returns compact JSON text that is
/// suitable as an MCP tool result, and turns HTTP errors into a short message instead of throwing,
/// so the model sees "404 Not Found" rather than an opaque tool failure.
/// </summary>
public sealed class GitHubRestClient(HttpClient http)
{
    private const int MaxFileChars = 60_000;

    // owner/repo segments are interpolated into URLs, so only accept GitHub's allowed characters.
    private static bool ValidName(string s) =>
        !string.IsNullOrEmpty(s) && s.Length <= 100 && s.All(c => char.IsAsciiLetterOrDigit(c) || c is '-' or '_' or '.');

    private static string Seg(string path) =>
        string.Join('/', path.Trim('/').Split('/', StringSplitOptions.RemoveEmptyEntries).Select(Uri.EscapeDataString));

    public async Task<string> GetAsync(string url, CancellationToken ct = default)
    {
        using HttpResponseMessage resp = await http.GetAsync(url, ct);
        string body = await resp.Content.ReadAsStringAsync(ct);
        if (resp.IsSuccessStatusCode) return body;

        string detail = resp.StatusCode == HttpStatusCode.Forbidden && resp.Headers.TryGetValues("x-ratelimit-remaining", out var rem) && rem.First() == "0"
            ? "GitHub rate limit exhausted"
            : body.Length > 300 ? body[..300] : body;
        return $"GitHub API error {(int)resp.StatusCode} {resp.ReasonPhrase}: {detail}";
    }

    public async Task<string> GetIssue(string owner, string repo, int number, CancellationToken ct) =>
        await (Guard(owner, repo) ?? Fetch($"repos/{owner}/{repo}/issues/{number}", e => Issue(e, MaxSingleIssueBodyChars), ct));

    public Task<string> ListIssues(string owner, string repo, string state, int perPage, CancellationToken ct) =>
        Guard(owner, repo) ?? Fetch($"repos/{owner}/{repo}/issues?state={Uri.EscapeDataString(state)}&per_page={Clamp(perPage)}", e => Issue(e, MaxIssueBodyChars), ct);

    public Task<string> SearchCode(string owner, string repo, string query, int perPage, CancellationToken ct) =>
        Guard(owner, repo, query) ?? Fetch($"search/code?q={Uri.EscapeDataString($"{query} repo:{owner}/{repo}")}&per_page={Clamp(perPage)}", CodeHit, ct);

    public Task<string> SearchIssues(string owner, string repo, string query, int perPage, CancellationToken ct) =>
        Guard(owner, repo, query) ?? Fetch($"search/issues?q={Uri.EscapeDataString($"{query} repo:{owner}/{repo}")}&per_page={Clamp(perPage)}", e => Issue(e, MaxIssueBodyChars), ct);

    public Task<string> ListCommits(string owner, string repo, string? path, string? sha, int perPage, CancellationToken ct)
    {
        if (Guard(owner, repo) is { } bad) return bad;
        string url = $"repos/{owner}/{repo}/commits?per_page={Clamp(perPage)}";
        if (!string.IsNullOrWhiteSpace(path)) url += $"&path={Uri.EscapeDataString(path)}";
        if (!string.IsNullOrWhiteSpace(sha)) url += $"&sha={Uri.EscapeDataString(sha)}";
        return Fetch(url, Commit, ct);
    }

    private async Task<string> Fetch(string url, Func<JsonElement, object> map, CancellationToken ct) =>
        Project(await GetAsync(url, ct), map);

    /// <summary>File → decoded text (truncated); directory → compact listing of entries.</summary>
    public async Task<string> GetFileContents(string owner, string repo, string path, string? @ref, CancellationToken ct)
    {
        if (Guard(owner, repo) is { } bad) return await bad;
        string url = $"repos/{owner}/{repo}/contents/{Seg(path)}";
        if (!string.IsNullOrWhiteSpace(@ref)) url += $"?ref={Uri.EscapeDataString(@ref)}";

        string body = await GetAsync(url, ct);
        if (body.StartsWith("GitHub API error", StringComparison.Ordinal)) return body;

        using JsonDocument doc = JsonDocument.Parse(body);
        JsonElement root = doc.RootElement;

        if (root.ValueKind == JsonValueKind.Array)
        {
            var entries = root.EnumerateArray().Select(e => new
            {
                name = e.GetProperty("name").GetString(),
                path = e.GetProperty("path").GetString(),
                type = e.GetProperty("type").GetString(),
                size = e.GetProperty("size").GetInt64(),
            });
            return JsonSerializer.Serialize(new { type = "dir", path, entries });
        }

        if (root.TryGetProperty("content", out JsonElement content) && root.GetProperty("encoding").GetString() == "base64")
        {
            string text = System.Text.Encoding.UTF8.GetString(Convert.FromBase64String(content.GetString()!.Replace("\n", "")));
            bool truncated = text.Length > MaxFileChars;
            return JsonSerializer.Serialize(new
            {
                type = "file",
                path,
                sha = root.GetProperty("sha").GetString(),
                truncated,
                content = truncated ? text[..MaxFileChars] : text,
            });
        }

        return $"GitHub API error: '{path}' is not a regular file or directory (symlink/submodule?).";
    }

    private static int Clamp(int perPage) => Math.Clamp(perPage <= 0 ? 20 : perPage, 1, 50);

    // Optional server-side scope ("owner/repo", app setting ALLOWED_REPO). The agent prompt already says to stay
    // on one repository, but issue text is untrusted, so the server enforces it too.
    private static readonly string? AllowedRepo = Environment.GetEnvironmentVariable("ALLOWED_REPO") is { Length: > 0 } r ? r.Trim() : null;

    private static readonly string[] ScopeQualifiers = ["repo:", "org:", "user:", "owner:"];

    private static Task<string>? Guard(string owner, string repo, string? query = null)
    {
        if (!ValidName(owner) || !ValidName(repo)) return Task.FromResult("Invalid owner or repository name.");
        if (AllowedRepo is not null)
        {
            if (!string.Equals($"{owner}/{repo}", AllowedRepo, StringComparison.OrdinalIgnoreCase))
                return Task.FromResult($"Access is limited to {AllowedRepo}.");
            if (query is not null && ScopeQualifiers.Any(q => query.Contains(q, StringComparison.OrdinalIgnoreCase)))
                return Task.FromResult("Search qualifiers repo:/org:/user: are not allowed; the search is already scoped to the repository.");
        }
        return null;
    }

    // --- Compact projections: the model needs titles, locations and short bodies, not GitHub's full JSON. ---
    private const int MaxIssueBodyChars = 1_500;
    private const int MaxSingleIssueBodyChars = 8_000;
    private const int MaxOutputChars = 40_000;

    private static string Trunc(string? s, int max) =>
        s is null ? "" : s.Length <= max ? s : s[..max] + "…[truncated]";

    private static string? Str(JsonElement e, string name) =>
        e.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;

    private static object Issue(JsonElement e, int bodyMax) => new
    {
        number = e.GetProperty("number").GetInt32(),
        title = Str(e, "title"),
        state = Str(e, "state"),
        is_pull_request = e.TryGetProperty("pull_request", out _),
        author = e.TryGetProperty("user", out var u) && u.ValueKind == JsonValueKind.Object ? Str(u, "login") : null,
        labels = e.TryGetProperty("labels", out var l) && l.ValueKind == JsonValueKind.Array
            ? l.EnumerateArray().Select(x => x.ValueKind == JsonValueKind.Object ? Str(x, "name") : x.GetString()).ToArray()
            : [],
        created_at = Str(e, "created_at"),
        updated_at = Str(e, "updated_at"),
        url = Str(e, "html_url"),
        body = Trunc(Str(e, "body"), bodyMax),
    };

    private static object CodeHit(JsonElement e) => new { name = Str(e, "name"), path = Str(e, "path"), url = Str(e, "html_url") };

    private static object Commit(JsonElement e)
    {
        string message = e.TryGetProperty("commit", out var c) ? Str(c, "message") ?? "" : "";
        int nl = message.IndexOf('\n');
        return new
        {
            sha = (Str(e, "sha") ?? "")[..Math.Min(7, (Str(e, "sha") ?? "").Length)],
            message = Trunc(nl >= 0 ? message[..nl] : message, 200),
            author = c.ValueKind == JsonValueKind.Object && c.TryGetProperty("author", out var a) ? Str(a, "name") : null,
            date = c.ValueKind == JsonValueKind.Object && c.TryGetProperty("author", out var a2) ? Str(a2, "date") : null,
            url = Str(e, "html_url"),
        };
    }

    /// <summary>Maps a REST list (or a search result's "items") to compact JSON; errors pass through untouched.</summary>
    private static string Project(string body, Func<JsonElement, object> map)
    {
        if (body.StartsWith("GitHub API error", StringComparison.Ordinal)) return body;
        using JsonDocument doc = JsonDocument.Parse(body);
        JsonElement root = doc.RootElement;
        int? total = null;
        if (root.ValueKind == JsonValueKind.Object && root.TryGetProperty("items", out JsonElement items))
        {
            total = root.TryGetProperty("total_count", out var t) ? t.GetInt32() : null;
            root = items;
        }
        object[] mapped = root.ValueKind == JsonValueKind.Array ? root.EnumerateArray().Select(map).ToArray() : [map(root)];
        string json = JsonSerializer.Serialize(total is null ? (object)mapped : new { total_count = total, items = mapped });
        return Trunc(json, MaxOutputChars);
    }
}
