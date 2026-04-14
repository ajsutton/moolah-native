# Benchmarking & Performance Instrumentation Design

**Date:** 2026-04-13
**Status:** Partially implemented. Signposts enum created, benchmark target with 8 benchmark files operational, `just benchmark` command works. Remaining: baseline capture documentation, CI regression detection integration.

## Problem

With ~18,600 transactions in the iCloud profile, UI performance is jittery during sync operations (upload and download of large record batches). We have no performance measurements, no way to identify what's slow, and no way to detect regressions.

## Goals

1. **Identify bottlenecks** — repeatable benchmarks that measure the key data operations at realistic scale, giving concrete numbers to guide optimization.
2. **Enable profiling** — os_signpost instrumentation in production code so Instruments traces show exactly where time is spent.
3. **Prevent regressions** — benchmarks that can be run on demand to verify performance hasn't degraded after changes.

## Real-World Data Profile

From the live iCloud profile (profile ID `26F879B7`):

| Record Type | Current Count | 2x Target |
|---|---|---|
| Transactions | 18,662 | 37,000 |
| Accounts | 31 | 60 |
| Categories | 158 | 320 |
| Earmarks | 21 | 42 |
| Budget Items | 14 | 28 |
| Investment Values | 2,711 | 5,400 |

Transaction distribution is heavily skewed: the top 3 accounts hold ~85% of transactions. Only 38 of 18,662 are scheduled.

## Benchmark Infrastructure

### Test Target

A new `MoolahBenchmarks_macOS` target in `project.yml` with scheme `Moolah-Benchmarks`. macOS-only to avoid simulator overhead and get consistent timing. Run via `just benchmark`.

The target sources from `MoolahBenchmarks/` and depends on `Moolah_macOS` (same pattern as `MoolahTests_macOS`).

### Data Seeding

`BenchmarkFixtures` generates realistic datasets using the existing `TestBackend` (in-memory SwiftData). Two scale tiers:

- **1x** — matches current real data (18k transactions, 31 accounts, 158 categories, 2.7k investment values)
- **2x** — double the current data (37k transactions, 60 accounts, 320 categories, 5.4k investment values)

The fixture preserves the real-world distribution:
- ~85% of transactions concentrated in the top 3 accounts
- Mix of transaction types (expense dominant, some income, some transfers)
- Realistic payee and category distribution
- Only ~0.2% scheduled transactions
- Date range spanning several years

### Test Pattern

Each benchmark uses `measure(metrics:options:)` with `XCTClockMetric` and `XCTMemoryMetric`, 10 iterations. Data is seeded once in `setUpWithError()` per class. Between measure iterations, `ModelContext` is reset to prevent SwiftData tracking accumulation from skewing results.

## What We Benchmark

### 1. Transaction Fetch

The most common operation — powers the transaction list view. All fetches run through `CloudKitTransactionRepository.fetch()`.

- **By account** (common case): fetch page 0 for the busiest account (~7k transactions matching)
- **All non-scheduled** (default filter): fetch with no account filter, scheduled=false
- **With date range**: fetch one year of transactions
- **With category filter** (in-memory post-filter path): filter by a set of category IDs
- **Deep pagination**: fetch page 0 vs page 10 to measure offset cost
- **All sizes**: each filter at 1x and 2x to observe scaling behavior

### 2. Batch Upsert (Sync Download)

Simulates receiving remote changes via `ProfileSyncEngine.applyBatchSaves`. Tests:

- **Insert-heavy**: 400 new records into an existing 18k/37k dataset (first sync scenario)
- **Update-heavy**: 400 records that already exist locally (subsequent sync scenario)
- **Mixed batch**: realistic mix of inserts and updates
- **Balance invalidation**: the `invalidateCachedBalances` call that follows transaction sync

### 3. Batch Record Lookup (Sync Upload)

Measures the record lookup phase of sync upload. `buildBatchRecordLookup` and `applyBatchSaves` are private, so benchmarks exercise them indirectly: for upload, by calling `nextRecordZoneChangeBatch` with queued pending changes; for download, by calling `applyRemoteChanges` with constructed CKRecord batches. Tests batch sizes of 100 and 400 against the full dataset.

Note: If indirect testing proves too noisy or hard to isolate, we can change these methods from `private` to `internal` (visible to the test target via `@testable import`). Decide based on the first benchmark run.

### 4. Balance Computation & Account Fetch After Sync

Two related paths:

