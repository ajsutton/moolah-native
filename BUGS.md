# Known Bugs

## Analysis starting balance vs. daily deltas use different rules for investment accounts

In `CloudKitAnalysisRepository.fetchDailyBalances` / `computeDailyBalances`, the starting-balance phase (transactions with `date < after`) calls `applyTransaction` with `investmentTransfersOnly: false` — so every leg type on an investment account bumps the `investments` running total. The daily-delta phase (transactions with `date >= after`) calls it with `investmentTransfersOnly: true` — so only `.transfer` legs on investment accounts bump `investments`. This means the balance at the `after` boundary can jump when a non-transfer leg on an investment account flips sides: it counted on day `after - 1` but is ignored on day `after`. The rule was imported from the server's `selectBalance` vs `dailyProfitAndLoss` split; unclear whether the discontinuity is intentional. Decide once and apply consistently across both phases.

## Exchange-rate failure leaves sidebar totals permanently blank

`AccountStore.recomputeConvertedTotals` (`Features/Accounts/AccountStore.swift:168-184`) and the equivalent in `EarmarkStore` (`Features/Earmarks/EarmarkStore.swift:114-168`) wrap the full loop in one `Task { do … catch }`. If a single conversion throws (e.g. `ExchangeRateService` can't reach Frankfurter and has no cached fallback for the requested currency), the whole task aborts and `convertedCurrentTotal` / `convertedNetWorth` / `convertedTotalBalance` stay `nil`, so the sidebar rows render spinners forever. Should degrade per-position: catch inside the inner loop, skip or zero the failed position, surface a warning to the user, and keep the rest of the totals.

## `AccountStore.balance(for:)` hides non-primary positions

`AccountStore.balance(for:)` (`Features/Accounts/AccountStore.swift:102-103`) returns only the position whose instrument matches `account.instrument`. If an account accumulates a position in any other instrument (e.g. a cross-currency transfer into it, or a stray crypto position), that value is invisible in the per-account sidebar row and in `canDelete` (line 109), even though the converted sidebar totals still include it. Show the full position list, or at least surface a badge / warning when an account holds off-primary positions.

