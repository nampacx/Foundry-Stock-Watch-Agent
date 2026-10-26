namespace CartApi;

public static class Pricing
{
    public static readonly Dictionary<string, Coupon> Coupons = new(StringComparer.OrdinalIgnoreCase)
    {
        ["SAVE10"] = new Coupon("SAVE10", 10),
        ["SAVE25"] = new Coupon("SAVE25", 25),
    };

    public static CartTotal Calculate(IEnumerable<CartItem> items, string? couponCode)
    {
        var subtotal = items.Sum(i => i.UnitPrice * i.Quantity);

        var discount = 0m;
        if (couponCode is not null && Coupons.TryGetValue(couponCode, out var coupon))
        {
            discount = Math.Round(subtotal * (coupon.PercentOff / 100), 2);
        }

        return new CartTotal(subtotal, discount, subtotal - discount);
    }
}
