# CloudKit/SwiftData Performance Optimization

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reduce transaction list load from ~1s to <200ms and analysis view load from ~2s to <500ms for ~18,755 transactions, with headroom for 50K+.

**Architecture:** Three independent optimizations, ordered by impact:
1. Push filters/sort/pagination into SwiftData `FetchDescriptor` predicates (highest impact — hot path)
2. Precomputed account balances to eliminate N+1 queries
3. Stale-while-revalidate caching for analysis data

**Tech Stack:** Swift 6.2, SwiftUI, SwiftData, `#Predicate`, `@concurrent`

**Assumption:** By the time this plan is executed, `InMemoryBackend` will have been retired and all tests use `CloudKitBackend` with in-memory `ModelContainer`. Changes to CloudKit repositories are automatically covered by existing contract tests.

---

## Verification Approach

Before and after each optimization, measure with:

```swift
let start = CFAbsoluteTimeGetCurrent()
// ... operation ...
let elapsed = CFAbsoluteTimeGetCurrent() - start
logger.info("Operation took \(elapsed)s")
```

Or use Instruments > SwiftData template to trace fetch durations.

Key metrics:
- **Transaction list load (page 0, 50 items, account filter):** Baseline ~1s, target <200ms
- **Account list load (10 accounts):** Baseline ~500ms (20 queries), target <50ms (1 query)
- **Analysis load (12-month history):** Baseline ~2s, target <500ms first load, <50ms cached

---

## Optimization 1: Predicate Push-Down for Transaction Fetching

**Impact:** HIGH — this is the hot path. Every account view, every page load, every payee autofill triggers `fetch()`.

**Problem:** `CloudKitTransactionRepository.fetch()` loads ALL transactions for the profile (~18K+ records), converts all to domain objects via `toDomain()`, filters in memory, sorts in memory, then paginates in memory.

**Solution:** Build compound `#Predicate` expressions from `TransactionFilter` fields, use `SortDescriptor` for sorting, and use `fetchLimit`/`fetchOffset` for pagination. SwiftData pushes these down to SQLite.

### Risks & `#Predicate` Limitations

1. **Optional fields in compound predicates:** SwiftData `#Predicate` has known issues with optional comparisons in compound expressions. E.g., `$0.categoryId == someUUID` where `categoryId` is `UUID?` can crash at runtime. Workaround: use separate predicate construction branches, or filter optionals in memory if the SwiftData predicate fails.
2. **`Set.contains()` not supported:** `#Predicate` does not support `categoryIds.contains($0.categoryId)`. The `categoryIds` filter must remain as an in-memory post-filter.
3. **Case-insensitive string matching:** `#Predicate` supports `localizedStandardContains` but behavior may vary. The `payee` filter should remain as in-memory post-filter.
4. **`toAccountId` OR logic:** The filter `$0.accountId == id || $0.toAccountId == id` requires careful handling with optionals. May need two separate queries merged if `#Predicate` rejects the compound form.
5. **`fetchOffset` correctness:** When using in-memory post-filters (categoryIds, payee), `fetchOffset` on the FetchDescriptor is incorrect because some fetched rows get filtered out. For filters that cannot be pushed down, fall back to the current fetch-all approach for those specific filter combinations.
6. **`priorBalance` computation:** Currently computed by summing all transactions after the current page. With predicate push-down, we need a separate query: sum of amounts for all transactions matching the filter with date <= oldest-on-page (or use a COUNT-based offset approach).

### Task 1: Push `accountId` and `scheduled` filters into predicate

These are the two most common filters and the simplest to push down. They eliminate the most rows.

**Files:**
- Modify: `Backends/CloudKit/Repositories/CloudKitTransactionRepository.swift`

- [ ] **Step 1: Build predicate with accountId filter**

The `accountId` filter is special: it matches transactions where `accountId == id OR toAccountId == id` (transfers show in both accounts). Since `#Predicate` may struggle with optionals in OR expressions, try the compound form first. If it fails at runtime, fall back to two separate fetches merged.

Try:
```swift
let descriptor = FetchDescriptor<TransactionRecord>(
  predicate: #Predicate {
    $0.profileId == profileId && (
      $0.accountId == accountId || $0.toAccountId == accountId
    )
  }
)
```

If this crashes due to optional comparison, use two descriptors:
```swift
// Fetch where accountId matches
let sourceDescriptor = FetchDescriptor<TransactionRecord>(
  predicate: #Predicate { $0.profileId == profileId && $0.accountId == accountId }
)
// Fetch where toAccountId matches (transfers into this account)
let destDescriptor = FetchDescriptor<TransactionRecord>(
  predicate: #Predicate { $0.profileId == profileId && $0.toAccountId == accountId }
)
// Merge and deduplicate
```

