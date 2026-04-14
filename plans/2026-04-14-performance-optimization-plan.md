# Performance Optimization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Status:** Partially implemented. Phase 0 baselines captured, Phase 1 sync download optimizations done (isFetchingChanges, targeted invalidation, debouncing, signposts, duplicate call elimination, Calendar caching). Phase 2 (upload) and Phase 3 (query/UI) not started.

**Goal:** Eliminate UI jitter during large iCloud sync and optimize loading performance for sidebar, transaction lists, and analysis.

**Architecture:** Benchmark-first approach — baseline, fix, verify, commit. Improvements span the sync engine (download/upload), SwiftData queries, domain object conversion, and store reload patterns.

**Tech Stack:** Swift, SwiftData, CKSyncEngine, XCTest (measure blocks), os_signpost

**Design spec:** `plans/2026-04-14-performance-optimization-design.md`

---

## Phase 0: Baselines

### Task 1: Run existing benchmarks and record baselines

**Files:**
- Read: `MoolahBenchmarks/TransactionFetchBenchmarks.swift`
- Read: `MoolahBenchmarks/BalanceBenchmarks.swift`
- Read: `MoolahBenchmarks/SyncBatchBenchmarks.swift`
- Read: `MoolahBenchmarks/ConversionBenchmarks.swift`

- [ ] **Step 1: Run all existing benchmarks and capture output**

```bash
mkdir -p .agent-tmp
just benchmark 2>&1 | tee .agent-tmp/baseline-benchmarks.txt
```

- [ ] **Step 2: Extract baseline numbers**

```bash
grep -E 'measured|values:' .agent-tmp/baseline-benchmarks.txt > .agent-tmp/baseline-summary.txt
```

Record these numbers — every subsequent task will compare against them.

- [ ] **Step 3: Clean up**

```bash
rm .agent-tmp/baseline-benchmarks.txt
```

Keep `.agent-tmp/baseline-summary.txt` for the duration of the optimization work.

---

## Phase 1: SwiftData Indexes (Highest Single Impact)

### Task 2: Add SwiftData indexes to all model types

Every predicate query is currently a full table scan. Adding indexes on columns used in WHERE clauses is the single highest-impact change.

**Files:**
- Modify: `Backends/CloudKit/Models/TransactionRecord.swift:1-86`
- Modify: `Backends/CloudKit/Models/AccountRecord.swift:1-56`
- Modify: `Backends/CloudKit/Models/CategoryRecord.swift:1-26`
- Modify: `Backends/CloudKit/Models/EarmarkRecord.swift:1-64`
- Modify: `Backends/CloudKit/Models/EarmarkBudgetItemRecord.swift:1-32`
- Modify: `Backends/CloudKit/Models/InvestmentValueRecord.swift:1-31`

- [ ] **Step 1: Add indexes to TransactionRecord**

In `Backends/CloudKit/Models/TransactionRecord.swift`, add an `#Index` macro after the `@Model` class definition. The columns used in predicates are: `id`, `accountId`, `toAccountId`, `date`, `recurPeriod`, `earmarkId`, `categoryId`.

```swift
@Model
final class TransactionRecord {
  #Index<TransactionRecord>([\.id], [\.accountId, \.recurPeriod, \.date], [\.toAccountId, \.recurPeriod, \.date], [\.earmarkId], [\.date])

  var id: UUID = UUID()
  // ... rest unchanged
```

The composite index `[\.accountId, \.recurPeriod, \.date]` covers the most common query: "non-scheduled transactions for an account, sorted by date". The `[\.toAccountId, \.recurPeriod, \.date]` covers the secondary query for transfers.

- [ ] **Step 2: Add indexes to AccountRecord**

In `Backends/CloudKit/Models/AccountRecord.swift`:

```swift
@Model
final class AccountRecord {
  #Index<AccountRecord>([\.id])

  var id: UUID = UUID()
  // ... rest unchanged
```

- [ ] **Step 3: Add indexes to remaining models**

In `Backends/CloudKit/Models/CategoryRecord.swift`:
```swift
@Model
final class CategoryRecord {
  #Index<CategoryRecord>([\.id])
  // ...
```

In `Backends/CloudKit/Models/EarmarkRecord.swift`:
```swift
@Model
final class EarmarkRecord {
  #Index<EarmarkRecord>([\.id])
  // ...
```

In `Backends/CloudKit/Models/EarmarkBudgetItemRecord.swift`:
```swift
@Model
final class EarmarkBudgetItemRecord {
  #Index<EarmarkBudgetItemRecord>([\.id], [\.earmarkId])
  // ...
```

In `Backends/CloudKit/Models/InvestmentValueRecord.swift`:
```swift
@Model
final class InvestmentValueRecord {
  #Index<InvestmentValueRecord>([\.id], [\.accountId])
  // ...
```

- [ ] **Step 4: Regenerate Xcode project**

```bash
just generate
```

- [ ] **Step 5: Build to verify indexes compile**

```bash
just build-mac 2>&1 | tail -5
```

- [ ] **Step 6: Run benchmarks and compare**

```bash
mkdir -p .agent-tmp
just benchmark 2>&1 | tee .agent-tmp/post-indexes-benchmarks.txt
grep -E 'measured|values:' .agent-tmp/post-indexes-benchmarks.txt > .agent-tmp/post-indexes-summary.txt
diff .agent-tmp/baseline-summary.txt .agent-tmp/post-indexes-summary.txt
rm .agent-tmp/post-indexes-benchmarks.txt
```

- [ ] **Step 7: Run full test suite to verify no regressions**

```bash
just test 2>&1 | tee .agent-tmp/test-output.txt
grep -c 'failed' .agent-tmp/test-output.txt
rm .agent-tmp/test-output.txt
```

- [ ] **Step 8: Commit**

```bash
git add Backends/CloudKit/Models/
git commit -m "$(cat <<'EOF'
perf: add SwiftData indexes to all model types

Adds #Index declarations for columns used in WHERE clauses:
- TransactionRecord: composite indexes on (accountId, recurPeriod, date),
  (toAccountId, recurPeriod, date), plus earmarkId, date
- AccountRecord, CategoryRecord, EarmarkRecord: id
- EarmarkBudgetItemRecord: id, earmarkId
- InvestmentValueRecord: id, accountId

Every predicate query was previously a full table scan.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 2: Currency.from() Optimization

### Task 3: Eliminate NumberFormatter in Currency.from()

`Currency.from(code:)` creates a new `NumberFormatter` on every call to derive symbol and decimals. This is called once per record in `toDomain()` — 18k+ times during analysis loads. NumberFormatter is notoriously expensive.

**Files:**
- Modify: `Domain/Models/Currency.swift:10-19`
- Create: `MoolahTests/Domain/CurrencyTests.swift`

- [ ] **Step 1: Write test for Currency.from() correctness**

Create `MoolahTests/Domain/CurrencyTests.swift`:

```swift
import XCTest

@testable import Moolah

final class CurrencyTests: XCTestCase {
  func testFromCode_AUD() {
    let currency = Currency.from(code: "AUD")
    XCTAssertEqual(currency.code, "AUD")
    XCTAssertEqual(currency.decimals, 2)
    XCTAssertFalse(currency.symbol.isEmpty)
  }

  func testFromCode_USD() {
    let currency = Currency.from(code: "USD")
    XCTAssertEqual(currency.code, "USD")
    XCTAssertEqual(currency.decimals, 2)
  }

  func testFromCode_JPY() {
    let currency = Currency.from(code: "JPY")
    XCTAssertEqual(currency.code, "JPY")
    XCTAssertEqual(currency.decimals, 0)
  }

  func testFromCode_BTC() {
    // Unknown/crypto codes should return reasonable defaults
    let currency = Currency.from(code: "BTC")
    XCTAssertEqual(currency.code, "BTC")
  }

  func testFromCode_sameCodeReturnsSameResult() {
    let a = Currency.from(code: "AUD")
    let b = Currency.from(code: "AUD")
    XCTAssertEqual(a, b)
  }

  func testFromCode_emptyCode() {
    let currency = Currency.from(code: "")
    XCTAssertEqual(currency.code, "")
  }
}
```

- [ ] **Step 2: Run test to verify it passes with current implementation**

```bash
mkdir -p .agent-tmp
just test 2>&1 | tee .agent-tmp/test-output.txt
grep 'CurrencyTests' .agent-tmp/test-output.txt
rm .agent-tmp/test-output.txt
```

- [ ] **Step 3: Add a static lookup cache to Currency.from()**

Modify `Domain/Models/Currency.swift`. Replace the `from()` method with one that uses a static concurrent-safe cache. The NumberFormatter is only called once per unique currency code, then cached forever (there are only a handful of distinct codes in practice).

```swift
private static let cacheLock = NSLock()
private static var cache: [String: Currency] = [:]

static func from(code: String) -> Currency {
  cacheLock.lock()
  if let cached = cache[code] {
    cacheLock.unlock()
    return cached
  }
  cacheLock.unlock()

  let formatter = NumberFormatter()
  formatter.numberStyle = .currency
  formatter.currencyCode = code
  let currency = Currency(
    code: code,
    symbol: formatter.currencySymbol ?? code,
    decimals: formatter.maximumFractionDigits
  )

  cacheLock.lock()
  cache[code] = currency
  cacheLock.unlock()
  return currency
}
```

- [ ] **Step 4: Run tests to verify correctness**

```bash
mkdir -p .agent-tmp
just test 2>&1 | tee .agent-tmp/test-output.txt
grep -i 'CurrencyTests\|failed' .agent-tmp/test-output.txt
rm .agent-tmp/test-output.txt
```

- [ ] **Step 5: Run ConversionBenchmarks to measure improvement**

```bash
mkdir -p .agent-tmp
just benchmark ConversionBenchmarks 2>&1 | tee .agent-tmp/post-currency-benchmarks.txt
grep -E 'measured|values:' .agent-tmp/post-currency-benchmarks.txt
rm .agent-tmp/post-currency-benchmarks.txt
```

- [ ] **Step 6: Commit**

```bash
git add Domain/Models/Currency.swift MoolahTests/Domain/CurrencyTests.swift
git commit -m "$(cat <<'EOF'
perf: cache Currency.from() to avoid repeated NumberFormatter allocation

