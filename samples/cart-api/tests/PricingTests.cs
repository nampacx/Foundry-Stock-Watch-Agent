using CartApi;
using Xunit;

public class PricingTests
{
    private static readonly CartItem[] Items =
    {
        new("A1", "Mug", 20.00m, 2),
        new("B2", "Shirt", 10.00m, 1),
    };

    [Fact]
    public void No_coupon_charges_full_price()
    {
        var total = Pricing.Calculate(Items, null);
        Assert.Equal(50.00m, total.Total);
    }

    [Fact]
    public void Save10_takes_ten_percent_off()
    {
        var total = Pricing.Calculate(Items, "SAVE10");
        Assert.Equal(5.00m, total.Discount);
        Assert.Equal(45.00m, total.Total);
    }

    [Fact]
    public void Save25_takes_twentyfive_percent_off()
    {
        var total = Pricing.Calculate(Items, "SAVE25");
        Assert.Equal(37.50m, total.Total);
    }
}