- [ ] **Step 2: Push `scheduled` filter into predicate**

Scheduled transactions have `recurPeriod != nil`. Non-scheduled have `recurPeriod == nil`.

```swift
// For scheduled == true:
#Predicate { $0.profileId == profileId && $0.recurPeriod != nil }

// For scheduled == false:
#Predicate { $0.profileId == profileId && $0.recurPeriod == nil }
```

Test this carefully — `#Predicate` with `nil` comparisons on optional `String?` fields can be tricky.

- [ ] **Step 3: Push `dateRange` filter into predicate**

```swift
if let dateRange = filter.dateRange {
  let start = dateRange.lowerBound
  let end = dateRange.upperBound
  // Add to predicate: $0.date >= start && $0.date <= end
}
```

- [ ] **Step 4: Push `earmarkId` filter into predicate**

```swift
// $0.earmarkId == earmarkId (UUID? == UUID comparison)
```

- [ ] **Step 5: Combine pushed-down filters into a single predicate builder**

Create a helper method that builds the `#Predicate` based on which filter fields are set. Since `#Predicate` is a macro and cannot be conditionally composed at runtime, you need to enumerate the common filter combinations, or use a multi-stage approach:

**Recommended approach — staged filtering:**
```swift
func buildDescriptor(filter: TransactionFilter) -> FetchDescriptor<TransactionRecord> {
  // Stage 1: Always filter by profileId + push down what we can
  // Stage 2: Apply remaining filters in memory
  
  // Build the most selective predicate we can
  var descriptor: FetchDescriptor<TransactionRecord>
  
  if let accountId = filter.accountId {
    if let scheduled = filter.scheduled {
      if scheduled {
        descriptor = FetchDescriptor<TransactionRecord>(
          predicate: #Predicate { $0.profileId == profileId && $0.accountId == accountId && $0.recurPeriod != nil }
        )
      } else {
        descriptor = FetchDescriptor<TransactionRecord>(
          predicate: #Predicate { $0.profileId == profileId && $0.accountId == accountId && $0.recurPeriod == nil }
        )
      }
    } else {
      descriptor = FetchDescriptor<TransactionRecord>(
        predicate: #Predicate { $0.profileId == profileId && $0.accountId == accountId }
      )
    }
    // Note: this misses toAccountId matches — handle separately
  } else if let scheduled = filter.scheduled {
    // ... similar branching
  }
  
  return descriptor
}
```

This is verbose but safe. Each `#Predicate` is fully static and known at compile time.

**Alternative approach — `NSPredicate` escape hatch:**
If the combinatorial explosion becomes unmanageable, consider using `NSPredicate` with `NSCompoundPredicate` for dynamic composition, then converting. However, this loses type safety and may not work with all SwiftData features. Research before using.

- [ ] **Step 6: Handle the `toAccountId` OR for account filter**

For the account filter, we need transactions where `accountId == filterAccountId OR toAccountId == filterAccountId`. Options:

a. Two separate `FetchDescriptor` queries, merge results, deduplicate by `id`
b. Single predicate with OR (test if this works)
c. Fetch by `accountId` only at the predicate level, then do a second query for `toAccountId` transfers

Option (a) is safest. The `toAccountId` matches are typically few (only transfers), so the second query is fast.

- [ ] **Step 7: Add sort descriptor**

```swift
descriptor.sortBy = [
  SortDescriptor(\.date, order: .reverse),
  SortDescriptor(\.id)  // stable ordering tiebreaker
]
```

Note: The current code sorts by `id.uuidString` for tiebreaking, but SwiftData sorts UUID by binary representation, not string. Verify this matches the expected ordering in contract tests. If not, the tiebreaker may need to remain in-memory (which is fine since it only affects same-date rows).

- [ ] **Step 8: Add pagination via fetchLimit/fetchOffset**

```swift
descriptor.fetchLimit = pageSize
descriptor.fetchOffset = page * pageSize
```

**Critical caveat:** This only works when ALL filters are pushed into the predicate. If any filter remains as in-memory post-filter (categoryIds, payee), the offset/limit will be wrong. For those cases, skip fetchLimit/fetchOffset and paginate in memory as before.

Create a boolean `canPaginateInDatabase` that is true only when `filter.categoryIds == nil && filter.payee == nil`.

