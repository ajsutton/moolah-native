# Sync Performance: Background Processing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix UI freeze during large initial CloudKit syncs by moving record processing off the main actor and batching database queries.

**Architecture:** Extract record processing into `nonisolated static` methods that operate on their own `ModelContext`. The `handleEvent` delegate (already nonisolated) calls these directly on CKSyncEngine's background queue, only hopping to MainActor to set/clear the `isApplyingRemoteChanges` flag and fire the callback. Per-record `FetchDescriptor` queries are replaced with one batch fetch per record type per sync event.

**Tech Stack:** Swift 6, SwiftData, CKSyncEngine, Swift Testing

---

## File Structure

- **Modify:** `Backends/CloudKit/Sync/ProfileSyncEngine.swift` — main changes (background processing + batch queries)
- **Modify:** `MoolahTests/Sync/ProfileSyncEngineTests.swift` — add batch tests

No new files. The `ProfileIndexSyncEngine` only handles a handful of profile records, so it doesn't need this optimization.

---

### Task 1: Mark immutable properties as `nonisolated`

The `handleEvent` delegate method is already `nonisolated`. To access the model container and logger from it (without hopping to MainActor), we need to mark immutable properties as `nonisolated`.

**Files:**
- Modify: `Backends/CloudKit/Sync/ProfileSyncEngine.swift:11-19`

- [ ] **Step 1: Add `nonisolated` to `let` properties**

Change these property declarations:

```swift
// Before
let profileId: UUID
let zoneID: CKRecordZone.ID
let modelContainer: ModelContainer

// After
nonisolated let profileId: UUID
nonisolated let zoneID: CKRecordZone.ID
nonisolated let modelContainer: ModelContainer
```

Also mark the logger:
```swift
// Before
private let logger = Logger(subsystem: "com.moolah.app", category: "ProfileSyncEngine")

// After
private nonisolated let logger = Logger(subsystem: "com.moolah.app", category: "ProfileSyncEngine")
```

- [ ] **Step 2: Build to verify no regressions**

Run: `just build-mac`
Expected: Clean build. These are additive annotations — all existing call sites still work.

- [ ] **Step 3: Commit**

```bash
git add Backends/CloudKit/Sync/ProfileSyncEngine.swift
git commit -m "refactor: mark immutable ProfileSyncEngine properties as nonisolated"
```

---

### Task 2: Extract static batch-upsert methods

Move the upsert logic from instance methods (which are `@MainActor`) into `nonisolated static` methods that take a `ModelContext` parameter. Replace per-record `FetchDescriptor` queries with one batch fetch per record type.

**Files:**
- Modify: `Backends/CloudKit/Sync/ProfileSyncEngine.swift:325-471` (upsert helpers section)
- Modify: `MoolahTests/Sync/ProfileSyncEngineTests.swift`

- [ ] **Step 1: Write a test for batch insert of multiple transactions**

Add to `MoolahTests/Sync/ProfileSyncEngineTests.swift`:

```swift
@Test func applyRemoteChangesHandlesBatchTransactions() {
  let profileId = UUID()
  let container = try! TestModelContainer.create()
  let engine = ProfileSyncEngine(profileId: profileId, modelContainer: container)

  let accountId = UUID()
  let date = Date(timeIntervalSince1970: 1_700_000_000)

  // Create 100 transaction CKRecords
  var ckRecords: [CKRecord] = []
  for i in 0..<100 {
    let txnId = UUID()
    let ckRecord = CKRecord(
      recordType: "CD_TransactionRecord",
      recordID: CKRecord.ID(recordName: txnId.uuidString, zoneID: engine.zoneID)
    )
    ckRecord["type"] = "expense" as CKRecordValue
    ckRecord["date"] = date as CKRecordValue
    ckRecord["accountId"] = accountId.uuidString as CKRecordValue
    ckRecord["amount"] = -(i * 100) as CKRecordValue
    ckRecord["currencyCode"] = "AUD" as CKRecordValue
    ckRecord["payee"] = "Item \(i)" as CKRecordValue
    ckRecords.append(ckRecord)
  }

  engine.applyRemoteChanges(saved: ckRecords, deleted: [])

  let context = ModelContext(container)
  let descriptor = FetchDescriptor<TransactionRecord>()
  let records = try! context.fetch(descriptor)
  #expect(records.count == 100)
}
```