Currency.from(code:) was creating a new NumberFormatter on every call.
This is called once per record in toDomain() — 18k+ times during
analysis loads. Now caches by code string (only a handful of distinct
codes in practice).

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 3: Sync Download Optimizations

### Task 4: Add sync download benchmark

Before optimizing the download path, we need a benchmark for `applyRemoteChanges`.

**Files:**
- Create: `MoolahBenchmarks/SyncDownloadBenchmarks.swift`

- [ ] **Step 1: Write the benchmark**

Create `MoolahBenchmarks/SyncDownloadBenchmarks.swift`:

```swift
import CloudKit
import SwiftData
import XCTest
import os

@testable import Moolah

final class SyncDownloadBenchmarks: XCTestCase {
  nonisolated(unsafe) private static var _backend: CloudKitBackend!
  nonisolated(unsafe) private static var _container: ModelContainer!
  nonisolated(unsafe) private static var _syncEngine: ProfileSyncEngine!

  override class func setUp() {
    super.setUp()
    let result = try! TestBackend.create()
    _backend = result.backend
    _container = result.container
    try! awaitSync { @MainActor in
      BenchmarkFixtures.seed(scale: .x2, in: result.container)
    }
    _syncEngine = try! awaitSync { @MainActor in
      ProfileSyncEngine(profileId: UUID(), modelContainer: result.container)
    }
  }

  override class func tearDown() {
    _syncEngine = nil
    _backend = nil
    _container = nil
    super.tearDown()
  }

  private var syncEngine: ProfileSyncEngine { Self._syncEngine }
  private var container: ModelContainer { Self._container }

  private var metrics: [XCTMetric] { [XCTClockMetric(), XCTMemoryMetric()] }
  private var options: XCTMeasureOptions {
    let opts = XCTMeasureOptions()
    opts.iterationCount = 10
    return opts
  }

  /// Measures applying 400 new transaction CKRecords (insert path).
  func testApplyRemoteChanges_400inserts() {
    // Pre-build CKRecords outside the measure block
    let zoneID = CKRecordZone.ID(zoneName: "bench-zone", ownerName: CKCurrentUserDefaultName)
    let ckRecords: [CKRecord] = (0..<400).map { i in
      let id = UUID()
      let record = CKRecord(
        recordType: TransactionRecord.recordType,
        recordID: CKRecord.ID(recordName: id.uuidString, zoneID: zoneID)
      )
      record["type"] = "expense" as CKRecordValue
      record["date"] = Date() as CKRecordValue
      record["amount"] = 1000 as CKRecordValue
      record["currencyCode"] = "AUD" as CKRecordValue
      record["accountId"] = BenchmarkFixtures.heavyAccountId.uuidString as CKRecordValue
      return record
    }

    measure(metrics: metrics, options: options) {
      _ = try! awaitSync { @MainActor in
        self.syncEngine.applyRemoteChanges(saved: ckRecords, deleted: [])
      }
    }
  }

  /// Measures applying 400 deletions.
  func testApplyRemoteChanges_400deletions() {
    // Fetch 400 existing transaction IDs to delete
    let ids: [(CKRecord.ID, String)] = try! awaitSync { @MainActor in
      let context = self.container.mainContext
      var descriptor = FetchDescriptor<TransactionRecord>()
      descriptor.fetchLimit = 400
      let records = try context.fetch(descriptor)
      let zoneID = CKRecordZone.ID(zoneName: "bench-zone", ownerName: CKCurrentUserDefaultName)
      return records.map { record in
        (CKRecord.ID(recordName: record.id.uuidString, zoneID: zoneID), TransactionRecord.recordType)
      }
    }

    measure(metrics: metrics, options: options) {
      _ = try! awaitSync { @MainActor in
        self.syncEngine.applyRemoteChanges(saved: [], deleted: ids)
      }
    }
  }
}
```

- [ ] **Step 2: Regenerate project and run benchmark**

```bash
just generate
mkdir -p .agent-tmp
just benchmark SyncDownloadBenchmarks 2>&1 | tee .agent-tmp/sync-download-baseline.txt
grep -E 'measured|values:' .agent-tmp/sync-download-baseline.txt
rm .agent-tmp/sync-download-baseline.txt
```

- [ ] **Step 3: Commit**

```bash
git add MoolahBenchmarks/SyncDownloadBenchmarks.swift
git commit -m "$(cat <<'EOF'
perf: add SyncDownloadBenchmarks for applyRemoteChanges baseline

Measures applying 400 insert and 400 deletion CKRecords to establish
baseline performance for sync download path optimization.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 5: Batch deletions in applyBatchDeletions

Currently does individual fetch+delete per record (one query per deletion). Group by type and batch-fetch.

**Files:**
- Modify: `Backends/CloudKit/Sync/ProfileSyncEngine.swift:443-478`

- [ ] **Step 1: Replace per-record deletion with batch deletion**

Replace the `applyBatchDeletions` method (lines 443-478) with a batch-fetch approach:

```swift
private nonisolated static func applyBatchDeletions(
  _ deletions: [(CKRecord.ID, String)], context: ModelContext
) {
  // Group deletions by record type
  var grouped: [String: [UUID]] = [:]
  for (recordID, recordType) in deletions {
    guard let uuid = UUID(uuidString: recordID.recordName) else { continue }
    grouped[recordType, default: []].append(uuid)
  }

  for (recordType, ids) in grouped {
    switch recordType {
    case AccountRecord.recordType:
      batchDelete(AccountRecord.self, ids: ids, context: context)
    case TransactionRecord.recordType:
      batchDelete(TransactionRecord.self, ids: ids, context: context)
    case CategoryRecord.recordType:
      batchDelete(CategoryRecord.self, ids: ids, context: context)
    case EarmarkRecord.recordType:
      batchDelete(EarmarkRecord.self, ids: ids, context: context)
    case EarmarkBudgetItemRecord.recordType:
      batchDelete(EarmarkBudgetItemRecord.self, ids: ids, context: context)
    case InvestmentValueRecord.recordType:
      batchDelete(InvestmentValueRecord.self, ids: ids, context: context)
    default:
      batchLogger.warning("applyBatchDeletions: unknown record type '\(recordType)' — skipping")
    }
  }
}

