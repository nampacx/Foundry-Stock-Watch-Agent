namespace CartApi;

public record CartItem(string Sku, string Name, decimal UnitPrice, int Quantity);

public record Coupon(string Code, int PercentOff);

public record CartTotal(decimal Subtotal, decimal Discount, decimal Total);
