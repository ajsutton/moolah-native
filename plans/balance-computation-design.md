# Balance Computation Performance — Design Options

**Status:** Partially implemented. Option A (fix sync reload cycle) is done — `isFetchingChanges` flag defers balance invalidation during active sync, with a single reload on completion. Option B (SQL-level aggregation) and Option C (incremental delta) are not implemented.

**Problem:** Opening an iCloud profile makes the app unresponsive. During initial CloudKit sync, every batch of 200 records triggers `recomputeAllBalances()` which fetches ALL transactions from SwiftData and iterates them on the main thread. As transactions accumulate during sync, this becomes progressively slower (O(batches x total_transactions)), blocking the main actor and preventing CKSyncEngine from delivering the next batch.

**Root cause chain:**
1. Sync batch arrives → `applyRemoteChanges` runs on `@MainActor`
2. Transaction records in batch → `invalidateCachedBalances` sets `cachedBalance = nil`
3. Debounce fires → `accountStore.reloadFromSync()` → `fetchAll()` → sees nil caches → `recomputeAllBalances()`
4. `recomputeAllBalances` fetches ALL `TransactionRecord` rows, iterates in Swift, saves
5. Main thread blocked for duration → CKSyncEngine's next batch blocked waiting for main actor
6. Repeat every ~30 seconds, each iteration slower than the last

**Three independent improvements** that can be combined:

## Option A: Fix the Sync Reload Cycle

**Effort:** Small. **Impact:** Eliminates the immediate unresponsiveness.

Stop invalidating and recomputing balances after every sync batch. Instead, defer to the end of the sync session.

### Approach

1. **Track sync-in-progress state** in `ProfileSyncEngine`. Set a flag on `.willFetchChanges`, clear it on `.didFetchChanges`. These events are already received but currently ignored (`ProfileSyncEngine.swift:793`).

2. **Skip balance invalidation during active fetch.** In `applyRemoteChanges`, don't call `invalidateCachedBalances` while `isFetchingChanges` is true. Instead, accumulate affected account IDs.

3. **On `.didFetchChanges`, do one invalidation + one reload.** Fire `onRemoteChangesApplied` once with the full accumulated set of changed types.

4. **Increase debounce detection window.** The current `isBulkSync` threshold of 1 second (`ProfileSession.swift:172`) is too tight — CKSyncEngine batches arrive ~30 seconds apart during initial sync. Either:
   - Use the `isFetchingChanges` flag from the engine (preferred — semantic, not heuristic)
   - Or widen to 60 seconds

### Files to change

- `Backends/CloudKit/Sync/ProfileSyncEngine.swift` — add `isFetchingChanges` flag, handle `.willFetchChanges`/`.didFetchChanges`, defer invalidation
- `App/ProfileSession.swift` — accept a signal that sync is complete vs. mid-stream

### Testing

- Unit test: `ProfileSyncEngine` with multiple batches verifies `onRemoteChangesApplied` fires once after `didFetchChanges`, not per batch.
- Unit test: `cachedBalance` remains non-nil between batches during active sync.
- Integration test: `AccountStore.reloadFromSync()` called once after sync completes, not per batch.

---

## Option B: SQL-Level Balance Aggregation via Core Data

**Effort:** Medium. **Impact:** Reduces balance computation from O(N) in-Swift iteration to a single SQL `SUM()` query regardless of transaction count.

### Why Core Data

SwiftData has no aggregate query support. `#Expression` (iOS 18+) only supports filtering and `.count` on to-many relationships — no SUM, AVG, MIN, MAX, GROUP BY. The community consensus and Apple's own examples confirm this gap exists through iOS 26.

The approach: open a **parallel, read-only Core Data stack** against the same SQLite file that SwiftData writes to. This is App Store safe — Apple explicitly documents Core Data + SwiftData coexistence (WWDC 2023 session "Migrate to SwiftData").

### Architecture

