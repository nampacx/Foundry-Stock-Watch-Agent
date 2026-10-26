using System.Text.RegularExpressions;
using Azure.Data.Tables;

namespace StockWatchApi;

internal static class Config
{
    public static string Required(string name) =>
        Optional(name, null) ?? throw new InvalidOperationException($"{name} is not set.");

    public static string? Optional(string name, string? fallback)
    {
        string? value = Environment.GetEnvironmentVariable(name);
        return string.IsNullOrWhiteSpace(value) ? fallback : value;
    }
}

public sealed record Report(
    string Ticker, string Name, string? Exchange, DateTimeOffset RunUtc, DateTimeOffset WindowStartUtc,
    string Sentiment, bool Failed, string Markdown);

public sealed record CompanySummary(string Ticker, string Name, string? Exchange, Report? Latest);

/// <summary>
/// Reads the table written by the agent: reports have PartitionKey = ticker and RowKey = inverted run time (newest first);
/// the watchlist table supplies the list of companies.
/// </summary>
internal sealed partial class ReportReader(TableClient watchlist, TableClient reports, string watchlistPartition)
{
    // Same key sanitising as the agent's ReportStore.KeyFor.
    public static string KeyFor(string ticker) => KeyChars().Replace(ticker.Trim(), "_");

    public async Task<IReadOnlyList<CompanySummary>> GetCompaniesAsync(CancellationToken ct)
    {
        var companies = new List<(string Ticker, string Name, string? Exchange)>();
        await foreach (TableEntity e in watchlist.QueryAsync<TableEntity>(x => x.PartitionKey == watchlistPartition, cancellationToken: ct))
        {
            if (e.TryGetValue("Active", out object? active) && active is false)
                continue;
            companies.Add((e.RowKey, e.GetString("Name") is { Length: > 0 } n ? n : e.RowKey, e.GetString("Exchange")));
        }

        CompanySummary[] result = await Task.WhenAll(companies.Select(async c =>
        {
            IReadOnlyList<Report> latest = await GetReportsAsync(c.Ticker, 1, ct);
            return new CompanySummary(c.Ticker, c.Name, c.Exchange, latest.FirstOrDefault());
        }));
        return result.OrderBy(c => c.Ticker, StringComparer.OrdinalIgnoreCase).ToList();
    }

    public async Task<IReadOnlyList<Report>> GetReportsAsync(string ticker, int limit, CancellationToken ct)
    {
        string key = KeyFor(ticker);
        var list = new List<Report>();
        // RowKey is the inverted run time, so the natural order is newest first.
        await foreach (TableEntity e in reports.QueryAsync<TableEntity>(x => x.PartitionKey == key, maxPerPage: Math.Min(limit, 1000), cancellationToken: ct))
        {
            list.Add(new Report(
                e.GetString("Ticker") ?? e.PartitionKey,
                e.GetString("Name") ?? e.PartitionKey,
                e.GetString("Exchange"),
                e.GetDateTimeOffset("RunUtc") ?? default,
                e.GetDateTimeOffset("WindowStartUtc") ?? default,
                e.GetString("Sentiment") ?? "none",
                e.GetBoolean("Failed") ?? false,
                e.GetString("Markdown") ?? ""));
            if (list.Count >= limit) break;
        }
        return list;
    }

    [GeneratedRegex(@"[/\#?\u0000-\u001F\u007F-\u009F]")]
    private static partial Regex KeyChars();
}