private nonisolated static func batchDelete<T: PersistentModel>(
  _ type: T.Type, ids: [UUID], context: ModelContext
) where T: HasID {
  guard !ids.isEmpty else { return }
  let records: [T]
  do {
    records = try context.fetch(
      FetchDescriptor<T>(predicate: #Predicate { ids.contains($0.id) })
    )
  } catch {
    batchLogger.error("batchDelete \(String(describing: T.self)): fetch failed: \(error)")
    return
  }
  for record in records {
    context.delete(record)
  }
}
```

Note: This requires a `HasID` protocol or using concrete types. Since SwiftData `#Predicate` doesn't support generics, you'll need to keep the concrete switch but use batch fetch within each case:

```swift
private nonisolated static func applyBatchDeletions(
  _ deletions: [(CKRecord.ID, String)], context: ModelContext
) {
  var grouped: [String: [UUID]] = [:]
  for (recordID, recordType) in deletions {
    guard let uuid = UUID(uuidString: recordID.recordName) else { continue }
    grouped[recordType, default: []].append(uuid)
  }

  for (recordType, ids) in grouped {
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
}
```

- [ ] **Step 2: Build and run tests**

```bash
mkdir -p .agent-tmp
just test 2>&1 | tee .agent-tmp/test-output.txt
grep -c 'failed' .agent-tmp/test-output.txt
rm .agent-tmp/test-output.txt
```

- [ ] **Step 3: Run sync benchmarks to measure improvement**

```bash
mkdir -p .agent-tmp
just benchmark SyncDownloadBenchmarks 2>&1 | tee .agent-tmp/post-batch-delete.txt
grep -E 'measured|values:' .agent-tmp/post-batch-delete.txt
rm .agent-tmp/post-batch-delete.txt
```

- [ ] **Step 4: Commit**

```bash
git add Backends/CloudKit/Sync/ProfileSyncEngine.swift
git commit -m "$(cat <<'EOF'
perf: batch-fetch deletions in sync engine instead of per-record queries

applyBatchDeletions now groups deletions by type and does one batch
fetch per type using IN predicate, instead of individual fetch+delete
per record. For 400 deletions this reduces queries from 400 to ~6.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 6: Targeted balance invalidation

Only invalidate accounts referenced by incoming transactions, not all accounts.

**Files:**
- Modify: `Backends/CloudKit/Sync/ProfileSyncEngine.swift:263-327` (applyRemoteChanges)
- Modify: `Backends/CloudKit/Sync/ProfileSyncEngine.swift:484-489` (invalidateCachedBalances)

- [ ] **Step 1: Extract affected account IDs from incoming CKRecords**

In `applyRemoteChanges`, before calling `invalidateCachedBalances`, extract the set of account IDs from transaction CKRecords:

```swift
if hasTransactionChanges {
  // Extract account IDs affected by incoming transaction changes
  let affectedAccountIds = Self.extractAffectedAccountIds(
    saved: saved, deleted: deleted)
  os_signpost(
    .begin, log: Signposts.balance, name: "invalidateCachedBalances", signpostID: signpostID)
  Self.invalidateCachedBalances(accountIds: affectedAccountIds, context: context)
  os_signpost(
    .end, log: Signposts.balance, name: "invalidateCachedBalances", signpostID: signpostID)
}
```

Add the extraction helper:

```swift
private nonisolated static func extractAffectedAccountIds(
  saved: [CKRecord],
  deleted: [(CKRecord.ID, String)]
) -> Set<UUID> {
  var ids = Set<UUID>()
  for ckRecord in saved where ckRecord.recordType == TransactionRecord.recordType {
    if let s = ckRecord["accountId"] as? String, let id = UUID(uuidString: s) {
      ids.insert(id)
    }
    if let s = ckRecord["toAccountId"] as? String, let id = UUID(uuidString: s) {
      ids.insert(id)
    }
  }
  // For deletions we don't have the record content, so invalidate all accounts
  // if any transaction deletions are present
  if deleted.contains(where: { $0.1 == TransactionRecord.recordType }) {
    return []  // Empty set signals "invalidate all"
  }
  return ids
}
```

- [ ] **Step 2: Update invalidateCachedBalances to accept account IDs**

```swift
/// Sets cachedBalance to nil on affected accounts so it will be recomputed on next load.
/// If accountIds is empty, invalidates ALL accounts (used when deletions lack record content).
nonisolated private static func invalidateCachedBalances(
  accountIds: Set<UUID>, context: ModelContext
) {
  if accountIds.isEmpty {
    // Invalidate all — deletion case where we don't know which accounts
    guard let accounts = try? context.fetch(FetchDescriptor<AccountRecord>()) else { return }
    for account in accounts {
      account.cachedBalance = nil
    }
  } else {
    let ids = Array(accountIds)
    guard let accounts = try? context.fetch(
      FetchDescriptor<AccountRecord>(predicate: #Predicate { ids.contains($0.id) })
    ) else { return }
    for account in accounts {
      account.cachedBalance = nil
    }
  }
}
```

- [ ] **Step 3: Build and run tests**

```bash
mkdir -p .agent-tmp
just test 2>&1 | tee .agent-tmp/test-output.txt
grep -c 'failed' .agent-tmp/test-output.txt
rm .agent-tmp/test-output.txt
```

- [ ] **Step 4: Run benchmarks**

```bash
mkdir -p .agent-tmp
just benchmark SyncBatchBenchmarks/testBalanceInvalidation 2>&1 | tee .agent-tmp/post-targeted-invalidation.txt
grep -E 'measured|values:' .agent-tmp/post-targeted-invalidation.txt
rm .agent-tmp/post-targeted-invalidation.txt
```

- [ ] **Step 5: Commit**

```bash
git add Backends/CloudKit/Sync/ProfileSyncEngine.swift
git commit -m "$(cat <<'EOF'
perf: targeted balance invalidation during sync

Instead of fetching and invalidating ALL accounts when transactions
sync, extract the affected accountIds from incoming CKRecords and
only invalidate those. Falls back to invalidate-all for deletions
where record content is unavailable.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 7: Debounce system fields cache writes

`saveSystemFieldsCache()` writes the entire dictionary to disk on every batch. Debounce to at most once per second.

**Files:**
- Modify: `Backends/CloudKit/Sync/ProfileSyncEngine.swift:368-375` (saveSystemFieldsCache)
- Modify: `Backends/CloudKit/Sync/ProfileSyncEngine.swift:183-188` (stop — flush on stop)

- [ ] **Step 1: Add debounced save mechanism**

Add a property and modify `saveSystemFieldsCache`:

```swift
private var systemFieldsSaveTask: Task<Void, Never>?

private func saveSystemFieldsCache() {
  // Debounce: cancel pending write, schedule new one in 1 second
  systemFieldsSaveTask?.cancel()
  systemFieldsSaveTask = Task { [weak self] in
    try? await Task.sleep(for: .seconds(1))
    guard !Task.isCancelled, let self else { return }
    self.flushSystemFieldsCache()
  }
}

private func flushSystemFieldsCache() {
  do {
    let data = try PropertyListEncoder().encode(systemFieldsCache)
    try data.write(to: systemFieldsCacheURL, options: .atomic)
  } catch {
    logger.error("Failed to save system fields cache: \(error)")
  }
}
```

- [ ] **Step 2: Flush on engine stop**

Modify the `stop()` method to flush any pending writes:

```swift
func stop() {
  systemFieldsSaveTask?.cancel()
  flushSystemFieldsCache()
  syncEngine = nil
  isRunning = false
  logger.info("Stopped sync engine for profile \(self.profileId)")
}
```

- [ ] **Step 3: Build and run tests**

```bash
mkdir -p .agent-tmp
just test 2>&1 | tee .agent-tmp/test-output.txt
grep -c 'failed' .agent-tmp/test-output.txt
rm .agent-tmp/test-output.txt
```

- [ ] **Step 4: Commit**

```bash
git add Backends/CloudKit/Sync/ProfileSyncEngine.swift
git commit -m "$(cat <<'EOF'
perf: debounce system fields cache writes to at most once per second

During large sync, saveSystemFieldsCache() was called after every
batch (hundreds of times). Now debounces with 1-second delay and
flushes on engine stop to avoid data loss.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 8: Move CKRecord parsing off MainActor

Extract CKRecord field values and system fields encoding off the main thread. Only SwiftData operations need MainActor.

**Files:**
- Modify: `Backends/CloudKit/Sync/ProfileSyncEngine.swift:263-327` (applyRemoteChanges)

- [ ] **Step 1: Extract data from CKRecords before MainActor work**

Restructure `applyRemoteChanges` to do CKRecord parsing first (this is pure data transform), then apply to SwiftData on MainActor. The method is already MainActor-isolated, so we need to refactor the system fields caching to happen synchronously but batch the disk write:

```swift
func applyRemoteChanges(
  saved: [CKRecord],
  deleted: [(CKRecord.ID, String)]
) {
  let signpostID = OSSignpostID(log: Signposts.sync)
  os_signpost(
    .begin, log: Signposts.sync, name: "applyRemoteChanges", signpostID: signpostID,
    "%{public}d saves, %{public}d deletes", saved.count, deleted.count)
  defer {
    os_signpost(.end, log: Signposts.sync, name: "applyRemoteChanges", signpostID: signpostID)
  }

  isApplyingRemoteChanges = true
  defer { isApplyingRemoteChanges = false }

  let typeCounts = Dictionary(grouping: saved, by: { $0.recordType })
    .mapValues(\.count)
  logger.info("applyRemoteChanges: \(saved.count) saves \(typeCounts), \(deleted.count) deletes")

  // Cache system fields in memory (disk write is debounced)
  for ckRecord in saved {
    systemFieldsCache[ckRecord.recordID.recordName] = ckRecord.encodedSystemFields
  }
  saveSystemFieldsCache()

  let context = modelContainer.mainContext

  os_signpost(
    .begin, log: Signposts.sync, name: "applyBatchSaves", signpostID: signpostID,
    "%{public}d records", saved.count)
  Self.applyBatchSaves(saved, context: context)
  os_signpost(.end, log: Signposts.sync, name: "applyBatchSaves", signpostID: signpostID)

  os_signpost(
    .begin, log: Signposts.sync, name: "applyBatchDeletions", signpostID: signpostID,
    "%{public}d records", deleted.count)
  Self.applyBatchDeletions(deleted, context: context)
  os_signpost(.end, log: Signposts.sync, name: "applyBatchDeletions", signpostID: signpostID)

  let hasTransactionChanges =
    saved.contains { $0.recordType == TransactionRecord.recordType }
    || deleted.contains { $0.1 == TransactionRecord.recordType }
  if hasTransactionChanges {
    let affectedAccountIds = Self.extractAffectedAccountIds(saved: saved, deleted: deleted)
    os_signpost(
      .begin, log: Signposts.balance, name: "invalidateCachedBalances", signpostID: signpostID)
    Self.invalidateCachedBalances(accountIds: affectedAccountIds, context: context)
    os_signpost(
      .end, log: Signposts.balance, name: "invalidateCachedBalances", signpostID: signpostID)
  }

  do {
    os_signpost(.begin, log: Signposts.sync, name: "contextSave", signpostID: signpostID)
    try context.save()
    os_signpost(.end, log: Signposts.sync, name: "contextSave", signpostID: signpostID)
    onRemoteChangesApplied?()
  } catch {
    os_signpost(.end, log: Signposts.sync, name: "contextSave", signpostID: signpostID)
    logger.error("Failed to save remote changes: \(error)")
  }
}
```

The key insight: the `encodedSystemFields` computation is the expensive part (NSKeyedArchiver per record). Since this method is `@MainActor`, we can't easily move it off-thread without restructuring. However, with the debounced disk write from Task 7, the main thread cost is now just the in-memory dictionary updates — the expensive disk I/O happens async.

For a more aggressive off-main approach, pre-compute system fields data in the delegate before dispatching to MainActor:

- [ ] **Step 2: Pre-extract system fields in the delegate method**

Modify `handleEventOnMain` to pre-extract system fields data before the MainActor dispatch in `handleEvent`:

```swift
nonisolated func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
  // Pre-extract system fields data off MainActor (NSKeyedArchiver is expensive)
  let preExtracted: [(String, Data)]?
  if case .fetchedRecordZoneChanges(let changes) = event {
    preExtracted = changes.modifications.map { mod in
      (mod.record.recordID.recordName, mod.record.encodedSystemFields)
    }
  } else {
    preExtracted = nil
  }

  await MainActor.run {
    handleEventOnMain(event, syncEngine: syncEngine, preExtractedSystemFields: preExtracted)
  }
}
```

Update `handleEventOnMain` to accept and use the pre-extracted data:

```swift
private func handleEventOnMain(
  _ event: CKSyncEngine.Event,
  syncEngine: CKSyncEngine,
  preExtractedSystemFields: [(String, Data)]? = nil
) {
  // ... existing switch ...
  case .fetchedRecordZoneChanges(let changes):
    let saved = changes.modifications.map(\.record)
    let deleted: [(CKRecord.ID, String)] = changes.deletions.map {
      ($0.recordID, $0.recordType)
    }
    guard !saved.isEmpty || !deleted.isEmpty else { break }
    applyRemoteChanges(
      saved: saved,
      deleted: deleted,
      preExtractedSystemFields: preExtractedSystemFields
    )
  // ...
}
```

Update `applyRemoteChanges` to use pre-extracted fields when available:

```swift
func applyRemoteChanges(
  saved: [CKRecord],
  deleted: [(CKRecord.ID, String)],
  preExtractedSystemFields: [(String, Data)]? = nil
) {
  // ... signpost setup ...

  // Use pre-extracted system fields (computed off MainActor) if available
  if let preExtracted = preExtractedSystemFields {
    for (recordName, data) in preExtracted {
      systemFieldsCache[recordName] = data
    }
  } else {
    for ckRecord in saved {
      systemFieldsCache[ckRecord.recordID.recordName] = ckRecord.encodedSystemFields
    }
  }
  saveSystemFieldsCache()

  // ... rest unchanged ...
}
```

- [ ] **Step 3: Build and run tests**

```bash
mkdir -p .agent-tmp
just test 2>&1 | tee .agent-tmp/test-output.txt
grep -c 'failed' .agent-tmp/test-output.txt
rm .agent-tmp/test-output.txt
```

- [ ] **Step 4: Run sync download benchmarks**

```bash
mkdir -p .agent-tmp
just benchmark SyncDownloadBenchmarks 2>&1 | tee .agent-tmp/post-offmain.txt
grep -E 'measured|values:' .agent-tmp/post-offmain.txt
rm .agent-tmp/post-offmain.txt
```

- [ ] **Step 5: Commit**

```bash
git add Backends/CloudKit/Sync/ProfileSyncEngine.swift
git commit -m "$(cat <<'EOF'
perf: pre-extract CKRecord system fields off MainActor

NSKeyedArchiver encoding for system fields was happening on the main
thread for every received record. Now pre-computed in the delegate
method before dispatching to MainActor.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 9: Selective store reloads after sync

Pass changed record types through so only affected stores reload.

**Files:**
- Modify: `Backends/CloudKit/Sync/ProfileSyncEngine.swift:18` (onRemoteChangesApplied callback)
- Modify: `Backends/CloudKit/Sync/ProfileSyncEngine.swift:322` (callback invocation)
- Modify: `App/ProfileSession.swift:127-174` (scheduleReloadFromSync)

- [ ] **Step 1: Change callback signature to include changed types**

In `ProfileSyncEngine.swift`, change the callback type:

```swift
/// Callback invoked after remote changes are applied to the local store.
/// Provides the set of record types that changed for selective reloading.
var onRemoteChangesApplied: ((Set<String>) -> Void)?
```

Update the invocation in `applyRemoteChanges` to pass the changed types:

```swift
do {
  os_signpost(.begin, log: Signposts.sync, name: "contextSave", signpostID: signpostID)
  try context.save()
  os_signpost(.end, log: Signposts.sync, name: "contextSave", signpostID: signpostID)
  let changedTypes = Set(saved.map(\.recordType) + deleted.map(\.1))
  onRemoteChangesApplied?(changedTypes)
} catch {
  // ...
}
```

- [ ] **Step 2: Update ProfileSession to use selective reloads**

In `ProfileSession.swift`, update the callback and `scheduleReloadFromSync`:

```swift
syncEngine.onRemoteChangesApplied = { [weak self] changedTypes in
  self?.scheduleReloadFromSync(changedTypes: changedTypes)
}
```

```swift
private var pendingChangedTypes = Set<String>()

private func scheduleReloadFromSync(changedTypes: Set<String>) {
  pendingChangedTypes.formUnion(changedTypes)
  syncReloadTask?.cancel()
  syncReloadTask = Task {
    try? await Task.sleep(for: .milliseconds(500))
    guard !Task.isCancelled else { return }

    let types = self.pendingChangedTypes
    self.pendingChangedTypes.removeAll()

    logger.debug("Reloading stores after CloudKit sync: \(types)")
    if types.contains(AccountRecord.recordType) || types.contains(TransactionRecord.recordType) {
      await accountStore.reloadFromSync()
    }
    if types.contains(CategoryRecord.recordType) {
      await categoryStore.reloadFromSync()
    }
    if types.contains(EarmarkRecord.recordType) || types.contains(EarmarkBudgetItemRecord.recordType) {
      await earmarkStore.reloadFromSync()
    }
  }
}
```

- [ ] **Step 3: Build and run tests**

```bash
mkdir -p .agent-tmp
just test 2>&1 | tee .agent-tmp/test-output.txt
grep -c 'failed' .agent-tmp/test-output.txt
rm .agent-tmp/test-output.txt
```

- [ ] **Step 4: Commit**

```bash
git add Backends/CloudKit/Sync/ProfileSyncEngine.swift App/ProfileSession.swift
git commit -m "$(cat <<'EOF'
perf: selective store reloads after sync based on changed record types

Instead of reloading all stores (accounts, categories, earmarks) on
every sync event, pass the set of changed record types and only reload
affected stores. Also accumulates changed types across debounce window.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 10: Adaptive sync reload debounce

During bulk sync (consecutive rapid batches), increase debounce to avoid thrashing store reloads.

**Files:**
- Modify: `App/ProfileSession.swift:163-174`

- [ ] **Step 1: Add adaptive debounce logic**

```swift
private var lastSyncEventTime: ContinuousClock.Instant?

private func scheduleReloadFromSync(changedTypes: Set<String>) {
  pendingChangedTypes.formUnion(changedTypes)

  // Adaptive debounce: if we're receiving batches rapidly (within 1s of last),
  // extend debounce to 2s to avoid thrashing during bulk sync.
  let now = ContinuousClock.now
  let isBulkSync: Bool
  if let last = lastSyncEventTime, now - last < .seconds(1) {
    isBulkSync = true
  } else {
    isBulkSync = false
  }
  lastSyncEventTime = now
  let debounceMs = isBulkSync ? 2000 : 500

  syncReloadTask?.cancel()
  syncReloadTask = Task {
    try? await Task.sleep(for: .milliseconds(debounceMs))
    guard !Task.isCancelled else { return }

    let types = self.pendingChangedTypes
    self.pendingChangedTypes.removeAll()

    logger.debug("Reloading stores after CloudKit sync: \(types)")
    if types.contains(AccountRecord.recordType) || types.contains(TransactionRecord.recordType) {
      await accountStore.reloadFromSync()
    }
    if types.contains(CategoryRecord.recordType) {
      await categoryStore.reloadFromSync()
    }
    if types.contains(EarmarkRecord.recordType) || types.contains(EarmarkBudgetItemRecord.recordType) {
      await earmarkStore.reloadFromSync()
    }
  }
}
```

- [ ] **Step 2: Build and run tests**

```bash
mkdir -p .agent-tmp
just test 2>&1 | tee .agent-tmp/test-output.txt
grep -c 'failed' .agent-tmp/test-output.txt
rm .agent-tmp/test-output.txt
```

- [ ] **Step 3: Commit**

```bash
git add App/ProfileSession.swift
git commit -m "$(cat <<'EOF'
perf: adaptive sync reload debounce for bulk sync scenarios

When sync batches arrive within 1s of each other (bulk migration),
extends the reload debounce from 500ms to 2s to avoid repeated
full store reloads. Reverts to 500ms for normal trickle sync.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 4: Sync Upload Optimizations

### Task 11: Batch-fetch in buildBatchRecordLookup

Currently does per-UUID sequential queries across 6 types (up to 2400 queries for 400 records).

**Files:**
- Modify: `Backends/CloudKit/Sync/ProfileSyncEngine.swift:806-865`

- [ ] **Step 1: Add sync upload benchmark**

Create `MoolahBenchmarks/SyncUploadBenchmarks.swift`:

```swift
import CloudKit
import SwiftData
import XCTest
import os

@testable import Moolah

final class SyncUploadBenchmarks: XCTestCase {
  nonisolated(unsafe) private static var _backend: CloudKitBackend!
  nonisolated(unsafe) private static var _container: ModelContainer!
  nonisolated(unsafe) private static var _syncEngine: ProfileSyncEngine!

  override class func setUp() {
    super.setUp()
    let result = try! TestBackend.create()
    _backend = result.backend
    _container = result.container
    try! awaitSync { @MainActor in
      BenchmarkFixtures.seed(scale: .x2, in: result.container)
    }
    _syncEngine = try! awaitSync { @MainActor in
      ProfileSyncEngine(profileId: UUID(), modelContainer: result.container)
    }
  }

  override class func tearDown() {
    _syncEngine = nil
    _backend = nil
    _container = nil
    super.tearDown()
  }

  private var syncEngine: ProfileSyncEngine { Self._syncEngine }
  private var container: ModelContainer { Self._container }

  private var metrics: [XCTMetric] { [XCTClockMetric(), XCTMemoryMetric()] }
  private var options: XCTMeasureOptions {
    let opts = XCTMeasureOptions()
    opts.iterationCount = 10
    return opts
  }

  /// Measures batch record lookup for 400 UUIDs (the upload preparation path).
  func testBuildBatchRecordLookup_400() {
    // Fetch 400 real transaction UUIDs
    let uuids: Set<UUID> = try! awaitSync { @MainActor in
      let context = self.container.mainContext
      var descriptor = FetchDescriptor<TransactionRecord>()
      descriptor.fetchLimit = 400
      let records = try context.fetch(descriptor)
      return Set(records.map(\.id))
    }

    measure(metrics: metrics, options: options) {
      _ = try! awaitSync { @MainActor in
        self.syncEngine.buildBatchRecordLookup(for: uuids)
      }
    }
  }
}
```

Note: `buildBatchRecordLookup` is private. You'll need to change it to `internal` (package-level) for benchmarking, or add a `@testable` accessible wrapper.

- [ ] **Step 2: Make buildBatchRecordLookup internal for benchmarking**

Change `private func buildBatchRecordLookup` to `func buildBatchRecordLookup` (internal access — `@testable import` already exposes internal symbols).

- [ ] **Step 3: Run baseline benchmark**

```bash
just generate
mkdir -p .agent-tmp
just benchmark SyncUploadBenchmarks 2>&1 | tee .agent-tmp/upload-baseline.txt
grep -E 'measured|values:' .agent-tmp/upload-baseline.txt
rm .agent-tmp/upload-baseline.txt
```

- [ ] **Step 4: Replace per-UUID lookup with batch-fetch-by-type**

Replace the `buildBatchRecordLookup` method:

```swift
func buildBatchRecordLookup(for uuids: Set<UUID>) -> [UUID: CKRecord] {
  let context = ModelContext(modelContainer)
  var lookup: [UUID: CKRecord] = [:]
  var remaining = uuids

  // Batch-fetch by type using IN predicate (6 queries total, not N*6)
  // Check most common types first (transactions, investment values)
  func batchFetch<T: PersistentModel & CloudKitRecordConvertible>(
    _ type: T.Type,
    ids: [UUID],
    context: ModelContext
  ) -> [T] {
    (try? context.fetch(
      FetchDescriptor<T>(predicate: #Predicate { ids.contains($0.id) })
    )) ?? []
  }

  // SwiftData #Predicate doesn't support generics, so use concrete types
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

- [ ] **Step 5: Run benchmark to measure improvement**

```bash
mkdir -p .agent-tmp
just benchmark SyncUploadBenchmarks 2>&1 | tee .agent-tmp/post-batch-lookup.txt
grep -E 'measured|values:' .agent-tmp/post-batch-lookup.txt
rm .agent-tmp/post-batch-lookup.txt
```

- [ ] **Step 6: Build and run tests**

```bash
mkdir -p .agent-tmp
just test 2>&1 | tee .agent-tmp/test-output.txt
grep -c 'failed' .agent-tmp/test-output.txt
rm .agent-tmp/test-output.txt
```

- [ ] **Step 7: Commit**

```bash
git add Backends/CloudKit/Sync/ProfileSyncEngine.swift MoolahBenchmarks/SyncUploadBenchmarks.swift
git commit -m "$(cat <<'EOF'
perf: batch-fetch records by type in upload preparation

buildBatchRecordLookup now does 6 batch queries (one per record type
using IN predicate) instead of up to 2400 individual per-UUID queries.
Each subsequent type query only searches for remaining unfound UUIDs.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 12: Optimize queueAllExistingRecords

Currently loads full records just to get IDs.

**Files:**
- Modify: `Backends/CloudKit/Sync/ProfileSyncEngine.swift:105-163`

- [ ] **Step 1: Use fetchCount + enumeration to avoid full hydration**

SwiftData doesn't have a `fetchIdentifiers` API, but we can use `fetchCount` to check if records exist and a FetchDescriptor with only the `id` property needed. Actually, the key optimization is to avoid keeping all records in memory at once. Since we only need the ID, we can fetch and immediately discard:

```swift
private func queueAllExistingRecords() {
  let signpostID = OSSignpostID(log: Signposts.sync)
  os_signpost(
    .begin, log: Signposts.sync, name: "queueAllExistingRecords", signpostID: signpostID)
  defer {
    os_signpost(
      .end, log: Signposts.sync, name: "queueAllExistingRecords", signpostID: signpostID)
  }
  let context = ModelContext(modelContainer)
  var total = 0

  func queueIDs<T: PersistentModel>(_ type: T.Type, extract: (T) -> UUID) {
    if let records = try? context.fetch(FetchDescriptor<T>()) {
      for r in records {
        queuePendingSave(for: extract(r))
        total += 1
      }
    }
  }

  queueIDs(CategoryRecord.self) { $0.id }
  queueIDs(AccountRecord.self) { $0.id }
  queueIDs(EarmarkRecord.self) { $0.id }
  queueIDs(EarmarkBudgetItemRecord.self) { $0.id }
  queueIDs(InvestmentValueRecord.self) { $0.id }
  queueIDs(TransactionRecord.self) { $0.id }

  if total > 0 {
    logger.info("Queued \(total) existing records for initial upload")
  }
}
```

Note: The main optimization here is the deduplication of repeated code. The fundamental constraint is that SwiftData requires fetching full model objects. The real win will come from the indexes added in Task 2 making these fetches faster. However, we can add `context.reset()` between types to release memory:

```swift
func queueIDs<T: PersistentModel>(_ type: T.Type, extract: (T) -> UUID) {
  if let records = try? context.fetch(FetchDescriptor<T>()) {
    for r in records {
      queuePendingSave(for: extract(r))
      total += 1
    }
    context.reset()  // Release fetched objects from memory
  }
}
```

- [ ] **Step 2: Build and run tests**

```bash
mkdir -p .agent-tmp
just test 2>&1 | tee .agent-tmp/test-output.txt
grep -c 'failed' .agent-tmp/test-output.txt
rm .agent-tmp/test-output.txt
```

- [ ] **Step 3: Commit**

```bash
git add Backends/CloudKit/Sync/ProfileSyncEngine.swift
git commit -m "$(cat <<'EOF'
perf: reset context between types in queueAllExistingRecords

Releases fetched objects from memory between record types during
initial upload queueing. Also deduplicates the per-type fetch code.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 13: Build CKRecord directly onto cached system fields

Avoid allocating an intermediate CKRecord when cached system fields exist.

**Files:**
- Modify: `Backends/CloudKit/Sync/ProfileSyncEngine.swift:239-257`
- Modify: `Backends/CloudKit/Sync/RecordMapping.swift` (toCKRecord methods)

- [ ] **Step 1: Add a method to apply fields to an existing CKRecord**

Add a new protocol method to `CloudKitRecordConvertible`:

```swift
protocol CloudKitRecordConvertible {
  static var recordType: String { get }
  func toCKRecord(in zoneID: CKRecordZone.ID) -> CKRecord
  func applyFields(to record: CKRecord)
  static func fieldValues(from ckRecord: CKRecord) -> Self
}
```

Add `applyFields(to:)` implementations. For `TransactionRecord`:

```swift
func applyFields(to record: CKRecord) {
  record["type"] = type as CKRecordValue
  record["date"] = date as CKRecordValue
  record["amount"] = amount as CKRecordValue
  record["currencyCode"] = currencyCode as CKRecordValue
  if let accountId { record["accountId"] = accountId.uuidString as CKRecordValue }
  if let toAccountId { record["toAccountId"] = toAccountId.uuidString as CKRecordValue }
  if let payee { record["payee"] = payee as CKRecordValue }
  if let notes { record["notes"] = notes as CKRecordValue }
  if let categoryId { record["categoryId"] = categoryId.uuidString as CKRecordValue }
  if let earmarkId { record["earmarkId"] = earmarkId.uuidString as CKRecordValue }
  if let recurPeriod { record["recurPeriod"] = recurPeriod as CKRecordValue }
  if let recurEvery { record["recurEvery"] = recurEvery as CKRecordValue }
}
```

Add similar `applyFields(to:)` for all other record types. Then update `toCKRecord` to call it:

```swift
func toCKRecord(in zoneID: CKRecordZone.ID) -> CKRecord {
  let recordID = CKRecord.ID(recordName: id.uuidString, zoneID: zoneID)
  let record = CKRecord(recordType: Self.recordType, recordID: recordID)
  applyFields(to: record)
  return record
}
```

- [ ] **Step 2: Update buildCKRecord to use applyFields directly**

```swift
func buildCKRecord<T: CloudKitRecordConvertible>(for record: T) -> CKRecord {
  let recordName = (record as? any HasIDString)?.idString ?? ""
  if let cachedData = systemFieldsCache[recordName],
     let cachedRecord = CKRecord.fromEncodedSystemFields(cachedData) {
    record.applyFields(to: cachedRecord)
    return cachedRecord
  }
  return record.toCKRecord(in: zoneID)
}
```

Actually, getting the record name requires knowing the ID. Since all our types have a UUID `id` property, extract it more directly. Check how the current code gets the record name — it calls `toCKRecord` first, which creates the full record. Instead:

```swift
func buildCKRecord<T: CloudKitRecordConvertible & HasUUIDId>(for record: T) -> CKRecord {
  let recordName = record.id.uuidString
  if let cachedData = systemFieldsCache[recordName],
     let cachedRecord = CKRecord.fromEncodedSystemFields(cachedData) {
    record.applyFields(to: cachedRecord)
    return cachedRecord
  }
  return record.toCKRecord(in: zoneID)
}
```

You'll need all model types to conform to a shared `HasUUIDId` protocol, or just access `.id` directly if they all have it. The simplest approach since all models have `var id: UUID`:

Add a protocol (or use the existing pattern — all models already have `id: UUID`):

```swift
// In RecordMapping.swift or a shared location
protocol IdentifiableRecord {
  var id: UUID { get }
}

extension AccountRecord: IdentifiableRecord {}
extension TransactionRecord: IdentifiableRecord {}
extension CategoryRecord: IdentifiableRecord {}
extension EarmarkRecord: IdentifiableRecord {}
extension EarmarkBudgetItemRecord: IdentifiableRecord {}
extension InvestmentValueRecord: IdentifiableRecord {}
```

Then constrain `buildCKRecord`:

```swift
func buildCKRecord<T: CloudKitRecordConvertible & IdentifiableRecord>(for record: T) -> CKRecord {
  let recordName = record.id.uuidString
  if let cachedData = systemFieldsCache[recordName],
     let cachedRecord = CKRecord.fromEncodedSystemFields(cachedData) {
    record.applyFields(to: cachedRecord)
    return cachedRecord
  }
  return record.toCKRecord(in: zoneID)
}
```

- [ ] **Step 3: Build and run tests**

```bash
mkdir -p .agent-tmp
just test 2>&1 | tee .agent-tmp/test-output.txt
grep -c 'failed' .agent-tmp/test-output.txt
rm .agent-tmp/test-output.txt
```

- [ ] **Step 4: Run upload benchmarks**

```bash
mkdir -p .agent-tmp
just benchmark SyncUploadBenchmarks 2>&1 | tee .agent-tmp/post-direct-build.txt
grep -E 'measured|values:' .agent-tmp/post-direct-build.txt
rm .agent-tmp/post-direct-build.txt
```

- [ ] **Step 5: Commit**

```bash
git add Backends/CloudKit/Sync/ProfileSyncEngine.swift Backends/CloudKit/Sync/RecordMapping.swift
git commit -m "$(cat <<'EOF'
perf: build CKRecord directly onto cached system fields

When system fields cache exists, applies field values directly to the
cached record instead of creating an intermediate CKRecord and copying.
Adds applyFields(to:) to CloudKitRecordConvertible protocol.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 5: UI Loading — Sidebar

### Task 14: Parallel store loads on sidebar

Currently sequential `await` calls.

**Files:**
- Modify: `App/ContentView.swift:19-23`

- [ ] **Step 1: Change sequential loads to concurrent**

Replace:
```swift
.task {
  await accountStore.load()
  await categoryStore.load()
  await earmarkStore.load()
}
```

With:
```swift
.task {
  async let a: Void = accountStore.load()
  async let c: Void = categoryStore.load()
  async let e: Void = earmarkStore.load()
  _ = await (a, c, e)
}
```

- [ ] **Step 2: Check SidebarView for the same pattern and fix if present**

Check `Features/Navigation/SidebarView.swift` for similar sequential loads and apply the same fix.

- [ ] **Step 3: Build and run tests**

```bash
mkdir -p .agent-tmp
just test 2>&1 | tee .agent-tmp/test-output.txt
grep -c 'failed' .agent-tmp/test-output.txt
rm .agent-tmp/test-output.txt
```

- [ ] **Step 4: Commit**

```bash
git add App/ContentView.swift Features/Navigation/SidebarView.swift
git commit -m "$(cat <<'EOF'
perf: load sidebar stores concurrently instead of sequentially

Uses async let to load accounts, categories, and earmarks in parallel
on app start, reducing total wait time to the slowest single load.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 6: UI Loading — Transaction Fetches

### Task 15: Optimize UUID string comparison in sort

`a.id.uuidString < b.id.uuidString` creates two String allocations per comparison.

**Files:**
- Modify: `Backends/CloudKit/Repositories/CloudKitTransactionRepository.swift:149-152`

- [ ] **Step 1: Replace uuidString comparison with direct UUID comparison**

UUID conforms to `Comparable` (by its `uuid` tuple, which is lexicographic on bytes). Replace:

```swift
filteredRecords.sort { a, b in
  if a.date != b.date { return a.date > b.date }
  return a.id.uuidString < b.id.uuidString
}
```

With:
```swift
filteredRecords.sort { a, b in
  if a.date != b.date { return a.date > b.date }
  return a.id < b.id
}
```

Apply the same fix in the fast path (line ~237-239):
```swift
merged.sort { a, b in
  if a.date != b.date { return a.date > b.date }
  return a.id < b.id
}
```

- [ ] **Step 2: Build and run tests**

```bash
mkdir -p .agent-tmp
just test 2>&1 | tee .agent-tmp/test-output.txt
grep -c 'failed' .agent-tmp/test-output.txt
rm .agent-tmp/test-output.txt
```

- [ ] **Step 3: Run transaction fetch benchmarks**

```bash
mkdir -p .agent-tmp
just benchmark TransactionFetchBenchmarks 2>&1 | tee .agent-tmp/post-uuid-sort.txt
grep -E 'measured|values:' .agent-tmp/post-uuid-sort.txt
rm .agent-tmp/post-uuid-sort.txt
```

- [ ] **Step 4: Commit**

```bash
git add Backends/CloudKit/Repositories/CloudKitTransactionRepository.swift
git commit -m "$(cat <<'EOF'
perf: compare UUID directly instead of via uuidString in sort

UUID conforms to Comparable with byte-level comparison. Removes two
String allocations per comparison in the hot sort path.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 16: Skip redundant post-filters

When filters are already pushed into the predicate, the in-memory re-application is a no-op but still allocates filtered arrays.

**Files:**
- Modify: `Backends/CloudKit/Repositories/CloudKitTransactionRepository.swift:110-145`

- [ ] **Step 1: Track which filters were pushed into predicates**

Add a return type from `buildDescriptor` that indicates which filters were applied:

```swift
private struct DescriptorResult {
  let descriptor: FetchDescriptor<TransactionRecord>
  let pushedScheduled: Bool
  let pushedDateRange: Bool
  let pushedEarmarkId: Bool
}
```

Update `buildDescriptor` to return `DescriptorResult` with flags. Then in the post-filter section, skip filters that were already pushed:

```swift
let result = buildDescriptor(...)
let mergedRecords = try context.fetch(result.descriptor)

var filteredRecords = mergedRecords

if !result.pushedScheduled {
  if scheduled {
    filteredRecords = filteredRecords.filter { $0.recurPeriod != nil }
  } else {
    filteredRecords = filteredRecords.filter { $0.recurPeriod == nil }
  }
}
if !result.pushedDateRange, let dateRange = filter.dateRange {
  let start = dateRange.lowerBound
  let end = dateRange.upperBound
  filteredRecords = filteredRecords.filter { $0.date >= start && $0.date <= end }
}
if !result.pushedEarmarkId, let earmarkId = filter.earmarkId {
  filteredRecords = filteredRecords.filter { $0.earmarkId == earmarkId }
}
// categoryIds and payee are never pushed — always apply
if let categoryIds = filter.categoryIds, !categoryIds.isEmpty {
  filteredRecords = filteredRecords.filter { record in
    guard let categoryId = record.categoryId else { return false }
    return categoryIds.contains(categoryId)
  }
}
if let payee = filter.payee, !payee.isEmpty {
  let lowered = payee.lowercased()
  filteredRecords = filteredRecords.filter { record in
    guard let recordPayee = record.payee else { return false }
    return recordPayee.lowercased().contains(lowered)
  }
}
```

- [ ] **Step 2: Update buildDescriptor to return DescriptorResult**

For each case in the switch, set the pushed flags. For example:

```swift
case (.primary, .some(_), nil, nil) where isNotScheduled:
  let aid = accountId!
  let d = FetchDescriptor<TransactionRecord>(
    predicate: #Predicate {
      $0.accountId == aid && $0.recurPeriod == nil
    },
    sortBy: sortDescriptors
  )
  return DescriptorResult(
    descriptor: d, pushedScheduled: true, pushedDateRange: false, pushedEarmarkId: false)
```

The `default` fallback case returns all flags as `false`.

- [ ] **Step 3: Build and run tests**

```bash
mkdir -p .agent-tmp
just test 2>&1 | tee .agent-tmp/test-output.txt
grep -c 'failed' .agent-tmp/test-output.txt
rm .agent-tmp/test-output.txt
```

- [ ] **Step 4: Run benchmarks**

```bash
mkdir -p .agent-tmp
just benchmark TransactionFetchBenchmarks 2>&1 | tee .agent-tmp/post-skip-filter.txt
grep -E 'measured|values:' .agent-tmp/post-skip-filter.txt
rm .agent-tmp/post-skip-filter.txt
```

- [ ] **Step 5: Commit**

```bash
git add Backends/CloudKit/Repositories/CloudKitTransactionRepository.swift
git commit -m "$(cat <<'EOF'
perf: skip redundant post-filters when predicate already applied

Track which filters were pushed into SwiftData predicates and skip
the corresponding in-memory re-filter pass. Avoids unnecessary
array allocations on the common account+non-scheduled path.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 17: Optimize fetchPayeeSuggestions

Currently loads ALL transactions with non-nil payee.

**Files:**
- Modify: `Backends/CloudKit/Repositories/CloudKitTransactionRepository.swift:688-715`

- [ ] **Step 1: Add fetchLimit and push prefix into predicate if possible**

SwiftData `#Predicate` supports `localizedStandardContains` but not `hasPrefix`. Use a reasonable `fetchLimit` to cap memory usage:

```swift
func fetchPayeeSuggestions(prefix: String) async throws -> [String] {
  let signpostID = OSSignpostID(log: Signposts.repository)
  os_signpost(
    .begin, log: Signposts.repository, name: "TransactionRepo.fetchPayeeSuggestions",
    signpostID: signpostID)
  defer {
    os_signpost(
      .end, log: Signposts.repository, name: "TransactionRepo.fetchPayeeSuggestions",
      signpostID: signpostID)
  }
  guard !prefix.isEmpty else { return [] }

  return try await MainActor.run {
    // Fetch only distinct payees, not full transaction records.
    // Since SwiftData doesn't support DISTINCT, fetch transactions
    // but use a more targeted approach.
    var descriptor = FetchDescriptor<TransactionRecord>(
      predicate: #Predicate { $0.payee != nil },
      sortBy: [SortDescriptor(\TransactionRecord.date, order: .reverse)]
    )
    // Limit to recent transactions — most relevant payees are recent
    descriptor.fetchLimit = 5000
    let records = try context.fetch(descriptor)
    let lowered = prefix.lowercased()

    var counts: [String: Int] = [:]
    for record in records {
      guard let payee = record.payee, !payee.isEmpty,
            payee.lowercased().hasPrefix(lowered) else { continue }
      counts[payee, default: 0] += 1
    }
    return counts.sorted { $0.value > $1.value }.map(\.key)
  }
}
```

- [ ] **Step 2: Build and run tests**

```bash
mkdir -p .agent-tmp
just test 2>&1 | tee .agent-tmp/test-output.txt
grep -c 'failed' .agent-tmp/test-output.txt
rm .agent-tmp/test-output.txt
```

- [ ] **Step 3: Commit**

```bash
git add Backends/CloudKit/Repositories/CloudKitTransactionRepository.swift
git commit -m "$(cat <<'EOF'
perf: cap fetchPayeeSuggestions to 5000 recent transactions

Instead of loading all transactions with payees, limit to the 5000
most recent. Also combines the map+filter into a single loop.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 7: UI Loading — Analysis

### Task 18: Add analysis benchmark

**Files:**
- Create: `MoolahBenchmarks/AnalysisBenchmarks.swift`

- [ ] **Step 1: Write the benchmark**

```swift
import SwiftData
import XCTest

@testable import Moolah

final class AnalysisBenchmarks: XCTestCase {
  nonisolated(unsafe) private static var _backend: CloudKitBackend!
  nonisolated(unsafe) private static var _container: ModelContainer!

  override class func setUp() {
    super.setUp()
    let result = try! TestBackend.create()
    _backend = result.backend
    _container = result.container
    try! awaitSync { @MainActor in
      BenchmarkFixtures.seed(scale: .x2, in: result.container)
    }
  }

  override class func tearDown() {
    _backend = nil
    _container = nil
    super.tearDown()
  }

  private var backend: CloudKitBackend { Self._backend }
  private var container: ModelContainer { Self._container }

  private var metrics: [XCTMetric] { [XCTClockMetric(), XCTMemoryMetric()] }
  private var options: XCTMeasureOptions {
    let opts = XCTMeasureOptions()
    opts.iterationCount = 10
    return opts
  }

  /// Measures full analysis loadAll (balances + breakdown + income/expense).
  func testLoadAll_12months() {
    let repo = backend.analysis as! CloudKitAnalysisRepository
    let historyAfter = Calendar.current.date(byAdding: .month, value: -12, to: Date())!
    let forecastUntil = Calendar.current.date(byAdding: .month, value: 3, to: Date())!

    measure(metrics: metrics, options: options) {
      _ = try! awaitSync {
        try await repo.loadAll(
          historyAfter: historyAfter, forecastUntil: forecastUntil, monthEnd: 28)
      }
    }
  }

  /// Measures full analysis loadAll with "All" history (no date filter).
  func testLoadAll_allHistory() {
    let repo = backend.analysis as! CloudKitAnalysisRepository
    let forecastUntil = Calendar.current.date(byAdding: .month, value: 3, to: Date())!

    measure(metrics: metrics, options: options) {
      _ = try! awaitSync {
        try await repo.loadAll(
          historyAfter: nil, forecastUntil: forecastUntil, monthEnd: 28)
      }
    }
  }

  /// Measures fetchCategoryBalances (used by Reports view, called twice).
  func testFetchCategoryBalances() {
    let repo = backend.analysis as! CloudKitAnalysisRepository
    let end = Date()
    let start = Calendar.current.date(byAdding: .month, value: -12, to: end)!

    measure(metrics: metrics, options: options) {
      _ = try! awaitSync {
        try await repo.fetchCategoryBalances(
          dateRange: start...end, transactionType: .expense, filters: nil)
      }
    }
  }
}
```

- [ ] **Step 2: Regenerate project and run benchmark**

```bash
just generate
mkdir -p .agent-tmp
just benchmark AnalysisBenchmarks 2>&1 | tee .agent-tmp/analysis-baseline.txt
grep -E 'measured|values:' .agent-tmp/analysis-baseline.txt
rm .agent-tmp/analysis-baseline.txt
```

- [ ] **Step 3: Commit**

```bash
git add MoolahBenchmarks/AnalysisBenchmarks.swift
git commit -m "$(cat <<'EOF'
perf: add AnalysisBenchmarks for loadAll and fetchCategoryBalances

Establishes baseline performance for analysis repository operations
at 2x scale (37k transactions).

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 19: Optimize Calendar.current.startOfDay calls in analysis

Called per-transaction in the inner loop. Consecutive transactions on the same day produce the same result.

**Files:**
- Modify: `Backends/CloudKit/Repositories/CloudKitAnalysisRepository.swift:430-455`

- [ ] **Step 1: Cache last day key in computeDailyBalances**

In the static `computeDailyBalances` method, replace:

```swift
for txn in transactions {
  applyTransaction(...)

  let dayKey = Calendar.current.startOfDay(for: txn.date)
  dailyBalances[dayKey] = DailyBalance(...)
}
```

With:

```swift
let calendar = Calendar.current
var lastDate: Date?
var lastDayKey: Date = .distantPast

for txn in transactions {
  applyTransaction(...)

  // Cache day key — consecutive transactions on the same day are common
  let dayKey: Date
  if let lastDate, calendar.isDate(txn.date, inSameDayAs: lastDate) {
    dayKey = lastDayKey
  } else {
    dayKey = calendar.startOfDay(for: txn.date)
    lastDayKey = dayKey
  }
  lastDate = txn.date

  dailyBalances[dayKey] = DailyBalance(...)
}
```

Apply the same pattern in the instance `fetchDailyBalances` method (lines ~135-156) and the priorTransactions loop.

- [ ] **Step 2: Apply same optimization to financialMonth**

In the loops that call `financialMonth(for:monthEnd:)`, cache the last result:

```swift
var lastFinancialDate: Date?
var lastFinancialMonth: String = ""

for txn in transactions {
  let month: String
  if let lastDate = lastFinancialDate, Calendar.current.isDate(txn.date, inSameDayAs: lastDate) {
    month = lastFinancialMonth
  } else {
    month = financialMonth(for: txn.date, monthEnd: monthEnd)
    lastFinancialMonth = month
    lastFinancialDate = txn.date
  }
  // ... use month ...
}
```

Apply this in `computeExpenseBreakdown` and `computeIncomeAndExpense`.

- [ ] **Step 3: Build and run tests**

```bash
mkdir -p .agent-tmp
just test 2>&1 | tee .agent-tmp/test-output.txt
grep -c 'failed' .agent-tmp/test-output.txt
rm .agent-tmp/test-output.txt
```

- [ ] **Step 4: Run analysis benchmarks**

```bash
mkdir -p .agent-tmp
just benchmark AnalysisBenchmarks 2>&1 | tee .agent-tmp/post-calendar-cache.txt
grep -E 'measured|values:' .agent-tmp/post-calendar-cache.txt
rm .agent-tmp/post-calendar-cache.txt
```

- [ ] **Step 5: Commit**

```bash
git add Backends/CloudKit/Repositories/CloudKitAnalysisRepository.swift
git commit -m "$(cat <<'EOF'
perf: cache Calendar.startOfDay and financialMonth in analysis loops

Consecutive transactions on the same day produce identical results.
Cache the last computed day key and financial month to skip repeated
Calendar operations in the hot loop.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 20: Sort once and partition in computeDailyBalances

Currently sorts transactions, then separately sorts prior transactions.

**Files:**
- Modify: `Backends/CloudKit/Repositories/CloudKitAnalysisRepository.swift:392-480`

- [ ] **Step 1: Sort all nonScheduled once, then partition**

Replace the sort-then-filter pattern:

```swift
@concurrent
private static func computeDailyBalances(
  nonScheduled: [Transaction],
  // ... other params
) async throws -> [DailyBalance] {
  let investmentAccountIds = Set(accounts.filter { $0.type == .investment }.map(\.id))

  // Sort once — reuse for both prior and main range
  let allSorted = nonScheduled.sorted(by: { $0.date < $1.date })

  // Partition using binary search if we have a date threshold
  let (priorTransactions, transactions): (ArraySlice<Transaction>, ArraySlice<Transaction>)
  if let after {
    // Binary search for the partition point
    let partitionIndex = allSorted.partitioningIndex(where: { $0.date >= after })
    priorTransactions = allSorted[..<partitionIndex]
    transactions = allSorted[partitionIndex...]
  } else {
    priorTransactions = allSorted[..<allSorted.startIndex]  // empty
    transactions = allSorted[...]
  }

  // Compute daily balances
  var dailyBalances: [Date: DailyBalance] = [:]
  var currentBalance: MonetaryAmount = .zero(currency: currency)
  var currentInvestments: MonetaryAmount = .zero(currency: currency)
  var currentEarmarks: MonetaryAmount = .zero(currency: currency)

  // Apply prior transactions (already sorted)
  for txn in priorTransactions {
    applyTransaction(
      txn,
      to: &currentBalance,
      investments: &currentInvestments,
      earmarks: &currentEarmarks,
      investmentAccountIds: investmentAccountIds
    )
  }

  // Apply main range transactions
  let calendar = Calendar.current
  var lastDate: Date?
  var lastDayKey: Date = .distantPast

  for txn in transactions {
    applyTransaction(
      txn,
      to: &currentBalance,
      investments: &currentInvestments,
      earmarks: &currentEarmarks,
      investmentAccountIds: investmentAccountIds
    )

    let dayKey: Date
    if let lastDate, calendar.isDate(txn.date, inSameDayAs: lastDate) {
      dayKey = lastDayKey
    } else {
      dayKey = calendar.startOfDay(for: txn.date)
      lastDayKey = dayKey
    }
    lastDate = txn.date

    dailyBalances[dayKey] = DailyBalance(
      date: dayKey,
      balance: currentBalance,
      earmarked: currentEarmarks,
      availableFunds: currentBalance - currentEarmarks,
      investments: currentInvestments,
      investmentValue: nil,
      netWorth: currentBalance + currentInvestments,
      bestFit: nil,
      isForecast: false
    )
  }

  // ... rest unchanged (investment values, bestFit, forecast) ...
}
```

Note: `partitioningIndex(where:)` is available in Swift's standard library (from the Algorithms package or Swift 5.7+). If not available, use a simple manual binary search or `firstIndex(where:)`.

- [ ] **Step 2: Build and run tests**

```bash
mkdir -p .agent-tmp
just test 2>&1 | tee .agent-tmp/test-output.txt
grep -c 'failed' .agent-tmp/test-output.txt
rm .agent-tmp/test-output.txt
```

- [ ] **Step 3: Run analysis benchmarks**

```bash
mkdir -p .agent-tmp
just benchmark AnalysisBenchmarks 2>&1 | tee .agent-tmp/post-sort-once.txt
grep -E 'measured|values:' .agent-tmp/post-sort-once.txt
rm .agent-tmp/post-sort-once.txt
```

- [ ] **Step 4: Commit**

```bash
git add Backends/CloudKit/Repositories/CloudKitAnalysisRepository.swift
git commit -m "$(cat <<'EOF'
perf: sort transactions once and partition via binary search

computeDailyBalances was sorting transactions, then separately sorting
prior transactions. Now sorts once and uses partitioningIndex to split
at the date threshold.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 21: Use lightweight projection in analysis instead of full toDomain()

Analysis only needs a subset of Transaction fields. Avoid full domain conversion.

**Files:**
- Modify: `Backends/CloudKit/Repositories/CloudKitAnalysisRepository.swift:70-79`
- Create: lightweight analysis struct

- [ ] **Step 1: Create a lightweight transaction struct for analysis**

Add at the bottom of `CloudKitAnalysisRepository.swift`:

```swift
/// Lightweight projection of TransactionRecord for analysis computation.
/// Avoids the full toDomain() conversion (Currency.from(), etc.).
private struct AnalysisTransaction: Sendable {
  let type: TransactionType
  let date: Date
  let accountId: UUID?
  let toAccountId: UUID?
  let cents: Int
  let categoryId: UUID?
  let earmarkId: UUID?
  let isScheduled: Bool
}
```

- [ ] **Step 2: Replace fetchTransactions with a lightweight fetch**

```swift
private func fetchAnalysisTransactions() async throws -> [AnalysisTransaction] {
  let descriptor = FetchDescriptor<TransactionRecord>()
  return try await MainActor.run {
    let records = try context.fetch(descriptor)
    return records.map { r in
      AnalysisTransaction(
        type: TransactionType(rawValue: r.type) ?? .expense,
        date: r.date,
        accountId: r.accountId,
        toAccountId: r.toAccountId,
        cents: r.amount,
        categoryId: r.categoryId,
        earmarkId: r.earmarkId,
        isScheduled: r.recurPeriod != nil
      )
    }
  }
}
```

- [ ] **Step 3: Update loadAll and compute methods to use AnalysisTransaction**

Update `loadAll` to call `fetchAnalysisTransactions()` instead of `fetchTransactions()`:

```swift
func loadAll(...) async throws -> AnalysisData {
  let allTransactions = try await fetchAnalysisTransactions()
  let accounts = try await fetchAccounts()

  let nonScheduled = allTransactions.filter { !$0.isScheduled }
  let scheduled = allTransactions.filter { $0.isScheduled }
  // ...
}
```

Update `computeDailyBalances`, `computeExpenseBreakdown`, and `computeIncomeAndExpense` signatures to accept `[AnalysisTransaction]` instead of `[Transaction]`.

Update `applyTransaction` to work with `AnalysisTransaction` — it only needs `type`, `accountId`, `toAccountId`, `cents`, and `earmarkId`.

Update the `MonetaryAmount` operations to work directly with cents in the inner loops:

```swift
private static func applyAnalysisTransaction(
  _ txn: AnalysisTransaction,
  to balance: inout Int,
  investments: inout Int,
  earmarks: inout Int,
  investmentAccountIds: Set<UUID>
) {
  let isFromInvestment = txn.accountId.map { investmentAccountIds.contains($0) } ?? false
  let isToInvestment = txn.toAccountId.map { investmentAccountIds.contains($0) } ?? false

  switch txn.type {
  case .income, .expense, .openingBalance:
    if txn.accountId != nil {
      balance += txn.cents
    }
    if txn.earmarkId != nil {
      earmarks += txn.cents
    }
  case .transfer:
    if isFromInvestment && !isToInvestment {
      balance -= txn.cents
      investments += txn.cents
    } else if !isFromInvestment && isToInvestment {
      balance += txn.cents
      investments -= txn.cents
    }
  }
}
```

This avoids `MonetaryAmount` allocation in the hot loop — accumulate raw cents, convert to `MonetaryAmount` once at the end.

- [ ] **Step 4: Build and run tests**

```bash
mkdir -p .agent-tmp
just test 2>&1 | tee .agent-tmp/test-output.txt
grep -c 'failed' .agent-tmp/test-output.txt
rm .agent-tmp/test-output.txt
```

- [ ] **Step 5: Run analysis benchmarks**

```bash
mkdir -p .agent-tmp
just benchmark AnalysisBenchmarks 2>&1 | tee .agent-tmp/post-lightweight.txt
grep -E 'measured|values:' .agent-tmp/post-lightweight.txt
rm .agent-tmp/post-lightweight.txt
```

- [ ] **Step 6: Commit**

```bash
git add Backends/CloudKit/Repositories/CloudKitAnalysisRepository.swift
git commit -m "$(cat <<'EOF'
perf: use lightweight projection in analysis instead of full toDomain()

Replaces Transaction domain objects with AnalysisTransaction struct
that skips Currency.from() and MonetaryAmount allocation. Inner loops
accumulate raw cents and convert once at the end.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 22: Combine duplicate fetchCategoryBalances calls in Reports

Reports view calls `fetchCategoryBalances` twice — once for income, once for expense — each loading ALL transactions.

**Files:**
- Modify: `Backends/CloudKit/Repositories/CloudKitAnalysisRepository.swift:348-388`
- Modify: `Domain/Repositories/AnalysisRepository.swift` (add new method to protocol)

- [ ] **Step 1: Add combined method to AnalysisRepository protocol**

Check the protocol file and add:

```swift
func fetchCategoryBalancesByType(
  dateRange: ClosedRange<Date>,
  filters: TransactionFilter?
) async throws -> (income: [UUID: MonetaryAmount], expense: [UUID: MonetaryAmount])
```

- [ ] **Step 2: Implement in CloudKitAnalysisRepository**

```swift
func fetchCategoryBalancesByType(
  dateRange: ClosedRange<Date>,
  filters: TransactionFilter?
) async throws -> (income: [UUID: MonetaryAmount], expense: [UUID: MonetaryAmount]) {
  let allTransactions = try await fetchAnalysisTransactions()
  let currency = self.currency

  let filtered = allTransactions.filter { tx in
    guard dateRange.contains(tx.date) else { return false }
    guard tx.categoryId != nil else { return false }
    guard !tx.isScheduled else { return false }

    if let accountId = filters?.accountId, tx.accountId != accountId { return false }
    if let earmarkId = filters?.earmarkId, tx.earmarkId != earmarkId { return false }
    if let categoryIds = filters?.categoryIds, !categoryIds.contains(tx.categoryId!) { return false }
    return true
  }

  var income: [UUID: Int] = [:]
  var expense: [UUID: Int] = [:]
  for tx in filtered {
    let categoryId = tx.categoryId!
    switch tx.type {
    case .income, .openingBalance:
      income[categoryId, default: 0] += tx.cents
    case .expense:
      expense[categoryId, default: 0] += tx.cents
    case .transfer:
      break
    }
  }

  return (
    income: income.mapValues { MonetaryAmount(cents: $0, currency: currency) },
    expense: expense.mapValues { MonetaryAmount(cents: $0, currency: currency) }
  )
}
```

- [ ] **Step 3: Update ReportsView to use the combined method**

Find the ReportsView file and replace the two separate calls with a single combined call.

- [ ] **Step 4: Implement the method in RemoteAnalysisRepository**

Check if RemoteAnalysisRepository (for remote backend) also needs this method. It may just call the two individual methods if the server has separate endpoints.

- [ ] **Step 5: Build and run tests**

```bash
mkdir -p .agent-tmp
just test 2>&1 | tee .agent-tmp/test-output.txt
grep -c 'failed' .agent-tmp/test-output.txt
rm .agent-tmp/test-output.txt
```

- [ ] **Step 6: Run analysis benchmarks**

```bash
mkdir -p .agent-tmp
just benchmark AnalysisBenchmarks/testFetchCategoryBalances 2>&1 | tee .agent-tmp/post-combined-catbal.txt
grep -E 'measured|values:' .agent-tmp/post-combined-catbal.txt
rm .agent-tmp/post-combined-catbal.txt
```

- [ ] **Step 7: Commit**

```bash
git add Backends/CloudKit/Repositories/CloudKitAnalysisRepository.swift Domain/Repositories/AnalysisRepository.swift Features/Reports/
git commit -m "$(cat <<'EOF'
perf: combine income/expense category balance fetches into single pass

Reports view was calling fetchCategoryBalances twice (income + expense),
each loading all transactions. New fetchCategoryBalancesByType does a
single fetch and splits by type in one pass.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 8: Final Verification

### Task 23: Run full benchmark suite and compare against baselines

- [ ] **Step 1: Run all benchmarks**

```bash
mkdir -p .agent-tmp
just benchmark 2>&1 | tee .agent-tmp/final-benchmarks.txt
grep -E 'measured|values:' .agent-tmp/final-benchmarks.txt > .agent-tmp/final-summary.txt
```

- [ ] **Step 2: Compare against initial baselines**

```bash
diff .agent-tmp/baseline-summary.txt .agent-tmp/final-summary.txt
```

- [ ] **Step 3: Run full test suite**

```bash
just test 2>&1 | tee .agent-tmp/test-output.txt
grep -c 'failed' .agent-tmp/test-output.txt
rm .agent-tmp/test-output.txt
```

- [ ] **Step 4: Check for compiler warnings**

Use `mcp__xcode__XcodeListNavigatorIssues` with `severity: "warning"` or:

```bash
just build-mac 2>&1 | grep -i 'warning:'
```

Fix any warnings.

- [ ] **Step 5: Clean up temp files**

```bash
rm -f .agent-tmp/baseline-summary.txt .agent-tmp/final-summary.txt .agent-tmp/final-benchmarks.txt
```

- [ ] **Step 6: Update caching-opportunities.md with any new findings**

During optimization work, note any additional caching opportunities discovered and add them to `plans/caching-opportunities.md`.

---

## File Map

### New files
| File | Purpose |
|------|---------|
| `MoolahBenchmarks/SyncDownloadBenchmarks.swift` | Benchmark for applyRemoteChanges |
| `MoolahBenchmarks/SyncUploadBenchmarks.swift` | Benchmark for buildBatchRecordLookup |
| `MoolahBenchmarks/AnalysisBenchmarks.swift` | Benchmark for analysis loadAll |
| `MoolahTests/Domain/CurrencyTests.swift` | Tests for Currency.from() caching |

### Modified files
| File | Changes |
|------|---------|
| `Backends/CloudKit/Models/TransactionRecord.swift` | Add #Index |
| `Backends/CloudKit/Models/AccountRecord.swift` | Add #Index |
| `Backends/CloudKit/Models/CategoryRecord.swift` | Add #Index |
| `Backends/CloudKit/Models/EarmarkRecord.swift` | Add #Index |
| `Backends/CloudKit/Models/EarmarkBudgetItemRecord.swift` | Add #Index |
| `Backends/CloudKit/Models/InvestmentValueRecord.swift` | Add #Index |
| `Backends/CloudKit/Sync/ProfileSyncEngine.swift` | Batch deletes, targeted invalidation, debounced cache writes, off-main parsing, batch upload lookup, selective reload callback |
| `Backends/CloudKit/Sync/RecordMapping.swift` | Add applyFields(to:), IdentifiableRecord protocol |
| `App/ProfileSession.swift` | Selective + adaptive sync reload debounce |
| `App/ContentView.swift` | Parallel store loads |
| `Backends/CloudKit/Repositories/CloudKitTransactionRepository.swift` | UUID sort, skip redundant post-filters, payee suggestions cap |
| `Backends/CloudKit/Repositories/CloudKitAnalysisRepository.swift` | Calendar caching, sort-once, lightweight projections, combined category balances |
| `Domain/Models/Currency.swift` | Static cache for from() |
| `Domain/Repositories/AnalysisRepository.swift` | Add fetchCategoryBalancesByType |