- [ ] **Step 9: Compute priorBalance with predicate push-down**

When database-level pagination is active, `priorBalance` requires a separate query:

```swift
// Fetch all matching transactions AFTER the current page (older transactions)
var priorDescriptor = FetchDescriptor<TransactionRecord>(
  predicate: /* same filter predicate */
)
priorDescriptor.sortBy = [SortDescriptor(\.date, order: .reverse)]
priorDescriptor.fetchOffset = (page + 1) * pageSize
// Sum amounts from these records
```

Or more efficiently, fetch ALL matching transactions' amounts (just the `amount` field) and sum the ones after the page boundary. SwiftData doesn't support partial field fetches, but since we only need the sum, we could:

a. Fetch all matching records (with predicate), sort, take the slice after the page, and sum `amount` directly on the records without calling `toDomain()`. This avoids the `toDomain()` overhead on non-page records.
b. Use two queries: one for the page (with limit/offset), one for the total sum.

Option (a) is simpler. For the prior balance, fetch all matching record amounts:

```swift
// For priorBalance: fetch records older than the current page
// Use the same predicate but without limit/offset
let allMatchingDescriptor = FetchDescriptor<TransactionRecord>(
  predicate: /* same predicate as above */,
  sortBy: [SortDescriptor(\.date, order: .reverse), SortDescriptor(\.id)]
)
let allRecords = try context.fetch(allMatchingDescriptor)
let end = min((page + 1) * pageSize, allRecords.count)
let priorCents = allRecords[end...].reduce(0) { $0 + $1.amount }
```

This still fetches all matching records but avoids `toDomain()` on most of them. The real win is that the predicate filters out non-matching accounts, reducing from 50K to ~5K records (typical account size).

- [ ] **Step 10: Build and verify**

Run: `just build-mac`
Expected: Compiles with no errors or warnings.

- [ ] **Step 11: Run contract tests**

Run: `just test`
Expected: All `TransactionRepositoryContractTests` pass. Pay special attention to:
- Pagination (page 0, page 1, empty page)
- Filter combinations (accountId + scheduled, dateRange, earmarkId)
- `priorBalance` correctness
- Sort order (date DESC, id tiebreaker)

- [ ] **Step 12: Measure performance improvement**

Add timing logs around `fetch()` and compare before/after with ~18K transactions.

Expected improvement: Fetching 50 transactions for a single account should drop from ~1s (fetch 18K, filter, sort, paginate) to ~100-200ms (fetch ~5K matching account, sort, paginate).

- [ ] **Step 13: Commit**

---

### Task 2: Push filters into `fetchPayeeSuggestions`

**Files:**
- Modify: `Backends/CloudKit/Repositories/CloudKitTransactionRepository.swift`

The current implementation fetches ALL transactions with a non-nil payee, then filters in memory. We can at least push the `payee != nil` into the predicate (already done) but the `hasPrefix` filter must stay in memory since `#Predicate` doesn't support `hasPrefix` reliably.

This is lower priority since it's already filtered to non-nil payees. Skip if the predicate push-down for `fetch()` is complex enough.

- [ ] **Step 1: Verify current predicate is efficient enough**

The existing predicate `$0.profileId == profileId && $0.payee != nil` is already reasonable. The main cost is iterating all payee-bearing transactions. With 18K transactions, maybe 15K have payees. This is acceptable for now.

- [ ] **Step 2: Consider adding a `payee` index to `TransactionRecord`**

In `project.yml` or via SwiftData `#Index` macro. This would speed up the `payee != nil` filter. Defer to a future optimization if the current performance is acceptable.

- [ ] **Step 3: Commit if any changes made**

---

## Optimization 2: Precomputed Account Balances

**Impact:** MEDIUM — eliminates 20 queries (2 per account) when loading the account list. Currently ~500ms, target <50ms.

**Problem:** `CloudKitAccountRepository.fetchAll()` calls `computeBalance(for:)` per account. Each call runs 2 SwiftData queries (source transactions, destination transactions). With 10 accounts = 20 queries.

**Solution:** Add a `cachedBalance` field to `AccountRecord`. Update it when transactions are created/updated/deleted. `fetchAll()` reads it directly.

### Risks

1. **Stale balances from CloudKit sync:** When another device syncs changes via CloudKit, the cached balance field could be stale. Need a recomputation trigger.
2. **Migration for existing data:** Existing `AccountRecord` rows have no `cachedBalance`. Need a one-time recomputation on first launch after upgrade.
3. **Atomicity:** When creating a transaction and updating the account balance, both must succeed. If the balance update fails, the balance becomes stale.
4. **Transfer transactions:** Update two accounts (source and destination). If one update fails, balances are inconsistent.
5. **Opening balance transactions:** Created inside `AccountRepository.create()`, so the balance update must also happen there.

