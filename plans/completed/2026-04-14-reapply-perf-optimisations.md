# Reapply Lost Performance Optimisations

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Re-apply the performance optimisations from `perf/sync-and-ui-optimizations` that were lost during the multi-instrument rebase.

**Architecture:** Direct port of optimisations from `main` to the leg-based multi-instrument code. Calendar caching, UUID sort, batch sync operations, generic helper, and debounced system fields writes. Two optimisations (algebraic fast path, targeted balance invalidation) are deferred because they require `cachedBalance` infrastructure that doesn't exist in the multi-instrument model yet.

**Tech Stack:** Swift, SwiftData, CKSyncEngine, os_signpost

---

## Scope

### Applying now (no new infrastructure needed)
1. Calendar caching in analysis loops
2. UUID sort fix
3. Batch record lookups with IN predicates
4. Batch deletions via IN predicate
5. Generic queueIDs helper
6. Debounced system fields cache writes
7. Skip redundant scheduled/dateRange post-filters

### Deferred (needs cachedBalance on AccountRecord)
- Algebraic fast path for prior balance (10x improvement)
- Targeted balance invalidation on sync

---

### Task 1: Calendar Caching in Analysis Loops

**Files:**
- Modify: `Backends/CloudKit/Repositories/CloudKitAnalysisRepository.swift`

The `financialMonth(for:monthEnd:)` call involves Calendar component extraction and conditional date arithmetic. When transactions are sorted by date, consecutive transactions often share the same day. Cache the last result and reuse it when dates match.

Apply to all six loop sites that call `financialMonth()` or `Calendar.current.startOfDay()`:
- `fetchDailyBalances` (line ~177: `startOfDay`)
- `computeDailyBalances` (line ~477: `startOfDay`)
- `fetchExpenseBreakdown` (line ~263: `financialMonth`)
- `computeExpenseBreakdown` (line ~540: `financialMonth`)
- `fetchIncomeAndExpense` (line ~311: `financialMonth`)
- `computeIncomeAndExpense` (line ~583: `financialMonth`)

- [ ] **Step 1: Add caching to `fetchExpenseBreakdown`**

Before the loop at line 260, add cache variables. Replace the `financialMonth` call:

```swift
var lastFinancialDate: Date?
var lastFinancialMonth: String = ""

for txn in allTransactions {
    if let after, txn.date < after { continue }

    let month: String
    if let last = lastFinancialDate, Calendar.current.isDate(txn.date, inSameDayAs: last) {
        month = lastFinancialMonth
    } else {
        month = Self.financialMonth(for: txn.date, monthEnd: monthEnd)
        lastFinancialMonth = month
        lastFinancialDate = txn.date
    }
    // ... rest of loop unchanged
```

- [ ] **Step 2: Add caching to `computeExpenseBreakdown`**

Same pattern in the static method's loop at line ~537.

- [ ] **Step 3: Add caching to `fetchIncomeAndExpense`**

Same pattern in the loop at line ~307.

- [ ] **Step 4: Add caching to `computeIncomeAndExpense`**

Same pattern in the static method's loop at line ~579.

- [ ] **Step 5: Add `startOfDay` caching to `fetchDailyBalances`**

In the loop at line ~168, cache `startOfDay`:

```swift
var lastDayDate: Date?
var lastDayKey: Date = .distantPast

for txn in transactions {
    // ... applyTransaction ...

    let dayKey: Date
    if let last = lastDayDate, Calendar.current.isDate(txn.date, inSameDayAs: last) {
        dayKey = lastDayKey
    } else {
        dayKey = Calendar.current.startOfDay(for: txn.date)
        lastDayKey = dayKey
        lastDayDate = txn.date
    }
    // ... rest unchanged
```

- [ ] **Step 6: Add `startOfDay` caching to `computeDailyBalances`**

Same pattern in the static method's loop at line ~468.

- [ ] **Step 7: Build and verify**

