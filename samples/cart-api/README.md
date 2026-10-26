# cart-api: sample app with a seeded bug

Tiny ASP.NET minimal API used as a target for the triage agent. It has **one deliberate bug**: coupons never apply a discount.

Run: `dotnet run`, then `POST /cart/total` with `{"items":[{"sku":"A1","name":"Mug","unitPrice":20,"quantity":2}],"coupon":"SAVE10"}`.
Tests: `dotnet test tests` (2 of 3 fail until the bug is fixed).

To exercise the agent, push this folder to the watched repo and open an issue like `sample-issue.json`. A good triage report should point at `Pricing.cs` (`coupon.PercentOff / 100` is integer division, so it is always 0).