- [ ] **Step 2: Write a test for batch upsert (mix of inserts and updates)**

Add to `MoolahTests/Sync/ProfileSyncEngineTests.swift`:

```swift
@Test func applyRemoteChangesHandlesMixedInsertAndUpdate() {
  let profileId = UUID()
  let container = try! TestModelContainer.create()
  let engine = ProfileSyncEngine(profileId: profileId, modelContainer: container)

  let existingId = UUID()
  let newId = UUID()
  let accountId = UUID()
  let date = Date(timeIntervalSince1970: 1_700_000_000)

  // Pre-insert one transaction
  let context = ModelContext(container)
  let existing = TransactionRecord(
    id: existingId, type: "expense", date: date, accountId: accountId, toAccountId: nil,
    amount: -500, currencyCode: "AUD", payee: "Old Payee", notes: nil,
    categoryId: nil, earmarkId: nil, recurPeriod: nil, recurEvery: nil
  )
  context.insert(existing)
  try! context.save()

  // Send both an update to the existing record and a new record
  let updateCK = CKRecord(
    recordType: "CD_TransactionRecord",
    recordID: CKRecord.ID(recordName: existingId.uuidString, zoneID: engine.zoneID)
  )
  updateCK["type"] = "expense" as CKRecordValue
  updateCK["date"] = date as CKRecordValue
  updateCK["accountId"] = accountId.uuidString as CKRecordValue
  updateCK["amount"] = -999 as CKRecordValue
  updateCK["currencyCode"] = "AUD" as CKRecordValue
  updateCK["payee"] = "Updated Payee" as CKRecordValue

  let insertCK = CKRecord(
    recordType: "CD_TransactionRecord",
    recordID: CKRecord.ID(recordName: newId.uuidString, zoneID: engine.zoneID)
  )
  insertCK["type"] = "income" as CKRecordValue
  insertCK["date"] = date as CKRecordValue
  insertCK["accountId"] = accountId.uuidString as CKRecordValue
  insertCK["amount"] = 2000 as CKRecordValue
  insertCK["currencyCode"] = "AUD" as CKRecordValue
  insertCK["payee"] = "New Payee" as CKRecordValue

  engine.applyRemoteChanges(saved: [updateCK, insertCK], deleted: [])

  let freshContext = ModelContext(container)
  let all = try! freshContext.fetch(FetchDescriptor<TransactionRecord>())
  #expect(all.count == 2)

  let updated = all.first { $0.id == existingId }
  #expect(updated?.payee == "Updated Payee")
  #expect(updated?.amount == -999)

  let inserted = all.first { $0.id == newId }
  #expect(inserted?.payee == "New Payee")
  #expect(inserted?.amount == 2000)
}
```

- [ ] **Step 3: Run tests to verify both pass with existing code**

```bash
mkdir -p .agent-tmp && just test 2>&1 | tee .agent-tmp/test-output.txt
grep -E 'HandlesBatch|HandlesMixed|FAIL|passed' .agent-tmp/test-output.txt
```

Expected: Both PASS (existing per-record approach handles this correctly, just slowly).

- [ ] **Step 4: Extract static batch-upsert methods**

Replace the `// MARK: - Upsert Helpers` section in `ProfileSyncEngine.swift`. Add new `nonisolated static` methods after the existing `// MARK: - Private Helpers` section.

Add the dispatch method:

