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

    public Task<string> GetIssue(string owner, string repo, int number, CancellationToken ct) =>
        Guard(owner, repo) ?? GetAsync($"repos/{owner}/{repo}/issues/{number}", ct);

    public Task<string> ListIssues(string owner, string repo, string state, int perPage, CancellationToken ct) =>
        Guard(owner, repo) ?? GetAsync($"repos/{owner}/{repo}/issues?state={Uri.EscapeDataString(state)}&per_page={Clamp(perPage)}", ct);

    public Task<string> SearchCode(string owner, string repo, string query, int perPage, CancellationToken ct) =>
        Guard(owner, repo) ?? GetAsync($"search/code?q={Uri.EscapeDataString($"{query} repo:{owner}/{repo}")}&per_page={Clamp(perPage)}", ct);

    public Task<string> SearchIssues(string owner, string repo, string query, int perPage, CancellationToken ct) =>
        Guard(owner, repo) ?? GetAsync($"search/issues?q={Uri.EscapeDataString($"{query} repo:{owner}/{repo}")}&per_page={Clamp(perPage)}", ct);

    public Task<string> ListCommits(string owner, string repo, string? path, string? sha, int perPage, CancellationToken ct)
    {
        if (Guard(owner, repo) is { } bad) return bad;
        string url = $"repos/{owner}/{repo}/commits?per_page={Clamp(perPage)}";
        if (!string.IsNullOrWhiteSpace(path)) url += $"&path={Uri.EscapeDataString(path)}";
        if (!string.IsNullOrWhiteSpace(sha)) url += $"&sha={Uri.EscapeDataString(sha)}";
        return GetAsync(url, ct);
    }

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

    private static Task<string>? Guard(string owner, string repo) =>
        ValidName(owner) && ValidName(repo) ? null : Task.FromResult("Invalid owner or repository name.");
}