Run: `just build-mac 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 8: Commit**

```bash
git add Backends/CloudKit/Repositories/CloudKitAnalysisRepository.swift
git commit -m "perf: cache Calendar calls in analysis loops to avoid redundant recomputation"
```

---

### Task 2: UUID Sort Fix

**Files:**
- Modify: `Backends/CloudKit/Repositories/CloudKitTransactionRepository.swift:169`

- [ ] **Step 1: Replace uuidString comparison with native UUID comparison**

At line 169:
```swift
// Before:
return a.id.uuidString < b.id.uuidString
// After:
return a.id < b.id
```

- [ ] **Step 2: Build and verify**

Run: `just build-mac 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add Backends/CloudKit/Repositories/CloudKitTransactionRepository.swift
git commit -m "perf: use native UUID Comparable instead of uuidString in sort"
```

---

### Task 3: Skip Redundant Post-Filters

**Files:**
- Modify: `Backends/CloudKit/Repositories/CloudKitTransactionRepository.swift`

The `fetchTransactionRecords` method already pushes `scheduled` and `dateRange` into SwiftData predicates. The post-filter stage re-applies them as a "safety net", but this wastes time filtering arrays that are already correctly filtered. Add a `DescriptorResult` to track what was pushed down and skip redundant post-filters.

- [ ] **Step 1: Add DescriptorResult struct**

```swift
private struct DescriptorResult {
    let pushedScheduled: Bool
    let pushedDateRange: Bool
}
```

- [ ] **Step 2: Update `fetchTransactionRecords` to return DescriptorResult**

Change return type to `(records: [TransactionRecord], result: DescriptorResult)`. All four branches push scheduled; two push dateRange:

```swift
case (false, nil):
    // pushes scheduled, not dateRange
    return (try context.fetch(...), DescriptorResult(pushedScheduled: true, pushedDateRange: false))
case (true, nil):
    return (try context.fetch(...), DescriptorResult(pushedScheduled: true, pushedDateRange: false))
case (false, .some(let range)):
    return (try context.fetch(...), DescriptorResult(pushedScheduled: true, pushedDateRange: true))
case (true, .some(let range)):
    return (try context.fetch(...), DescriptorResult(pushedScheduled: true, pushedDateRange: true))