```swift
// MARK: - Batch Processing (nonisolated)

/// Applies saved CKRecords to a ModelContext using batch fetches.
/// Groups records by type, fetches existing records in one query per type,
/// then inserts or updates as needed. Does NOT call context.save().
nonisolated static func applyBatchSaves(_ records: [CKRecord], context: ModelContext) {
  var byType: [String: [CKRecord]] = [:]
  for record in records {
    byType[record.recordType, default: []].append(record)
  }

  if let group = byType[AccountRecord.recordType] {
    batchUpsertAccounts(group, context: context)
  }
  if let group = byType[TransactionRecord.recordType] {
    batchUpsertTransactions(group, context: context)
  }
  if let group = byType[CategoryRecord.recordType] {
    batchUpsertCategories(group, context: context)
  }
  if let group = byType[EarmarkRecord.recordType] {
    batchUpsertEarmarks(group, context: context)
  }
  if let group = byType[EarmarkBudgetItemRecord.recordType] {
    batchUpsertEarmarkBudgetItems(group, context: context)
  }
  if let group = byType[InvestmentValueRecord.recordType] {
    batchUpsertInvestmentValues(group, context: context)
  }
}

/// Applies deletions to a ModelContext. Does NOT call context.save().
nonisolated static func applyBatchDeletions(
  _ deletions: [(CKRecord.ID, String)],
  context: ModelContext
) {
  for (recordID, recordType) in deletions {
    guard let recordId = UUID(uuidString: recordID.recordName) else { continue }
    switch recordType {
    case AccountRecord.recordType:
      deleteByID(AccountRecord.self, id: recordId, context: context)
    case TransactionRecord.recordType:
      deleteByID(TransactionRecord.self, id: recordId, context: context)
    case CategoryRecord.recordType:
      deleteByID(CategoryRecord.self, id: recordId, context: context)
    case EarmarkRecord.recordType:
      deleteByID(EarmarkRecord.self, id: recordId, context: context)
    case EarmarkBudgetItemRecord.recordType:
      deleteByID(EarmarkBudgetItemRecord.self, id: recordId, context: context)
    case InvestmentValueRecord.recordType:
      deleteByID(InvestmentValueRecord.self, id: recordId, context: context)
    default:
      break
    }
  }
}
```

Add the per-type batch upsert methods. Here's the pattern — each type follows the same structure with its own fields. Copy field assignments from the existing `upsert*` instance methods:

