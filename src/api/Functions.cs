using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Azure.Functions.Worker;

namespace StockWatchApi;

// Anonymous at the function level on purpose: the Static Web App is the only way in. Linking it as the backend puts App
// Service authentication in front of this app, so callers cannot bypass the Static Web App.
internal sealed class Functions(ReportReader reader)
{
    /// <summary>GET /api/companies: every active watchlist company with its latest report.</summary>
    [Function("GetCompanies")]
    public async Task<IActionResult> GetCompanies(
        [HttpTrigger(AuthorizationLevel.Anonymous, "get", Route = "companies")] HttpRequest req, CancellationToken ct) =>
        new OkObjectResult(await reader.GetCompaniesAsync(ct));

    /// <summary>GET /api/companies/{ticker}/reports?limit=30: report history of one company, newest first.</summary>
    [Function("GetCompanyReports")]
    public async Task<IActionResult> GetCompanyReports(
        [HttpTrigger(AuthorizationLevel.Anonymous, "get", Route = "companies/{ticker}/reports")] HttpRequest req,
        string ticker, CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(ticker) || ticker.Length > 32)
            return new BadRequestObjectResult("Invalid ticker.");
        int limit = int.TryParse(req.Query["limit"], out int l) ? Math.Clamp(l, 1, 100) : 30;
        return new OkObjectResult(await reader.GetReportsAsync(ticker, limit, ct));
    }
}