```
┌─────────────────────────────┐     ┌──────────────────────────┐
│  SwiftData ModelContainer   │     │  Core Data (read-only)   │
│  - All reads/writes as now  │     │  - Aggregate queries     │
│  - Owns the SQLite file     │────▶│  - SUM, GROUP BY         │
│                             │     │  - No object hydration   │
└─────────────────────────────┘     └──────────────────────────┘
         writes to                     reads from
              ╲                          ╱
               ╲                        ╱
            ┌──────────────────────────┐
            │  SQLite file             │
            │  Moolah-{profileId}.store│
            └──────────────────────────┘
```

### Implementation: `AggregateQueryService`

A small service that wraps a read-only `NSPersistentStoreCoordinator` and provides typed aggregate queries.

```swift
/// Executes SQL-level aggregate queries against the SwiftData store.
/// Uses a read-only Core Data stack pointing at the same SQLite file.
/// NOT @MainActor — can run aggregates off the main thread.
final class AggregateQueryService: Sendable {
    private let coordinator: NSPersistentStoreCoordinator
    
    init(storeURL: URL) throws { ... }
    
    /// Returns per-account balance sums in a single SQL query.
    /// Equivalent to:
    ///   SELECT accountId, SUM(amount) FROM TransactionRecord
    ///   WHERE recurPeriod IS NULL GROUP BY accountId
    /// Plus the toAccountId side for transfers.
    func computeAccountBalances() throws -> [UUID: Int] { ... }
}
```

The query plan for `computeAccountBalances`:
1. Fetch source-side sums: `SELECT accountId, SUM(amount) FROM TransactionRecord WHERE recurPeriod IS NULL GROUP BY accountId` — returns `[UUID: Int]`
2. Fetch dest-side sums: `SELECT toAccountId, SUM(amount) FROM TransactionRecord WHERE recurPeriod IS NULL AND toAccountId IS NOT NULL GROUP BY toAccountId` — returns `[UUID: Int]`
3. Combine: `balances[accountId] = sourceSums[accountId] - destSums[accountId]`

Two SQL queries, zero object hydration, constant memory.

### Core Data Model Definition

The `NSManagedObjectModel` is built programmatically — no `.xcdatamodeld` file. Only the attributes needed for aggregation are declared:

```swift
enum AggregateSchema {
    static func buildModel() -> NSManagedObjectModel {
        let model = NSManagedObjectModel()
        
        let txnEntity = NSEntityDescription()
        txnEntity.name = "TransactionRecord"  // Must match SwiftData class name
        txnEntity.managedObjectClassName = "NSManagedObject" // Generic, no subclass
        txnEntity.properties = [
            attribute("id", .UUIDAttributeType),
            attribute("accountId", .UUIDAttributeType, optional: true),
            attribute("toAccountId", .UUIDAttributeType, optional: true),
            attribute("amount", .integer64AttributeType),
            attribute("recurPeriod", .stringAttributeType, optional: true),
        ]
        
        model.entities = [txnEntity]
        return model
    }
}
```

**Critical: Entity/attribute names must exactly match SwiftData's generated schema.** SwiftData uses the `@Model` class name as the entity name and property names as attribute names. See "Schema Sync" section below.

### Schema Sync Safety

This is the primary risk. If a SwiftData `@Model` property is renamed or its type changes, the Core Data model silently breaks. Multiple layers of protection:

#### Layer 1: Compile-time test (runs in CI)

A test that opens the SwiftData `ModelContainer`, reads the `NSManagedObjectModel` from the underlying store, and asserts the expected entity/attribute names and types exist:

```swift
/// Verifies AggregateSchema matches the actual SwiftData-generated schema.
/// Fails at compile time (in CI) if the schema drifts.
@Test func aggregateSchemaMatchesSwiftDataSchema() throws {
    // Build in-memory SwiftData container
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try ModelContainer(
        for: TransactionRecord.self, configurations: config
    )
    
    // Read the Core Data model that SwiftData generated
    let coordinator = container.configurations.first!... // get underlying store
    
    // Compare against AggregateSchema
    let aggregateModel = AggregateSchema.buildModel()
    for entity in aggregateModel.entities {
        // Assert entity exists in SwiftData model
        // Assert each attribute name and type matches
    }
}
```

