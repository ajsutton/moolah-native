# Known Bugs

## Analysis starting balance vs. daily deltas use different rules for investment accounts

In `CloudKitAnalysisRepository.fetchDailyBalances` / `computeDailyBalances`, the starting-balance phase (transactions with `date < after`) calls `applyTransaction` with `investmentTransfersOnly: false` — so every leg type on an investment account bumps the `investments` running total. The daily-delta phase (transactions with `date >= after`) calls it with `investmentTransfersOnly: true` — so only `.transfer` legs on investment accounts bump `investments`. This means the balance at the `after` boundary can jump when a non-transfer leg on an investment account flips sides: it counted on day `after - 1` but is ignored on day `after`. The rule was imported from the server's `selectBalance` vs `dailyProfitAndLoss` split; unclear whether the discontinuity is intentional. Decide once and apply consistently across both phases.

