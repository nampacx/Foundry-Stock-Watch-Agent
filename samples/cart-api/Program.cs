using CartApi;

var builder = WebApplication.CreateBuilder(args);
var app = builder.Build();

// POST /cart/total  { "items": [...], "coupon": "SAVE10" }
app.MapPost("/cart/total", (CartRequest request) =>
    Results.Ok(Pricing.Calculate(request.Items, request.Coupon)));

app.MapGet("/coupons", () => Pricing.Coupons.Values);

app.Run();

public record CartRequest(List<CartItem> Items, string? Coupon);