**Implementation note:** Getting the `NSManagedObjectModel` from SwiftData's container requires opening the SQLite file with Core Data and reading `NSStoreModelVersionHashes`. Alternatively, the test can:
1. Create an in-memory SwiftData container
2. Create the `AggregateQueryService` against the same in-memory store
3. Insert test data via SwiftData
4. Query via the aggregate service
5. If the schema is mismatched, the query returns wrong results or crashes — test fails

This second approach (insert-then-query) is simpler and more robust. It tests the full round-trip, not just names.

#### Layer 2: Runtime assertion on init

When `AggregateQueryService` opens the store, verify the entity and attributes exist:

```swift
init(storeURL: URL) throws {
    // ... open store ...
    guard let entity = coordinator.managedObjectModel
        .entitiesByName["TransactionRecord"] else {
        throw AggregateError.schemaMismatch("TransactionRecord entity not found")
    }
    let required = ["accountId", "toAccountId", "amount", "recurPeriod"]
    for attr in required {
        guard entity.attributesByName[attr] != nil else {
            throw AggregateError.schemaMismatch("Missing attribute: \(attr)")
        }
    }
}
```

This fails loudly at app launch rather than returning silently wrong data. On failure, `CloudKitAccountRepository.fetchAll()` falls back to the existing in-memory computation.

#### Layer 3: AI review guidelines

Add to `CLAUDE.md` and/or `guides/SYNC_GUIDE.md`:

```
## Aggregate Query Schema Constraint

`AggregateQueryService` maintains a Core Data model that must match SwiftData's
generated schema for `TransactionRecord`. When modifying `TransactionRecord`:

- If you RENAME a property used by aggregation (`accountId`, `toAccountId`,
  `amount`, `recurPeriod`), you MUST update `AggregateSchema.buildModel()`.
- If you change the TYPE of one of these properties, update the corresponding
  `NSAttributeType` in `AggregateSchema`.
- Run `just test` — the schema sync test will catch mismatches.
- Do NOT add new entities to `AggregateSchema` unless they need SQL aggregation.

The aggregate schema intentionally declares only the minimum attributes needed.
```

#### Layer 4: Code comment at the source

In `TransactionRecord.swift`, add a comment on the relevant properties:

```swift
var accountId: UUID?    // ⚠️ Used by AggregateSchema — rename requires update
var toAccountId: UUID?  // ⚠️ Used by AggregateSchema — rename requires update  
var amount: Int = 0     // ⚠️ Used by AggregateSchema — rename requires update
var recurPeriod: String? // ⚠️ Used by AggregateSchema — rename requires update
```

### Integration with existing code

Replace `recomputeAllBalances` in `CloudKitAccountRepository`:

```swift
// Before: O(N) in-memory iteration
private func recomputeAllBalances(records: [AccountRecord]) throws {
    let transactions = try context.fetch(FetchDescriptor<TransactionRecord>(...))
    // ... iterate all transactions ...
}

// After: two SQL queries, zero object hydration
private func recomputeAllBalances(records: [AccountRecord]) throws {
    let balances = try aggregateService.computeAccountBalances()
    for record in records {
        record.cachedBalance = balances[record.id] ?? 0
    }
    try context.save()
}
```

Also benefits `computeBalance(for:)` (single-account version used in update/delete).

### Future aggregation uses

The same `AggregateQueryService` can later support:
- `fetchCategoryBalances` in `CloudKitAnalysisRepository` (currently iterates all transactions)
- Earmark spent-amount computation
- Any GROUP BY / SUM needed for reports

### Testing

