# Performance Optimization Design

**Status:** Partially implemented. Sync download optimizations (isFetchingChanges flag, targeted balance invalidation, debouncing) and signpost instrumentation are done. Upload optimizations, SQL-level balance aggregation, and full caching layer remain.

## Goal

Optimize iCloud sync upload/download so the UI stays completely responsive during large profile migrations (20k+ records syncing at once). Then optimize sidebar, transaction list, and analysis page loading. Track caching opportunities separately without implementing them.

## Method

Benchmark-first: baseline measurement, implement fix, verify improvement, commit. Each fix gets before/after numbers.

## Phase 1: Sync Download (Highest Priority)

These run on the main thread when CKSyncEngine delivers batches. Every millisecond here causes UI jitter.

### 1.1 Move CKRecord parsing off MainActor

**File:** `ProfileSyncEngine.swift` — `applyRemoteChanges()`

Currently the entire method runs on MainActor. The CKRecord field extraction (`fieldValues(from:)`) and system fields encoding are pure data transforms with no SwiftData dependency. Extract CKRecord data into plain structs off-main, then apply to SwiftData on-main.

### 1.2 Debounce system fields cache writes

**File:** `ProfileSyncEngine.swift` — `saveSystemFieldsCache()`

Called after every download batch AND every upload batch. During large sync this means hundreds of disk writes. Debounce to write at most once per second, with a flush on engine stop.

### 1.3 Targeted balance invalidation

**File:** `ProfileSyncEngine.swift` — `invalidateCachedBalances()`

Currently fetches ALL accounts and sets `cachedBalance = nil` on each. Instead, extract the set of accountIds from incoming transaction CKRecords and only invalidate those specific accounts.

### 1.4 Batch deletions

**File:** `ProfileSyncEngine.swift` — `applyBatchDeletions()`

Currently does individual fetch+delete per record (one query per deletion). Group by type and batch-fetch using `IN` predicate, same pattern as upserts.

### 1.5 Reduce system fields encoding overhead

**File:** `ProfileSyncEngine.swift` — `applyRemoteChanges()` line 287

`CKRecord.encodedSystemFields` uses NSKeyedArchiver per record. For 400 records that's 400 archive operations blocking the main thread. Move this off-main as part of 1.1.

### 1.6 Increase sync reload debounce during bulk sync

**File:** `ProfileSession.swift` — `scheduleReloadFromSync()`

500ms debounce means ~2 full store reloads per second during large sync. Detect bulk sync (e.g., consecutive batches within a window) and increase debounce to 2-3 seconds. Reset to 500ms after sync settles.

### 1.7 Selective store reloads

**File:** `ProfileSession.swift` — `scheduleReloadFromSync()`

Currently reloads accounts, categories, and earmarks on every sync event regardless of what changed. Pass the set of changed record types from the sync engine so only affected stores reload.

### 1.8 Benchmark: sync batch upsert with indexes

Existing `SyncBatchBenchmarks` measures upsert performance. After adding SwiftData indexes (see 4.1), re-benchmark to quantify the improvement on the `incomingIds.contains($0.id)` predicate.

## Phase 2: Sync Upload

These run when queuing and sending local changes to CloudKit.

### 2.1 Batch-fetch in buildBatchRecordLookup

**File:** `ProfileSyncEngine.swift` — `buildBatchRecordLookup()`

Currently does per-UUID sequential queries (up to 2400 queries for 400 records). Instead, fetch all UUIDs per type using `IN` predicates (6 queries total). The download path already does this — mirror that pattern.

### 2.2 Use fetchCount/ID-only fetch in queueAllExistingRecords

**File:** `ProfileSyncEngine.swift` — `queueAllExistingRecords()`

Currently loads full records just to get `.id`. Use a FetchDescriptor with `propertiesToFetch` limited to `id`, or use `fetchIdentifiers` if available, to avoid hydrating full objects.

### 2.3 Build CKRecord directly onto cached system fields

**File:** `ProfileSyncEngine.swift` — `buildCKRecord()`