### Task 3: Add `cachedBalance` field to `AccountRecord`

**Files:**
- Modify: `Backends/CloudKit/Models/AccountRecord.swift`

- [ ] **Step 1: Add the field**

```swift
@Model
final class AccountRecord {
  // ... existing fields ...
  var cachedBalance: Int?  // cents, nil = needs recomputation
}
```

Use `Int?` (optional) so that existing records have `nil`, which signals "needs recomputation."

- [ ] **Step 2: Update `toDomain` to use cachedBalance when available**

```swift
func toDomain(balance: MonetaryAmount? = nil, investmentValue: MonetaryAmount? = nil) -> Account {
  let resolvedBalance = balance ?? MonetaryAmount(
    cents: cachedBalance ?? 0,
    currency: Currency.from(code: currencyCode)
  )
  return Account(
    id: id,
    name: name,
    type: AccountType(rawValue: type) ?? .bank,
    balance: resolvedBalance,
    investmentValue: investmentValue,
    position: position,
    isHidden: isHidden
  )
}
```

- [ ] **Step 3: Build and verify**

Run: `just build-mac`

- [ ] **Step 4: Commit**

---

### Task 4: Recompute balances on first load and after sync

**Files:**
- Modify: `Backends/CloudKit/Repositories/CloudKitAccountRepository.swift`

- [ ] **Step 1: Update `fetchAll()` to use cached balances with fallback**

```swift
func fetchAll() async throws -> [Account] {
  let profileId = self.profileId
  let descriptor = FetchDescriptor<AccountRecord>(
    predicate: #Predicate { $0.profileId == profileId },
    sortBy: [SortDescriptor(\.position)]
  )
  return try await MainActor.run {
    let records = try context.fetch(descriptor)
    
    // Check if any records need balance recomputation
    let needsRecompute = records.contains { $0.cachedBalance == nil }
    if needsRecompute {
      try recomputeAllBalances(records: records)
    }
    
    return try records.map { record in
      let balance = MonetaryAmount(
        cents: record.cachedBalance ?? 0,
        currency: currency
      )
      let investmentValue = record.type == AccountType.investment.rawValue
        ? try latestInvestmentValue(for: record.id)
        : nil
      return record.toDomain(balance: balance, investmentValue: investmentValue)
    }
  }
}
```

- [ ] **Step 2: Add `recomputeAllBalances` method**

This is a batch operation that computes all account balances in a single pass through all transactions:

```swift
@MainActor
private func recomputeAllBalances(records: [AccountRecord]) throws {
  let profileId = self.profileId
  let txnDescriptor = FetchDescriptor<TransactionRecord>(
    predicate: #Predicate { $0.profileId == profileId && $0.recurPeriod == nil }
  )
  let allTransactions = try context.fetch(txnDescriptor)
  
  // Compute balances per account in a single pass
  var sourceBalances: [UUID: Int] = [:]
  var destBalances: [UUID: Int] = [:]
  
  for txn in allTransactions {
    if let accountId = txn.accountId {
      sourceBalances[accountId, default: 0] += txn.amount
    }
    if let toAccountId = txn.toAccountId {
      destBalances[toAccountId, default: 0] += txn.amount
    }
  }
  
  for record in records {
    let source = sourceBalances[record.id] ?? 0
    let dest = destBalances[record.id] ?? 0
    record.cachedBalance = source - dest
  }
  
  try context.save()
}
```

This is a one-time cost (~100ms for 18K transactions) that eliminates all per-account queries going forward.

- [ ] **Step 3: Update `computeBalance` to also write through to cache**

Keep the existing `computeBalance(for:)` method for single-account updates (used in `update()` and `delete()`), but have it also write the cached value:

```swift
@MainActor
private func computeBalance(for accountId: UUID) throws -> MonetaryAmount {
  // ... existing logic ...
  let balance = MonetaryAmount(cents: sourceSum - destSum, currency: currency)
  
  // Write through to cache
  let descriptor = FetchDescriptor<AccountRecord>(
    predicate: #Predicate { $0.id == accountId && $0.profileId == profileId }
  )
  if let record = try context.fetch(descriptor).first {
    record.cachedBalance = balance.cents
  }
  
  return balance
}
```