- **Schema sync test** (described above): Insert via SwiftData, query via Core Data, assert match.
- **Balance computation test**: Seed transactions across multiple accounts via SwiftData. Query balances via `AggregateQueryService`. Assert correct per-account sums including transfers.
- **Edge cases**: Scheduled transactions excluded (`recurPeriod IS NULL`), transfer double-counting (source + dest), accounts with zero transactions, empty store.
- **Fallback test**: Simulate schema mismatch, verify fallback to in-memory computation.
- **Concurrency test**: Verify aggregate queries work correctly from a non-main-actor context while SwiftData writes are happening on main actor.

---

## Option C: Incremental Balance Deltas from Sync

**Effort:** Medium. **Impact:** Avoids recomputation entirely during sync — O(batch_size) per batch instead of O(total_transactions).

### Approach

Instead of invalidating cached balances and recomputing from scratch, apply the transaction amounts from each sync batch directly to the cached balance:

1. During `applyRemoteChanges`, for each incoming `TransactionRecord`:
   - If it's a **new insert**: add its amount to the source account's `cachedBalance`, subtract from dest account (transfers)
   - If it's an **update**: compute the delta (new amount - old amount) and apply
   - If it's a **deletion**: subtract its amount from the cached balance

2. **No invalidation, no recomputation, no full-table scan.**

### Complexity and risks

Updates are the hard part. When a transaction is updated, we need the old amount to compute the delta. The old amount is available from the existing SwiftData record (fetched in `batchUpsertTransactions` before overwriting), so we can capture it there.

Deletions are also tricky: the CKRecord deletion only gives us `(recordID, recordType)`, not the record content. We need to read the local record before deleting it to get the amount. The current `applyBatchDeletions` already fetches the records before deleting — we'd extract the amounts first.

Account reassignment (transaction moves from account A to account B) requires adjusting both the old and new account balances.

### Periodic reconciliation

Incremental deltas can drift if a sync batch is partially applied (crash, error) or if the delta logic has a bug. To guard against this:

- **Reconcile on sync completion:** After `.didFetchChanges`, do one full `recomputeAllBalances` (or SQL SUM via Option B) to verify the incremental balances are correct. If this only runs once at the end of sync, performance is acceptable.
- **Reconcile periodically:** Every N app launches or once per day, verify incremental balances match a full recomputation. Log a warning if they diverge and correct silently.

### Files to change

- `Backends/CloudKit/Sync/ProfileSyncEngine.swift` — capture old amounts during upsert, apply deltas to `cachedBalance`
- `Backends/CloudKit/Repositories/CloudKitAccountRepository.swift` — remove `invalidateCachedBalances` trigger during sync, add reconciliation

### Testing

- **Insert delta test**: Sync a batch of new transactions. Verify `cachedBalance` updated by exactly the transaction amounts.
- **Update delta test**: Sync an update that changes amount from 100 to 150. Verify balance changes by +50.
- **Delete delta test**: Sync a deletion. Verify balance decremented by the deleted amount.
- **Transfer delta test**: Sync a transfer. Verify source +amount, dest -amount.
- **Account reassignment test**: Sync an update that changes `accountId`. Verify old account decremented, new account incremented.
- **Reconciliation test**: Introduce a deliberate drift, run reconciliation, verify correction.
- **Crash recovery test**: Simulate partial batch application, verify reconciliation corrects on next launch.

---

## Recommendation

**Implement in this order:**

1. **Option A first** (fix the sync cycle) — small change, eliminates the immediate unresponsiveness. Even without faster balance computation, computing once at the end of sync instead of per-batch is a major improvement.

2. **Option B second** (SQL aggregation) — makes the single end-of-sync recomputation fast regardless of transaction count. Also benefits `computeBalance(for:)` used in single-account operations, and opens the door for analysis/reports aggregation.

3. **Option C only if needed** — if SQL aggregation is fast enough (expected: <10ms for 50k transactions), incremental deltas add complexity without meaningful benefit. Consider only if the reconciliation-on-sync-complete from Option A + B is still too slow for very large datasets.

Options A and B are independent and can be developed in parallel. Option C depends on A (needs the sync lifecycle signals).
