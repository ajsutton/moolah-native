# Known Bugs

## CloudKit Daily Balances: Forecast start date uses unsorted transactions

**Location:** `Backends/CloudKit/Repositories/CloudKitAnalysisRepository.swift`

In both `fetchDailyBalances` and `computeDailyBalances`, the forecast start date is computed as `transactions.last?.date`. However, `transactions` is filtered but not sorted at that point — `.sorted(by:)` earlier in the method returns a new array without mutating the original. This means `transactions.last` yields an arbitrary transaction's date rather than the chronologically latest one.

**Impact:** The forecast start date may be incorrect, causing the forecast to begin from the wrong point. In practice, the effect depends on the order SwiftData returns records.

**Fix:** Use `transactions.sorted(by: { $0.date < $1.date }).last?.date` or store the sorted result and reuse it.