Currently `toCKRecord()` allocates a fresh CKRecord, then `applySystemFieldsCache()` may discard it and copy fields onto a cached record. When cache exists, build directly onto the cached record without the intermediate allocation.

### 2.4 Debounce system fields cache writes (upload side)

Same fix as 1.2, applied to `handleSentRecordZoneChanges()`. The debounce mechanism from 1.2 covers both paths since they share `saveSystemFieldsCache()`.

### 2.5 Benchmark: initial upload of 20k records

Add a benchmark that simulates `queueAllExistingRecords` + `nextRecordZoneChangeBatch` for a full 2x dataset to measure the upload preparation path.

## Phase 3: UI Loading — Transaction Fetches

### 3.1 SwiftData indexes on hot columns

**File:** `project.yml` or model declarations

Add indexes on: `TransactionRecord.accountId`, `TransactionRecord.date`, `TransactionRecord.toAccountId`, `TransactionRecord.recurPeriod`, `TransactionRecord.categoryId`, `TransactionRecord.earmarkId`, `AccountRecord.id`, `CategoryRecord.id`, `EarmarkRecord.id`, `InvestmentValueRecord.accountId`.

This is the single highest-impact change for query performance across the entire app.

### 3.2 Push fetchLimit into full-path transaction fetch

**File:** `CloudKitTransactionRepository.swift` — `fetch()`

The full path loads ALL matching records, sorts in memory, then paginates. For page 0 with no complex filters, push `fetchLimit` and sort into the FetchDescriptor so SQLite handles pagination.

### 3.3 Push category filter into predicate where possible

**File:** `CloudKitTransactionRepository.swift`

Category filter is always applied in-memory post-fetch. For single-category filters, this can be pushed into the predicate. Multi-category `IN` filters may also work with SwiftData.

### 3.4 Optimize fetchPayeeSuggestions

**File:** `CloudKitTransactionRepository.swift` — `fetchPayeeSuggestions()`

Currently loads all transactions with non-nil payee. Add a `fetchLimit` and push the prefix match into the predicate if SwiftData supports `BEGINSWITH`. At minimum, use a projection to fetch only the `payee` field.

### 3.5 Benchmark: transaction fetch with indexes vs without

Add benchmark variants that measure the impact of indexes on the common account+non-scheduled filter path.

## Phase 4: UI Loading — Analysis

### 4.1 Avoid redundant toDomain() in analysis

**File:** `CloudKitAnalysisRepository.swift` — `fetchTransactions()`

`toDomain()` creates a full `Transaction` domain object including `Currency.from()` string lookup per record. Analysis only needs a subset of fields (date, amount, type, accountId, categoryId, earmarkId). Use a lightweight projection struct instead.

### 4.2 Sort once, reuse

**File:** `CloudKitAnalysisRepository.swift` — `computeDailyBalances()`

Currently sorts `nonScheduled` transactions, then separately sorts `priorTransactions`. Sort once and partition using binary search on the date threshold.

### 4.3 Precompute financialMonth date thresholds

**File:** `CloudKitAnalysisRepository.swift` — `financialMonth()`

Called per-transaction in expense breakdown and income/expense loops. `Calendar.current.component()` is expensive. Precompute month boundaries and use binary search.

### 4.4 Reduce Calendar.current.startOfDay calls

**File:** `CloudKitAnalysisRepository.swift` — `computeDailyBalances()`

`startOfDay(for:)` called per transaction. Since transactions are sorted by date, consecutive transactions on the same day produce the same key. Cache the last computed day key and skip recomputation when the date hasn't changed.

### 4.5 Optimize fetchCategoryBalances

**File:** `CloudKitAnalysisRepository.swift` — `fetchCategoryBalances()`

Reports view calls this twice (income + expense), each loading ALL transactions. Combine into a single fetch that computes both simultaneously, or at minimum share the fetched data.

### 4.6 Benchmark: analysis loadAll at 2x scale

Add benchmark for `AnalysisRepository.loadAll()` measuring end-to-end time including fetch, conversion, and computation.

