# Performance Optimisations Lost During Rebase

The `feature/multi-instrument` branch was rebased onto `main` on 2026-04-14. Several performance optimisations from the `perf/sync-and-ui-optimizations` merge conflicted with the multi-instrument rewrite and were resolved by taking the branch's version. This document captures what was lost so it can be re-applied to the new leg-based code.

## 1. Calendar Caching in Analysis Loops

**Original commit:** `9d2e6ea` — cache Calendar calls in analysis loops  
**File:** `CloudKitAnalysisRepository.swift`  
**Methods:** All six analysis methods (computeDailyBalances, fetchDailyBalances, computeExpenseBreakdown, fetchExpenseBreakdown, computeIncomeAndExpense, fetchIncomeAndExpense)

Main caches the last `financialMonth` result and reuses it when consecutive transactions fall on the same day, avoiding repeated `Calendar.current` calls:

```swift
var lastFinancialDate: Date?
var lastFinancialMonth: String = ""

for txn in transactions {
    let month: String
    if let last = lastFinancialDate, Calendar.current.isDate(txn.date, inSameDayAs: last) {
        month = lastFinancialMonth
    } else {
        month = Self.financialMonth(for: txn.date, monthEnd: monthEnd)
        lastFinancialMonth = month
        lastFinancialDate = txn.date
    }
    // ...
}
```

The branch iterates legs instead of transactions, but the same caching pattern applies — consecutive legs from the same transaction share a date.

## 2. Algebraic Fast Path for Prior Balance (10x)

**Original commit:** `000b3c8` — 10x faster prior balance loading via algebraic fast path  
**File:** `CloudKitTransactionRepository.swift` — `fetch()` method

For the common case (page 0, simple accountId filter, cached balance available), main computes prior balance algebraically instead of loading all records:

```
priorBalance = cachedBalance - sum(page records adjusted for account direction)
```

Benchmark: 0.451s → 0.045s.

The branch doesn't have `cachedBalance` on accounts (yet). Re-applying this requires:
- Adding a `cachedBalance` field to the account model (or an instrument-aware equivalent).
- Computing the fast path from leg quantities for the filtered account.

## 3. Predicate Push-Down with Skip Tracking

**Original commit:** `5e42932` — skip redundant post-filters when predicate already pushed down  
**File:** `CloudKitTransactionRepository.swift`

Main tracks which filters were pushed into SwiftData predicates via a `DescriptorResult` struct:

```swift
struct DescriptorResult {
    let descriptor: FetchDescriptor<TransactionRecord>
    let pushedScheduled: Bool
    let pushedDateRange: Bool
    let pushedEarmarkId: Bool
}
```

Post-filter stage skips redundant array passes when the predicate already handled the filter. Main also has extensive per-combination predicate branches (accountId × scheduled × dateRange × earmarkId) with primary/toAccount split.

The branch queries legs for accountId filtering instead, so the predicate structure is fundamentally different. The skip-tracking pattern still applies — the branch could track whether scheduled/dateRange were pushed down and skip their post-filters.

## 4. Native UUID Comparable in Sort

**Original commit:** `ec0f040` — use native UUID Comparable instead of uuidString in sort  
**File:** `CloudKitTransactionRepository.swift`

Trivial fix: `a.id < b.id` instead of `a.id.uuidString < b.id.uuidString`. Eliminates two String allocations per comparison. Should be re-applied wherever transaction/leg sorts use UUID tie-breaking.

## 5. Batch Record Lookups with IN Predicates

**Original commit:** `4bc67db` — batch-fetch buildBatchRecordLookup with IN predicates  
**File:** `ProfileSyncEngine.swift`

Main batches the `buildBatchRecordLookup` per record type using IN-predicate fetches instead of per-UUID loops. Reduces query count from up to N×6 to exactly 6 for a batch of N UUIDs.

The branch adds InstrumentRecord and TransactionLegRecord as new types, increasing the number of record types. The batch pattern needs to cover these additional types.

## 6. Batch Deletions via IN Predicate

**Original commit:** `a30abfd` — batch deletions in applyBatchDeletions via IN predicate  
**File:** `ProfileSyncEngine.swift`

Main groups deletions by record type and does one IN-predicate fetch per type:

```swift
for (recordType, ids) in grouped {
    case TransactionRecord.recordType:
        let records = try? context.fetch(
            FetchDescriptor<TransactionRecord>(predicate: #Predicate { ids.contains($0.id) }))
        for record in records { context.delete(record) }
    // ...
}
```

The branch uses per-record deletion (`$0.id == recordId`). Re-applying this means adding IN-predicate batch deletion for all types including the new InstrumentRecord and TransactionLegRecord.

## 7. Targeted Balance Invalidation on Sync

**Original commit:** `1f6307e` — targeted balance invalidation — only fetch affected accounts  
**File:** `ProfileSyncEngine.swift` — `applyRemoteChanges()`

When remote transaction changes arrive, main extracts affected account IDs from the CKRecords and invalidates only those accounts' cached balances:

```swift
let affectedAccountIds = Self.extractAffectedAccountIds(saved: saved, deleted: deleted)
Self.invalidateCachedBalances(accountIds: affectedAccountIds, context: context)
```

Falls back to invalidating all accounts when deletions are present (since deleted CKRecords don't carry content).

This depends on cached balances existing (see item 2). Once cached balances are added to the multi-instrument model, this targeted invalidation should be re-applied, reading account IDs from transaction leg CKRecords instead of the old accountId/toAccountId fields.

## 8. Generic queueIDs Helper for Initial Upload

**Original commit:** `12fbb4a` — deduplicate queueAllExistingRecords with generic closure  
**File:** `ProfileSyncEngine.swift` — `queueAllExistingRecords()`

Main extracts a generic helper that creates a fresh ModelContext per type to reduce peak memory:

```swift
func queueIDs<T: PersistentModel>(_ type: T.Type, extract: (T) -> UUID) {
    let context = ModelContext(modelContainer)
    if let records = try? context.fetch(FetchDescriptor<T>()) {
        for r in records {
            queuePendingSave(for: extract(r))
            total += 1
        }
    }
}
```

The branch's version creates one context and iterates all types inline. Re-applying the generic helper would also need to handle InstrumentRecord (which uses String IDs via `queueSave(recordName:)` rather than UUID).

## Priority

Rough impact order for re-application:
1. **Algebraic fast path** (item 2) — 10x improvement on the hottest path, but requires cached balance infrastructure
2. **Batch sync operations** (items 5, 6) — 3.5x deletion speedup, major query reduction
3. **Calendar caching** (item 1) — straightforward pattern, applies directly to leg iteration
4. **UUID sort fix** (item 4) — trivial to re-apply
5. **Predicate push-down** (item 3) — significant but the leg-based query model may need a different approach
6. **Targeted invalidation** (item 7) and **generic queueIDs** (item 8) — depend on items 2 and 5 respectively
