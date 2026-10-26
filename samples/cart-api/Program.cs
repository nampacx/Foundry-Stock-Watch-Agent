using System.Globalization;
using CartApi;

// Usage: dotnet run -- --items "Mug:20:2,Shirt:10:1" [--coupon SAVE10]
//   items are name:unitPrice:quantity, comma separated
string? itemsArg = null, coupon = null;
for (var i = 0; i < args.Length - 1; i++)
{
    if (args[i] == "--items") itemsArg = args[i + 1];
    if (args[i] == "--coupon") coupon = args[i + 1];
}

if (string.IsNullOrWhiteSpace(itemsArg))
{
    Console.Error.WriteLine("Usage: dotnet run -- --items \"Mug:20:2,Shirt:10:1\" [--coupon SAVE10]");
    Console.Error.WriteLine("Coupons: " + string.Join(", ", Pricing.Coupons.Keys));
    return 1;
}

var items = itemsArg.Split(',').Select(part =>
{
    var f = part.Split(':');
    return new CartItem(f[0], f[0], decimal.Parse(f[1], CultureInfo.InvariantCulture), int.Parse(f[2]));
}).ToList();

var total = Pricing.Calculate(items, coupon);
Console.WriteLine($"Subtotal: {total.Subtotal:F2}");
Console.WriteLine($"Discount: {total.Discount:F2}");
Console.WriteLine($"Total:    {total.Total:F2}");
return 0;