- **priorBalance reduction** — the `filteredRecords[end...].reduce()` in `fetch()` that sums all transactions after the current page. Measured by fetching page 0 for an account with ~7k transactions.
- **Account fetchAll with invalidated caches** — `AccountRepository.fetchAll()` when all `cachedBalance` values are nil (the post-sync path). This triggers a full transaction sum per account across the entire dataset.

### 5. toDomain Conversion

Bulk `TransactionRecord.toDomain()` over 1000 and 5000 records. This isolates the per-record conversion cost, including `Currency.from(code:)` which creates a `NumberFormatter` on every call.

## Signpost Instrumentation

### Categories

All signposts use subsystem `"com.moolah.app"` (matching existing Logger usage). Three OSLog categories:

- `"Repository"` — fetch, create, update, delete operations on all repositories
- `"Sync"` — sync engine events, batch upserts, record lookups
- `"Balance"` — balance computation and cache invalidation

Defined as static properties on a `Signposts` enum in `Shared/Signposts.swift`.

### Coarse Signposts

One begin/end pair around each public method:

**Repository methods:**
- `TransactionRepository`: `fetch`, `create`, `update`, `delete`, `fetchPayeeSuggestions`
- `AccountRepository`: `fetchAll`, `create`, `update`, `delete`
- `CategoryRepository`: `fetchAll`, `create`, `update`, `delete`
- `EarmarkRepository`: `fetchAll`, `create`, `update`, `delete`

**Sync engine methods:**
- `applyRemoteChanges`
- `nextRecordZoneChangeBatch`
- `queueAllExistingRecords`
- `sendChanges`
- `fetchChanges`

### Fine-Grained Signposts

Inside the hot paths, mark sub-steps:

**`TransactionRepository.fetch()`:**
- Predicate fetch (primary + secondary queries)
- In-memory post-filtering
- Sort
- toDomain conversion
- priorBalance reduction

**`ProfileSyncEngine.applyBatchSaves()`:**
- Per-type batch upsert (with record count in signpost metadata)
- System fields cache write

**`ProfileSyncEngine.applyRemoteChanges()`:**
- Balance invalidation
- Context save

**`ProfileSyncEngine.buildBatchRecordLookup()`:**
- Full loop (with batch size in metadata)

### Implementation

Signposts are added inline using `os_signpost(.begin)` / `os_signpost(.end)` calls. No wrapper types. The `Signposts` enum provides the `OSLog` instances:

```swift
enum Signposts {
  static let repository = OSLog(subsystem: "com.moolah.app", category: "Repository")
  static let sync = OSLog(subsystem: "com.moolah.app", category: "Sync")
  static let balance = OSLog(subsystem: "com.moolah.app", category: "Balance")
}
```

## File Changes

### New Files

| File | Purpose |
|---|---|
| `MoolahBenchmarks/Support/BenchmarkFixtures.swift` | Data seeding at 1x/2x scale |
| `MoolahBenchmarks/TransactionFetchBenchmarks.swift` | Fetch operation benchmarks |
| `MoolahBenchmarks/SyncBatchBenchmarks.swift` | Batch upsert and upload benchmarks |
| `MoolahBenchmarks/BalanceBenchmarks.swift` | Balance computation and account fetch benchmarks |
| `MoolahBenchmarks/ConversionBenchmarks.swift` | toDomain conversion benchmarks |
| `Shared/Signposts.swift` | OSLog instances for signpost categories |
| `guides/BENCHMARKING_GUIDE.md` | Style guide for writing and interpreting benchmarks |
| `.claude/skills/write-benchmark/SKILL.md` | Skill for writing new benchmarks |
| `.claude/skills/interpret-benchmarks/SKILL.md` | Skill for interpreting benchmark results |

### Modified Files

| File | Change |
|---|---|
| `project.yml` | Add `MoolahBenchmarks_macOS` target and `Moolah-Benchmarks` scheme |
| `justfile` | Add `benchmark` target |
| `Backends/CloudKit/Repositories/CloudKitTransactionRepository.swift` | Coarse + fine signposts |
| `Backends/CloudKit/Repositories/CloudKitAccountRepository.swift` | Coarse signposts |
| `Backends/CloudKit/Repositories/CloudKitCategoryRepository.swift` | Coarse signposts |
| `Backends/CloudKit/Repositories/CloudKitEarmarkRepository.swift` | Coarse signposts |
| `Backends/CloudKit/Sync/ProfileSyncEngine.swift` | Coarse + fine signposts |

### Not Changed

- Existing test targets — benchmarks are fully separate
- Domain layer — signposts only go in backend/sync code
- No new dependencies — uses XCTest `measure()` and `os_signpost` from the OS
