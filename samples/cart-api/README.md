# cart-api: sample CLI with a seeded bug

Tiny .NET console app used as a target for the triage agent. It has **one deliberate bug**: coupons never apply a discount.

Run: `dotnet run -- --items "Mug:20:2,Shirt:10:1" --coupon SAVE10` (expected total 45.00, actual 50.00).
Tests: `dotnet test tests` (2 of 3 fail until the bug is fixed).

To exercise the agent, push this folder to the watched repo and open an issue like `sample-issue.json`. A good triage report should point at `Pricing.cs` (`coupon.PercentOff / 100` is integer division, so it is always 0).