## Phase 5: UI Loading — Sidebar & Stores

### 5.1 Parallel store loads on sidebar

**File:** `ContentView.swift` / `SidebarView.swift`

Currently loads accounts, categories, earmarks sequentially with `await`. Use `async let` to load all three concurrently.

### 5.2 Optimize account balance recomputation

**File:** `CloudKitAccountRepository.swift` — `fetchAll()`

When `cachedBalance` is nil (post-sync), recomputation sums all transactions per account. With indexes on `accountId`, this becomes efficient. Additionally, recompute only for accounts whose balances were invalidated (ties into 1.3).

### 5.3 Benchmark: sidebar initial load at 2x scale

Add benchmark measuring `AccountRepository.fetchAll()` with and without cached balances.

## Phase 6: Additional Optimizations

Smaller wins to pursue after the high-impact fixes.

### 6.1 Currency.from() lookup optimization

If `Currency.from()` does string matching, replace with a static dictionary lookup.

### 6.2 UUID string comparison in sort

**File:** `CloudKitTransactionRepository.swift` — line 152

`a.id.uuidString < b.id.uuidString` creates two String allocations per comparison. Compare UUID bytes directly.

### 6.3 Reduce MonetaryAmount allocation pressure

In tight loops (analysis computation), MonetaryAmount `+=` creates new instances. Use `inout` mutation or accumulate raw cents and convert once.

### 6.4 Batch context.insert for large sync

When inserting many records in a single batch, SwiftData may perform better with explicit batch insert APIs if available, vs individual `context.insert()` calls.

### 6.5 Avoid redundant predicate evaluation in post-filter

**File:** `CloudKitTransactionRepository.swift` — lines 119-145

Post-filters re-apply scheduled/dateRange/earmarkId even when already pushed into the predicate. Track which filters were pushed and skip redundant checks.

### 6.6 Optimize TransactionRecord.toDomain()

Profile `toDomain()` to identify hot spots. Common candidates: Currency.from(), TransactionType(rawValue:), RecurPeriod(rawValue:).

## Caching Opportunities (Track, Don't Implement)

These are documented in `plans/caching-opportunities.md` for later investigation:

- Category tree: cache the flattened/path-computed structure, invalidate on mutation
- Payee frequency map: precomputed payee→count for suggestions
- Analysis data: cache per time-range, invalidate on transaction mutation
- Account balances: more granular invalidation (per-account, not all)
- Transaction page cache: cache recent pages, invalidate on mutation
- Financial month boundaries: precompute for the relevant date range
- Investment values: cache aggregated daily values per account

## Benchmark Plan

New benchmarks to add:
1. `SyncDownloadBenchmarks` — `applyRemoteChanges()` with 400 inserts, 400 updates, 400 mixed
2. `SyncUploadBenchmarks` — `buildBatchRecordLookup()` for 400 UUIDs, `queueAllExistingRecords()` at 2x
3. `AnalysisBenchmarks` — `loadAll()` at 1x and 2x scale
4. `SidebarBenchmarks` — `AccountRepository.fetchAll()` with/without cached balances
5. `TransactionFetchBenchmarks` — additional variants with indexes

Existing benchmarks to re-run as baselines before any changes:
- `TransactionFetchBenchmarks` (5 tests)
- `BalanceBenchmarks` (2 tests)
- `SyncBatchBenchmarks` (3 tests)
- `ConversionBenchmarks` (2 tests)

## Success Criteria

- No visible UI jitter during sync of 20k+ records (measured via Instruments signposts)
- Sync download batch processing time under 50ms per 400-record batch
- Sidebar loads in under 100ms at 2x scale
- Transaction list first page loads in under 50ms at 2x scale
- Analysis page loads in under 500ms at 2x scale

## Out of Scope

- Caching implementations (tracked separately)
- CloudKit API-level optimizations (batch size, zone configuration)
- Network-layer optimizations (these are Apple's responsibility)
- UI rendering optimizations (SwiftUI List performance, lazy loading)