- [ ] **Step 4: Build and verify**

Run: `just build-mac`

- [ ] **Step 5: Run tests**

Run: `just test`
Expected: All `AccountRepositoryContractTests` pass.

- [ ] **Step 6: Commit**

---

### Task 5: Update transaction mutations to maintain cached balances

**Files:**
- Modify: `Backends/CloudKit/Repositories/CloudKitTransactionRepository.swift`

When a transaction is created, updated, or deleted, the affected account(s)' cached balances must be updated.

- [ ] **Step 1: Add a balance update helper**

```swift
@MainActor
private func updateAccountBalance(accountId: UUID, delta: Int) throws {
  let profileId = self.profileId
  let descriptor = FetchDescriptor<AccountRecord>(
    predicate: #Predicate { $0.id == accountId && $0.profileId == profileId }
  )
  if let record = try context.fetch(descriptor).first {
    record.cachedBalance = (record.cachedBalance ?? 0) + delta
  }
}
```

- [ ] **Step 2: Update `create()` to adjust balances**

After inserting the transaction record and before `context.save()`:

```swift
// Update cached balance for source account
if let accountId = transaction.accountId, transaction.recurPeriod == nil {
  try updateAccountBalance(accountId: accountId, delta: transaction.amount.cents)
}
// For transfers, update destination account
if let toAccountId = transaction.toAccountId, transaction.recurPeriod == nil {
  try updateAccountBalance(accountId: toAccountId, delta: -transaction.amount.cents)
}
```

- [ ] **Step 3: Update `delete()` to adjust balances**

Before deleting the record, read the transaction and reverse its balance effect:

```swift
// Reverse the balance effect
if record.recurPeriod == nil {
  if let accountId = record.accountId {
    try updateAccountBalance(accountId: accountId, delta: -record.amount)
  }
  if let toAccountId = record.toAccountId {
    try updateAccountBalance(accountId: toAccountId, delta: record.amount)
  }
}
```

- [ ] **Step 4: Update `update()` to adjust balances**

This is the trickiest case. The old transaction's effect must be reversed and the new transaction's effect applied. Read the old record before overwriting:

```swift
// Read old values before overwriting
let oldAmount = record.amount
let oldAccountId = record.accountId
let oldToAccountId = record.toAccountId
let oldRecurPeriod = record.recurPeriod

// ... apply updates to record ...

// Adjust balances: reverse old, apply new
if oldRecurPeriod == nil {
  if let accountId = oldAccountId {
    try updateAccountBalance(accountId: accountId, delta: -oldAmount)
  }
  if let toAccountId = oldToAccountId {
    try updateAccountBalance(accountId: toAccountId, delta: oldAmount)
  }
}
if transaction.recurPeriod == nil {
  if let accountId = transaction.accountId {
    try updateAccountBalance(accountId: accountId, delta: transaction.amount.cents)
  }
  if let toAccountId = transaction.toAccountId {
    try updateAccountBalance(accountId: toAccountId, delta: -transaction.amount.cents)
  }
}
```

- [ ] **Step 5: Build and verify**

Run: `just build-mac`

- [ ] **Step 6: Run full test suite**

Run: `just test`
Expected: All tests pass. Account balance contract tests are the key validation here.

- [ ] **Step 7: Test CloudKit sync scenario manually**

1. Make a change on device A
2. Wait for sync to device B
3. Verify account balances on device B are correct

If balances are stale after sync, add a `recomputeAllBalances` trigger when the app comes to foreground. This is the fallback safety net:

```swift
// In CloudKitAccountRepository, invalidate caches on foreground
func invalidateCachedBalances() async throws {
  try await MainActor.run {
    let descriptor = FetchDescriptor<AccountRecord>(
      predicate: #Predicate { $0.profileId == profileId }
    )
    let records = try context.fetch(descriptor)
    for record in records {
      record.cachedBalance = nil  // Force recomputation on next fetchAll()
    }
    try context.save()
  }
}
```

Wire this to `scenePhase == .active` in the relevant view. The recomputation is fast (~100ms) and only happens on foreground.

- [ ] **Step 8: Commit**

---

## Optimization 3: Stale-While-Revalidate for Analysis

**Impact:** MEDIUM — eliminates perceived latency on repeated analysis views. First load still takes ~500ms (after Optimization 1 reduces the data set), but subsequent navigations appear instant.

**Problem:** Every time the user navigates to the Analysis tab, switches back from editing transactions, or brings the app to foreground, `loadAll()` runs from scratch. With 18K transactions this takes ~2s (or ~500ms after Optimization 1).