```swift
nonisolated private static func batchUpsertAccounts(
  _ ckRecords: [CKRecord], context: ModelContext
) {
  let pairs: [(UUID, CKRecord)] = ckRecords.compactMap { ck in
    guard let id = UUID(uuidString: ck.recordID.recordName) else { return nil }
    return (id, ck)
  }
  let ids = pairs.map(\.0)
  let descriptor = FetchDescriptor<AccountRecord>(
    predicate: #Predicate<AccountRecord> { record in ids.contains(record.id) }
  )
  let existing = (try? context.fetch(descriptor)) ?? []
  let byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })

  for (id, ckRecord) in pairs {
    let values = AccountRecord.fieldValues(from: ckRecord)
    if let record = byID[id] {
      record.name = values.name
      record.type = values.type
      record.position = values.position
      record.isHidden = values.isHidden
      record.currencyCode = values.currencyCode
      record.cachedBalance = values.cachedBalance
    } else {
      context.insert(values)
    }
  }
}

nonisolated private static func batchUpsertTransactions(
  _ ckRecords: [CKRecord], context: ModelContext
) {
  let pairs: [(UUID, CKRecord)] = ckRecords.compactMap { ck in
    guard let id = UUID(uuidString: ck.recordID.recordName) else { return nil }
    return (id, ck)
  }
  let ids = pairs.map(\.0)
  let descriptor = FetchDescriptor<TransactionRecord>(
    predicate: #Predicate<TransactionRecord> { record in ids.contains(record.id) }
  )
  let existing = (try? context.fetch(descriptor)) ?? []
  let byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })

  for (id, ckRecord) in pairs {
    let values = TransactionRecord.fieldValues(from: ckRecord)
    if let record = byID[id] {
      record.type = values.type
      record.date = values.date
      record.accountId = values.accountId
      record.toAccountId = values.toAccountId
      record.amount = values.amount
      record.currencyCode = values.currencyCode
      record.payee = values.payee
      record.notes = values.notes
      record.categoryId = values.categoryId
      record.earmarkId = values.earmarkId
      record.recurPeriod = values.recurPeriod
      record.recurEvery = values.recurEvery
    } else {
      context.insert(values)
    }
  }
}

nonisolated private static func batchUpsertCategories(
  _ ckRecords: [CKRecord], context: ModelContext
) {
  let pairs: [(UUID, CKRecord)] = ckRecords.compactMap { ck in
    guard let id = UUID(uuidString: ck.recordID.recordName) else { return nil }
    return (id, ck)
  }
  let ids = pairs.map(\.0)
  let descriptor = FetchDescriptor<CategoryRecord>(
    predicate: #Predicate<CategoryRecord> { record in ids.contains(record.id) }
  )
  let existing = (try? context.fetch(descriptor)) ?? []
  let byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })

  for (id, ckRecord) in pairs {
    let values = CategoryRecord.fieldValues(from: ckRecord)
    if let record = byID[id] {
      record.name = values.name
      record.parentId = values.parentId
    } else {
      context.insert(values)
    }
  }
}

nonisolated private static func batchUpsertEarmarks(
  _ ckRecords: [CKRecord], context: ModelContext
) {
  let pairs: [(UUID, CKRecord)] = ckRecords.compactMap { ck in
    guard let id = UUID(uuidString: ck.recordID.recordName) else { return nil }
    return (id, ck)
  }
  let ids = pairs.map(\.0)
  let descriptor = FetchDescriptor<EarmarkRecord>(
    predicate: #Predicate<EarmarkRecord> { record in ids.contains(record.id) }
  )
  let existing = (try? context.fetch(descriptor)) ?? []
  let byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })

  for (id, ckRecord) in pairs {
    let values = EarmarkRecord.fieldValues(from: ckRecord)
    if let record = byID[id] {
      record.name = values.name
      record.position = values.position
      record.isHidden = values.isHidden
      record.savingsTarget = values.savingsTarget
      record.currencyCode = values.currencyCode
      record.savingsStartDate = values.savingsStartDate
      record.savingsEndDate = values.savingsEndDate
    } else {
      context.insert(values)
    }
  }
}

nonisolated private static func batchUpsertEarmarkBudgetItems(
  _ ckRecords: [CKRecord], context: ModelContext
) {
  let pairs: [(UUID, CKRecord)] = ckRecords.compactMap { ck in
    guard let id = UUID(uuidString: ck.recordID.recordName) else { return nil }
    return (id, ck)
  }
  let ids = pairs.map(\.0)
  let descriptor = FetchDescriptor<EarmarkBudgetItemRecord>(
    predicate: #Predicate<EarmarkBudgetItemRecord> { record in ids.contains(record.id) }
  )
  let existing = (try? context.fetch(descriptor)) ?? []
  let byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })

  for (id, ckRecord) in pairs {
    let values = EarmarkBudgetItemRecord.fieldValues(from: ckRecord)
    if let record = byID[id] {
      record.earmarkId = values.earmarkId
      record.categoryId = values.categoryId
      record.amount = values.amount
      record.currencyCode = values.currencyCode
    } else {
      context.insert(values)
    }
  }
}

nonisolated private static func batchUpsertInvestmentValues(
  _ ckRecords: [CKRecord], context: ModelContext
) {
  let pairs: [(UUID, CKRecord)] = ckRecords.compactMap { ck in
    guard let id = UUID(uuidString: ck.recordID.recordName) else { return nil }
    return (id, ck)
  }
  let ids = pairs.map(\.0)
  let descriptor = FetchDescriptor<InvestmentValueRecord>(
    predicate: #Predicate<InvestmentValueRecord> { record in ids.contains(record.id) }
  )
  let existing = (try? context.fetch(descriptor)) ?? []
  let byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })

  for (id, ckRecord) in pairs {
    let values = InvestmentValueRecord.fieldValues(from: ckRecord)
    if let record = byID[id] {
      record.accountId = values.accountId
      record.date = values.date
      record.value = values.value
      record.currencyCode = values.currencyCode
    } else {
      context.insert(values)
    }
  }
}
```

Add the generic delete helper. The record types all have `id: UUID` but may not share a protocol. If `#Predicate` doesn't work with a generic, use concrete per-type delete functions (same switch pattern as existing `applyRemoteDeletion`):

```swift
// Per-type delete — used because SwiftData #Predicate doesn't support generic type parameters
nonisolated private static func deleteByID<T: PersistentModel>(
  _ type: T.Type, id: UUID, context: ModelContext
) {
  // SwiftData generics crash with #Predicate — use concrete helpers
  // This is a dispatcher that calls the right concrete method
}
```

**If the generic `#Predicate` approach crashes** (known SwiftData issue with generics), replace `deleteByID` with the same concrete per-type fetch pattern already used in `applyRemoteDeletion`. The deletion path handles small numbers of records so per-record queries are acceptable here.

- [ ] **Step 5: Update `applyRemoteChanges` to use the new static methods**

Replace the body of `applyRemoteChanges`:

```swift
func applyRemoteChanges(
  saved: [CKRecord],
  deleted: [(CKRecord.ID, String)]
) {
  isApplyingRemoteChanges = true
  defer { isApplyingRemoteChanges = false }

  let context = ModelContext(modelContainer)
  Self.applyBatchSaves(saved, context: context)
  Self.applyBatchDeletions(deleted, context: context)

  do {
    try context.save()
    onRemoteChangesApplied?()
  } catch {
    logger.error("Failed to save remote changes: \(error)")
  }
}
```

- [ ] **Step 6: Remove the old per-record instance methods**

Delete these methods (replaced by the static batch methods):
- `applyRemoteSave(_:context:)` (~line 327)
- `applyRemoteDeletion(recordID:recordType:context:)` (~line 354)
- All 6 `upsert*` instance methods (~lines 383-471)

Keep:
- All `fetch*` instance methods — still used by `recordToSave(for:)` and `deleteLocalData()`

- [ ] **Step 7: Run all tests**

```bash
mkdir -p .agent-tmp && just test 2>&1 | tee .agent-tmp/test-output.txt
grep -E 'FAIL|Test Suite.*passed' .agent-tmp/test-output.txt
```

Expected: All tests pass. The batch methods produce the same results as the per-record methods.

- [ ] **Step 8: Commit**

```bash
git add Backends/CloudKit/Sync/ProfileSyncEngine.swift MoolahTests/Sync/ProfileSyncEngineTests.swift
git commit -m "perf: batch-fetch existing records during sync instead of per-record queries

Replaces N individual FetchDescriptor queries per sync batch with one
query per record type. For a 400-record batch, this reduces ~400 SQLite
queries to ~6."
```

---

### Task 3: Move `fetchedRecordZoneChanges` processing off the main actor

The `handleEvent` delegate method is already `nonisolated` — it runs on CKSyncEngine's background queue. Currently it hops to MainActor for all processing. Change it to process `fetchedRecordZoneChanges` directly on the background queue, only hopping to MainActor for the `isApplyingRemoteChanges` flag and callback.

**Files:**
- Modify: `Backends/CloudKit/Sync/ProfileSyncEngine.swift:476-510` (CKSyncEngineDelegate section)

- [ ] **Step 1: Split `handleEvent` to process fetched changes on background**

Replace the `handleEvent` method in the `CKSyncEngineDelegate` extension:

```swift
nonisolated func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
  switch event {
  case .fetchedRecordZoneChanges(let changes):
    await handleFetchedRecordZoneChangesInBackground(changes)

  default:
    await MainActor.run {
      handleEventOnMain(event, syncEngine: syncEngine)
    }
  }
}
```

Add the new background processing method:

```swift
/// Processes fetched record zone changes on the BACKGROUND thread (CKSyncEngine's queue).
/// Only hops to MainActor for the isApplyingRemoteChanges flag and the reload callback.
nonisolated private func handleFetchedRecordZoneChangesInBackground(
  _ changes: CKSyncEngine.Event.FetchedRecordZoneChanges
) async {
  let saved = changes.modifications.map(\.record)
  let deleted: [(CKRecord.ID, String)] = changes.deletions.map {
    ($0.recordID, $0.recordType)
  }
  guard !saved.isEmpty || !deleted.isEmpty else { return }

  // Set flag BEFORE background work — ChangeTracker checks this on main queue.
  // The flag stays true for the duration of the await, so any
  // NSManagedObjectContextDidSave notifications delivered to the main queue
  // during context.save() will see it as true.
  await MainActor.run { self.isApplyingRemoteChanges = true }

  // Process on current (background) thread — no main actor involvement
  let context = ModelContext(modelContainer)
  Self.applyBatchSaves(saved, context: context)
  Self.applyBatchDeletions(deleted, context: context)
  do {
    try context.save()
  } catch {
    logger.error("Failed to save remote changes: \(error)")
  }

  // Notify on main actor
  await MainActor.run {
    self.isApplyingRemoteChanges = false
    self.onRemoteChangesApplied?()
  }
}
```

- [ ] **Step 2: Remove `fetchedRecordZoneChanges` case from `handleEventOnMain`**

