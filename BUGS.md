# Known Bugs

## Exchange-rate failure leaves sidebar totals permanently blank

`AccountStore.recomputeConvertedTotals` (`Features/Accounts/AccountStore.swift:168-184`) and the equivalent in `EarmarkStore` (`Features/Earmarks/EarmarkStore.swift:114-168`) wrap the full loop in one `Task { do … catch }`. If a single conversion throws (e.g. `ExchangeRateService` can't reach Frankfurter and has no cached fallback for the requested currency), the whole task aborts and `convertedCurrentTotal` / `convertedNetWorth` / `convertedTotalBalance` stay `nil`, so the sidebar rows render spinners forever. Should degrade per-position: catch inside the inner loop, skip or zero the failed position, surface a warning to the user, and keep the rest of the totals.