```

- [ ] **Step 3: Update call site to skip redundant filters**

```swift
let fetchResult = try fetchTransactionRecords(scheduled: scheduled, dateRange: filter.dateRange)
let allRecords = fetchResult.records
let descriptorResult = fetchResult.result
// ...
if !descriptorResult.pushedScheduled {
    if scheduled {
        filteredRecords = filteredRecords.filter { $0.recurPeriod != nil }
    } else {
        filteredRecords = filteredRecords.filter { $0.recurPeriod == nil }
    }
}
if !descriptorResult.pushedDateRange, let dateRange = filter.dateRange {
    // ...
}
```

- [ ] **Step 4: Build and verify**

Run: `just build-mac 2>&1 | tail -5`

- [ ] **Step 5: Commit**

```bash
git add Backends/CloudKit/Repositories/CloudKitTransactionRepository.swift
git commit -m "perf: skip redundant post-filters when predicate already pushed down"
```

---

### Task 4: Batch Deletions via IN Predicate

**Files:**
- Modify: `Backends/CloudKit/Sync/ProfileSyncEngine.swift`

Replace per-record deletion with grouped IN-predicate fetches. Group deletions by record type, one fetch per type.

- [ ] **Step 1: Rewrite `applyBatchDeletions`**

```swift
private nonisolated static func applyBatchDeletions(
    _ deletions: [(CKRecord.ID, String)], context: ModelContext
) {
    // Group by record type for batch processing (one IN-predicate fetch per type)
    var uuidGrouped: [String: [UUID]] = [:]
    var stringGrouped: [String: [String]] = [:]

    for (recordID, recordType) in deletions {
        if let uuid = UUID(uuidString: recordID.recordName) {
            uuidGrouped[recordType, default: []].append(uuid)
        } else {
            stringGrouped[recordType, default: []].append(recordID.recordName)
        }
    }

    for (recordType, ids) in uuidGrouped {
        switch recordType {
        case AccountRecord.recordType:
            let records = (try? context.fetch(
                FetchDescriptor<AccountRecord>(predicate: #Predicate { ids.contains($0.id) })
            )) ?? []
            for record in records { context.delete(record) }
        case TransactionRecord.recordType:
            let records = (try? context.fetch(
                FetchDescriptor<TransactionRecord>(predicate: #Predicate { ids.contains($0.id) })
            )) ?? []
            for record in records { context.delete(record) }
        case TransactionLegRecord.recordType:
            let records = (try? context.fetch(
                FetchDescriptor<TransactionLegRecord>(predicate: #Predicate { ids.contains($0.id) })
            )) ?? []
            for record in records { context.delete(record) }
        case CategoryRecord.recordType:
            let records = (try? context.fetch(
                FetchDescriptor<CategoryRecord>(predicate: #Predicate { ids.contains($0.id) })
            )) ?? []
            for record in records { context.delete(record) }
        case EarmarkRecord.recordType:
            let records = (try? context.fetch(
                FetchDescriptor<EarmarkRecord>(predicate: #Predicate { ids.contains($0.id) })
            )) ?? []
            for record in records { context.delete(record) }
        case EarmarkBudgetItemRecord.recordType:
            let records = (try? context.fetch(
                FetchDescriptor<EarmarkBudgetItemRecord>(predicate: #Predicate { ids.contains($0.id) })
            )) ?? []
            for record in records { context.delete(record) }
        case InvestmentValueRecord.recordType:
            let records = (try? context.fetch(
                FetchDescriptor<InvestmentValueRecord>(predicate: #Predicate { ids.contains($0.id) })
            )) ?? []
            for record in records { context.delete(record) }
        default:
            batchLogger.warning("applyBatchDeletions: unknown record type '\(recordType)' — skipping")
        }
    }

    for (recordType, names) in stringGrouped {
        switch recordType {
        case InstrumentRecord.recordType:
            let records = (try? context.fetch(
                FetchDescriptor<InstrumentRecord>(predicate: #Predicate { names.contains($0.id) })
            )) ?? []
            for record in records { context.delete(record) }
        default:
            batchLogger.warning("applyBatchDeletions: unknown string-ID record type '\(recordType)' — skipping")
        }
    }
}
```

- [ ] **Step 2: Build and verify**

Run: `just build-mac 2>&1 | tail -5`

- [ ] **Step 3: Commit**

```bash
git add Backends/CloudKit/Sync/ProfileSyncEngine.swift
git commit -m "perf: batch deletions in applyBatchDeletions via IN predicate"
```

---

### Task 5: Batch Record Lookups with IN Predicates

**Files:**
- Modify: `Backends/CloudKit/Sync/ProfileSyncEngine.swift`

Replace per-UUID individual lookups with batched IN-predicate fetches per record type, pruning `remaining` set after each type.

- [ ] **Step 1: Rewrite `buildBatchRecordLookup`**

```swift
private func buildBatchRecordLookup(for uuids: Set<UUID>) -> [UUID: CKRecord] {
    let context = ModelContext(modelContainer)
    var lookup: [UUID: CKRecord] = [:]
    var remaining = uuids

    let ids = Array(remaining)
    let transactions = (try? context.fetch(
        FetchDescriptor<TransactionRecord>(predicate: #Predicate { ids.contains($0.id) })
    )) ?? []
    for r in transactions {
        lookup[r.id] = buildCKRecord(for: r)
        remaining.remove(r.id)
    }

    if !remaining.isEmpty {
        let rIds = Array(remaining)
        let legs = (try? context.fetch(
            FetchDescriptor<TransactionLegRecord>(predicate: #Predicate { rIds.contains($0.id) })
        )) ?? []
        for r in legs {
            lookup[r.id] = buildCKRecord(for: r)
            remaining.remove(r.id)
        }
    }

    if !remaining.isEmpty {
        let rIds = Array(remaining)
        let investmentValues = (try? context.fetch(
            FetchDescriptor<InvestmentValueRecord>(predicate: #Predicate { rIds.contains($0.id) })
        )) ?? []
        for r in investmentValues {
            lookup[r.id] = buildCKRecord(for: r)
            remaining.remove(r.id)
        }
    }

    if !remaining.isEmpty {
        let rIds = Array(remaining)
        let accounts = (try? context.fetch(
            FetchDescriptor<AccountRecord>(predicate: #Predicate { rIds.contains($0.id) })
        )) ?? []
        for r in accounts {
            lookup[r.id] = buildCKRecord(for: r)
            remaining.remove(r.id)
        }
    }

    if !remaining.isEmpty {
        let rIds = Array(remaining)
        let categories = (try? context.fetch(
            FetchDescriptor<CategoryRecord>(predicate: #Predicate { rIds.contains($0.id) })
        )) ?? []
        for r in categories {
            lookup[r.id] = buildCKRecord(for: r)
            remaining.remove(r.id)
        }
    }

    if !remaining.isEmpty {
        let rIds = Array(remaining)
        let earmarks = (try? context.fetch(
            FetchDescriptor<EarmarkRecord>(predicate: #Predicate { rIds.contains($0.id) })
        )) ?? []
        for r in earmarks {
            lookup[r.id] = buildCKRecord(for: r)
            remaining.remove(r.id)
        }
    }

    if !remaining.isEmpty {
        let rIds = Array(remaining)
        let budgetItems = (try? context.fetch(
            FetchDescriptor<EarmarkBudgetItemRecord>(predicate: #Predicate { rIds.contains($0.id) })
        )) ?? []
        for r in budgetItems {
            lookup[r.id] = buildCKRecord(for: r)
            remaining.remove(r.id)
        }
    }

    if !remaining.isEmpty {
        logger.warning("Batch lookup: \(remaining.count) of \(uuids.count) records not found in local store")
    }

    return lookup
}
```

- [ ] **Step 2: Build and verify**

Run: `just build-mac 2>&1 | tail -5`

- [ ] **Step 3: Commit**

```bash
git add Backends/CloudKit/Sync/ProfileSyncEngine.swift
git commit -m "perf: batch-fetch buildBatchRecordLookup with IN predicates"
```

---

### Task 6: Generic queueIDs Helper

**Files:**
- Modify: `Backends/CloudKit/Sync/ProfileSyncEngine.swift`

Extract a generic helper that creates a fresh ModelContext per type to reduce peak memory. Handle InstrumentRecord (String IDs) separately since it uses `queueSave(recordName:)`.

- [ ] **Step 1: Rewrite `queueAllExistingRecords`**

```swift
private func queueAllExistingRecords() {
    let signpostID = OSSignpostID(log: Signposts.sync)
    os_signpost(.begin, log: Signposts.sync, name: "queueAllExistingRecords", signpostID: signpostID)
    defer { os_signpost(.end, log: Signposts.sync, name: "queueAllExistingRecords", signpostID: signpostID) }
    var total = 0

    // Use a fresh ModelContext per type so fetched objects are released between types,
    // reducing peak memory when the local store has many records.
    func queueIDs<T: PersistentModel>(_ type: T.Type, extract: (T) -> UUID) {
        let context = ModelContext(modelContainer)
        if let records = try? context.fetch(FetchDescriptor<T>()) {
            for r in records {
                queuePendingSave(for: extract(r))
                total += 1
            }
        }
    }

    func queueStringIDs<T: PersistentModel>(_ type: T.Type, extract: (T) -> String) {
        let context = ModelContext(modelContainer)
        if let records = try? context.fetch(FetchDescriptor<T>()) {
            for r in records {
                queueSave(recordName: extract(r))
                total += 1
            }
        }
    }

    // Queue in dependency order:
    // 1. Instruments (no dependencies — must arrive before records that reference them)
    // 2. Categories (no dependencies)
    // 3. Accounts (no dependencies)
    // 4. Earmarks (reference instruments)
    // 5. Budget items (reference earmarks + categories + instruments)
    // 6. Investment values (reference accounts + instruments)
    // 7. Transactions (header only, no dependencies)
    // 8. Transaction legs (reference transactions, accounts, instruments)
    queueStringIDs(InstrumentRecord.self) { $0.id }
    queueIDs(CategoryRecord.self) { $0.id }
    queueIDs(AccountRecord.self) { $0.id }
    queueIDs(EarmarkRecord.self) { $0.id }
    queueIDs(EarmarkBudgetItemRecord.self) { $0.id }
    queueIDs(InvestmentValueRecord.self) { $0.id }
    queueIDs(TransactionRecord.self) { $0.id }
    queueIDs(TransactionLegRecord.self) { $0.id }

    if total > 0 {
        logger.info("Queued \(total) existing records for initial upload")
    }
}
```

- [ ] **Step 2: Build and verify**

Run: `just build-mac 2>&1 | tail -5`

- [ ] **Step 3: Commit**

```bash
git add Backends/CloudKit/Sync/ProfileSyncEngine.swift
git commit -m "perf: deduplicate queueAllExistingRecords with generic closure and per-type context"
```

---

### Task 7: Debounced System Fields Cache Writes

**Files:**
- Modify: `Backends/CloudKit/Sync/ProfileSyncEngine.swift`

The sync engine calls `saveSystemFieldsCache()` after every batch of sent/received records. On bulk sync this can mean dozens of plist writes per second. Debounce to at most once per second.

- [ ] **Step 1: Add task property**

Add to the class properties:
```swift
private var systemFieldsSaveTask: Task<Void, Never>?
```

- [ ] **Step 2: Extract `flushSystemFieldsCache`**

Rename current `saveSystemFieldsCache` to `flushSystemFieldsCache`.

- [ ] **Step 3: Rewrite `saveSystemFieldsCache` with debounce**

```swift
private func saveSystemFieldsCache() {
    systemFieldsSaveTask?.cancel()
    systemFieldsSaveTask = Task { [weak self] in
        try? await Task.sleep(for: .seconds(1))
        guard !Task.isCancelled, let self else { return }
        self.flushSystemFieldsCache()
    }
}
```

- [ ] **Step 4: Cancel task in `stop()`**

Add `systemFieldsSaveTask?.cancel()` to the `stop()` method, and flush before stopping:
```swift
func stop() {
    systemFieldsSaveTask?.cancel()
    flushSystemFieldsCache()
    syncEngine = nil
    isRunning = false
    logger.info("Stopped sync engine for profile \(self.profileId)")
}
```

- [ ] **Step 5: Build and verify**

Run: `just build-mac 2>&1 | tail -5`

- [ ] **Step 6: Commit**

```bash
git add Backends/CloudKit/Sync/ProfileSyncEngine.swift
git commit -m "perf: debounce system fields cache writes to at most once per second"
```