In `handleEventOnMain`, remove the `.fetchedRecordZoneChanges` case (it's now routed directly by `handleEvent`):

```swift
// Remove this case from handleEventOnMain:
case .fetchedRecordZoneChanges(let fetchedChanges):
  handleFetchedRecordZoneChanges(fetchedChanges)
```

Also delete the old synchronous `handleFetchedRecordZoneChanges` instance method (~line 603-614).

- [ ] **Step 3: Build and run tests**

```bash
just test 2>&1 | tee .agent-tmp/test-output.txt
grep -E 'FAIL|Test Suite.*passed' .agent-tmp/test-output.txt
```

Expected: All tests pass. Tests call `applyRemoteChanges` directly (still `@MainActor`, synchronous), which is unchanged. The `handleEvent` path is the production code path.

- [ ] **Step 4: Check for warnings**

```bash
just build-mac 2>&1 | grep -i warning | grep -v 'Preview'
```

Fix any new warnings (sendability, unused variables, etc.). Common ones:
- If CKRecord sendability warnings appear, add `@preconcurrency import CloudKit` at the top of the file
- If `changes` capture warnings appear, the `nonisolated` method already receives them as parameters (no capture)

- [ ] **Step 5: Commit**

```bash
git add Backends/CloudKit/Sync/ProfileSyncEngine.swift
git commit -m "perf: process fetched CloudKit records off the main actor

CKSyncEngine's handleEvent delegate runs on a background queue.
Previously, all processing was dispatched to MainActor, blocking the UI
during large syncs (15000+ records caused multi-minute freezes).

Now fetchedRecordZoneChanges are processed directly on the background
queue with their own ModelContext. Only the isApplyingRemoteChanges flag
and the reload callback hop to MainActor."
```

---

### Task 4: Verify the ChangeTracker guard still works

The `ChangeTracker` checks `syncEngine.isApplyingRemoteChanges` on the main queue to avoid re-uploading records that just arrived from CloudKit. With background saves, we need to verify the flag timing is correct.

**Files:**
- Review: `Backends/CloudKit/Sync/ChangeTracker.swift:22-58`

- [ ] **Step 1: Verify timing correctness**

The sequence is:
1. Main actor: `isApplyingRemoteChanges = true` (via `await MainActor.run`)
2. Background: `context.save()` → Core Data posts `NSManagedObjectContextDidSave`
3. Observer (`.main` queue): checks `isApplyingRemoteChanges` → should be `true`
4. Main actor: `isApplyingRemoteChanges = false` (via `await MainActor.run`)

Step 3 runs during the `await` suspension between steps 2 and 4. The main actor is yielded, so the main dispatch queue can process the notification. The flag was set in step 1 and hasn't been cleared yet. The guard works correctly.

No code changes needed — just verify this reasoning by reviewing the ChangeTracker code.

- [ ] **Step 2: Run the full test suite**

```bash
just test 2>&1 | tee .agent-tmp/test-output.txt
grep -E 'FAIL|Test Suite.*passed' .agent-tmp/test-output.txt
rm .agent-tmp/test-output.txt
```

Expected: All tests pass.

- [ ] **Step 3: Commit (if any fixes were needed)**

---

## Implementation Notes

### `#Predicate` with `Array.contains`

The batch fetch uses `#Predicate<T> { record in ids.contains(record.id) }` where `ids` is a `[UUID]`. This translates to SQL `IN` and should work in SwiftData on iOS 17+. If it doesn't compile, fall back to fetching all records of the type and filtering in memory:

```swift
// Fallback: fetch all records of the type, filter in memory
let all = (try? context.fetch(FetchDescriptor<TransactionRecord>())) ?? []
let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
```

This is still far better than N individual queries. On initial sync the table is empty so the fetch is instant.

### Generic delete helper

SwiftData's `#Predicate` doesn't work with generic type parameters (runtime crash due to KVC resolution). If `deleteByID<T>` crashes, replace it with concrete per-type delete methods — the same pattern as the existing `applyRemoteDeletion` switch statement. Deletions are always small batches so per-record queries are acceptable.

### CKRecord sendability

`CKRecord` is not `Sendable`. In `handleFetchedRecordZoneChangesInBackground`, the CKRecords are created by CKSyncEngine on its background queue and processed on that same queue — no actor boundary crossing. If the compiler warns, add `@preconcurrency import CloudKit`.

### Why not `@ModelActor`?

A `@ModelActor` would create a separate actor with its own serial executor. This is heavier than needed — we already have a background thread (CKSyncEngine's queue) and just need a `ModelContext` to use on it. Creating a `ModelContext(modelContainer)` directly is simpler and avoids an extra actor hop.