**Solution:** Cache the last `AnalysisData` result in `AnalysisStore`. On subsequent loads, immediately display cached data, then recompute in background and animate the diff.

### Task 6: Add stale-while-revalidate to AnalysisStore

**Files:**
- Modify: `Features/Analysis/AnalysisStore.swift`

- [ ] **Step 1: Add cached state**

```swift
@Observable
@MainActor
final class AnalysisStore {
  // ... existing published state ...
  
  /// Cached analysis parameters — used to detect if cache is still valid for current filters
  private var cachedHistoryMonths: Int?
  private var cachedForecastMonths: Int?
  private var hasCachedData: Bool {
    cachedHistoryMonths != nil && !dailyBalances.isEmpty
  }
}
```

- [ ] **Step 2: Modify `loadAll()` to show stale data during recomputation**

```swift
func loadAll() async {
  monthEnd = Calendar.current.component(.day, from: Date())
  error = nil
  
  // If filters changed, clear cache — stale data with wrong filters is confusing
  let filtersChanged = historyMonths != cachedHistoryMonths || forecastMonths != cachedForecastMonths
  
  // Show loading only if we have no cached data or filters changed
  if !hasCachedData || filtersChanged {
    isLoading = true
    if filtersChanged {
      // Clear stale data for different filter settings
      dailyBalances = []
      expenseBreakdown = []
      incomeAndExpense = []
    }
  }
  
  do {
    let after = afterDate(monthsAgo: historyMonths)
    let forecastUntil = forecastDate(monthsAhead: forecastMonths)
    
    let data = try await repository.loadAll(
      historyAfter: after,
      forecastUntil: forecastUntil,
      monthEnd: monthEnd
    )
    
    dailyBalances = Self.extrapolateBalances(
      data.dailyBalances, today: Date(), forecastUntil: forecastUntil
    )
    expenseBreakdown = data.expenseBreakdown
    incomeAndExpense = data.incomeAndExpense.sorted { $0.month > $1.month }
    
    cachedHistoryMonths = historyMonths
    cachedForecastMonths = forecastMonths
  } catch {
    logger.error("Failed to load analysis data: \(error)")
    self.error = error
  }
  
  isLoading = false
}
```

- [ ] **Step 3: Update `AnalysisView` loading indicator**

The view already handles this correctly:
```swift
if store.isLoading && store.dailyBalances.isEmpty {
  ProgressView("Loading analysis...")
}
```

When cached data exists, `dailyBalances` is non-empty, so the progress view is skipped and the cached charts are shown while recomputation happens in background. SwiftUI animates changes when fresh data arrives.

No view changes needed.

- [ ] **Step 4: Build and verify**

Run: `just build-mac`

- [ ] **Step 5: Run tests**

Run: `just test`
Expected: All AnalysisStore tests pass.

- [ ] **Step 6: Manual verification**

1. Open Analysis tab (first load shows spinner)
2. Switch to Transactions tab, make a change
3. Switch back to Analysis tab — charts should appear immediately with stale data, then update
4. Change history filter — should show spinner briefly since filter changed
5. Bring app to foreground — charts show immediately, refresh in background

- [ ] **Step 7: Commit**

---

## Optimization 4 (Future/Optional): SwiftData Indexes

If performance is still insufficient after Optimizations 1-3, add SwiftData indexes to `TransactionRecord`:

```swift
@Model
final class TransactionRecord {
  #Index<TransactionRecord>([\.profileId, \.accountId, \.date])
  #Index<TransactionRecord>([\.profileId, \.recurPeriod])
  #Index<TransactionRecord>([\.profileId, \.toAccountId])
  // ...
}
```

This requires SwiftData schema migration and should be measured before adding. The predicate push-down in Optimization 1 may be sufficient without explicit indexes since SwiftData/SQLite creates some indexes automatically.

---

## Summary of Expected Improvements

| Operation | Before | After Opt 1 | After Opt 2 | After Opt 3 |
|-----------|--------|-------------|-------------|-------------|
| Transaction list (50 items, account filter) | ~1s | ~200ms | ~200ms | ~200ms |
| Account list (10 accounts) | ~500ms | ~500ms | ~50ms | ~50ms |
| Analysis (first load, 12mo) | ~2s | ~1s | ~1s | ~1s (spinner) |
| Analysis (subsequent load) | ~2s | ~1s | ~1s | <50ms (cached) |

Total user-perceived improvement: Navigation feels instant for all common operations.
