# System Fields on Model Records — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate the separate system fields cache file by storing `encodedSystemFields` directly on each SwiftData model record, following Apple's CKSyncEngine pattern.

**Architecture:** Add `encodedSystemFields: Data?` to each of the 6 model types. The sync engine reads/writes this field on the model instead of a separate `[String: Data]` dictionary. SwiftData auto-migrates the new optional column. The cache file, debounced save task, and all serialization code are deleted.

**Tech Stack:** SwiftData, CKSyncEngine, Swift Testing

**Design Spec:** `plans/2026-04-14-system-fields-on-model-design.md`

---

### Task 1: Add `encodedSystemFields` to All Model Records

**Files:**
- Modify: `Backends/CloudKit/Models/AccountRecord.swift`
- Modify: `Backends/CloudKit/Models/TransactionRecord.swift`
- Modify: `Backends/CloudKit/Models/CategoryRecord.swift`
- Modify: `Backends/CloudKit/Models/EarmarkRecord.swift`
- Modify: `Backends/CloudKit/Models/EarmarkBudgetItemRecord.swift`
- Modify: `Backends/CloudKit/Models/InvestmentValueRecord.swift`

- [ ] **Step 1: Add `encodedSystemFields: Data?` to each model**

Add the property after the last field in each model. Do NOT add it to `init()` parameters — it's only set by the sync engine, never by repository code.

`AccountRecord.swift` — add after `cachedBalance`:
```swift
  /// CKRecord system fields (change tag, etc.) for sync conflict detection.
  /// Set by ProfileSyncEngine, not by repository code.
  var encodedSystemFields: Data?
```

`TransactionRecord.swift` — add after `recurEvery`:
```swift
  var encodedSystemFields: Data?
```

`CategoryRecord.swift` — add after `parentId`:
```swift
  var encodedSystemFields: Data?
```

`EarmarkRecord.swift` — add after `savingsEndDate`:
```swift
  var encodedSystemFields: Data?
```

`EarmarkBudgetItemRecord.swift` — add after `currencyCode`:
```swift
  var encodedSystemFields: Data?
```

`InvestmentValueRecord.swift` — add after `currencyCode`:
```swift
  var encodedSystemFields: Data?
```

- [ ] **Step 2: Build to verify schema migration works**

Run: `just build-mac 2>&1 | grep -E 'error:|BUILD'`
Expected: `** BUILD SUCCEEDED **`

SwiftData auto-migrates new optional properties with nil default — no explicit migration plan needed.

- [ ] **Step 3: Run tests to verify nothing breaks**

Run: `mkdir -p .agent-tmp && just test 2>&1 | tee .agent-tmp/test-output.txt | tail -5`
Expected: All tests pass. Check with: `grep "Test Suite.*passed\|Test Suite.*failed" .agent-tmp/test-output.txt`

- [ ] **Step 4: Commit**

```bash
git add Backends/CloudKit/Models/*.swift
git commit -m "feat: add encodedSystemFields to all SwiftData model records"
```

---

### Task 2: Write Test for System Fields Round-Trip on Model

**Files:**
- Modify: `MoolahTests/Sync/ProfileSyncEngineTests.swift`

- [ ] **Step 1: Write failing test — system fields stored on model after remote sync**

Add to the end of `ProfileSyncEngineTests`:

```swift
  // MARK: - System Fields on Model

  @Test func applyRemoteChangesStoresSystemFieldsOnModel() async {
    let profileId = UUID()
    let container = try! TestModelContainer.create()
    let engine = ProfileSyncEngine(profileId: profileId, modelContainer: container)

    let accountId = UUID()
    let ckRecord = CKRecord(
      recordType: "CD_AccountRecord",
      recordID: CKRecord.ID(recordName: accountId.uuidString, zoneID: engine.zoneID)
    )
    ckRecord["name"] = "Test Account" as CKRecordValue
    ckRecord["type"] = "bank" as CKRecordValue
    ckRecord["position"] = 0 as CKRecordValue
    ckRecord["isHidden"] = 0 as CKRecordValue
    ckRecord["currencyCode"] = "AUD" as CKRecordValue

    engine.applyRemoteChanges(saved: [ckRecord], deleted: [])

    // Verify system fields were stored on the model
    let context = ModelContext(container)
    let records = try! context.fetch(
      FetchDescriptor<AccountRecord>(predicate: #Predicate { $0.id == accountId })
    )
    #expect(records.count == 1)
    #expect(records.first?.encodedSystemFields != nil)

    // Verify the stored system fields can reconstruct a CKRecord
    let storedData = records.first!.encodedSystemFields!
    let restored = CKRecord.fromEncodedSystemFields(storedData)
    #expect(restored != nil)
    #expect(restored?.recordID.recordName == accountId.uuidString)
  }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `just test 2>&1 | tee .agent-tmp/test-output.txt | tail -10`
Expected: FAIL — `encodedSystemFields` is nil because `applyBatchSaves` doesn't set it yet.

- [ ] **Step 3: Commit the failing test**

```bash
git add MoolahTests/Sync/ProfileSyncEngineTests.swift
git commit -m "test: add failing test for system fields stored on model after sync"
```

---

### Task 3: Pass System Fields Through to Batch Upserts

**Files:**
- Modify: `Backends/CloudKit/Sync/ProfileSyncEngine.swift`

This task wires pre-extracted system fields through `applyRemoteChanges` → `applyBatchSaves` → each `batchUpsert*` method.

- [ ] **Step 1: Change `applyBatchSaves` to accept and pass through system fields**

In `ProfileSyncEngine.swift`, find the static method `applyBatchSaves` (~line 596):

```swift
  private nonisolated static func applyBatchSaves(_ records: [CKRecord], context: ModelContext) {
```

Change to:

```swift
  private nonisolated static func applyBatchSaves(
    _ records: [CKRecord], context: ModelContext, systemFields: [String: Data]
  ) {
```

Update each call in the switch body to pass `systemFields` through. For example:

```swift
      case AccountRecord.recordType:
        batchUpsertAccounts(ckRecords, context: context, systemFields: systemFields)
```

Do the same for all 6 cases: `batchUpsertAccounts`, `batchUpsertTransactions`, `batchUpsertCategories`, `batchUpsertEarmarks`, `batchUpsertEarmarkBudgetItems`, `batchUpsertInvestmentValues`.

- [ ] **Step 2: Update each `batchUpsert*` method to accept and set system fields**

Each method gets the `systemFields: [String: Data]` parameter. After setting all field values (for both insert and update), set `encodedSystemFields`:

Example for `batchUpsertAccounts` (~line 720):

```swift
  private nonisolated static func batchUpsertAccounts(
    _ ckRecords: [CKRecord], context: ModelContext, systemFields: [String: Data]
  ) {
```

Inside the loop, after the existing insert/update logic, add for both branches:

```swift
      if let existing = byID[id] {
        existing.name = values.name
        existing.type = values.type
        existing.position = values.position
        existing.isHidden = values.isHidden
        existing.currencyCode = values.currencyCode
        existing.encodedSystemFields = systemFields[id.uuidString]
        updateCount += 1
      } else {
        values.encodedSystemFields = systemFields[id.uuidString]
        context.insert(values)
        byID[id] = values
        insertCount += 1
      }
```

Apply the same pattern to all 6 `batchUpsert*` methods:
- `batchUpsertTransactions`: add `existing.encodedSystemFields = systemFields[id.uuidString]` and same for insert
- `batchUpsertCategories`: same
- `batchUpsertEarmarks`: same
- `batchUpsertEarmarkBudgetItems`: same
- `batchUpsertInvestmentValues`: same

- [ ] **Step 3: Update `applyRemoteChanges` to build and pass the system fields dictionary**

In `applyRemoteChanges()`, after caching system fields in the dictionary (the block starting with `if let preExtracted = preExtractedSystemFields`), build a `[String: Data]` for the batch upserts.

Replace the existing system fields caching block and the `applyBatchSaves` call. Find (~line 383):

```swift
    // Cache system fields from received records ...
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

    let context = modelContainer.mainContext

    os_signpost(
      .begin, log: Signposts.sync, name: "applyBatchSaves", signpostID: signpostID,
      "%{public}d records", saved.count)
    let upsertStart = ContinuousClock.now
    Self.applyBatchSaves(saved, context: context)
```

Replace with:

```swift
    // Build system fields lookup for batch upserts.
    // Pre-extracted fields (computed off MainActor) are preferred when available.
    var systemFields: [String: Data]
    if let preExtracted = preExtractedSystemFields {
      systemFields = Dictionary(preExtracted, uniquingKeysWith: { _, last in last })
    } else {
      systemFields = Dictionary(
        uniqueKeysWithValues: saved.map { ($0.recordID.recordName, $0.encodedSystemFields) }
      )
    }

    // Also update the in-memory cache (still needed for buildCKRecord during uploads)
    for (name, data) in systemFields {
      systemFieldsCache[name] = data
    }
    saveSystemFieldsCache()

    let context = modelContainer.mainContext

    os_signpost(
      .begin, log: Signposts.sync, name: "applyBatchSaves", signpostID: signpostID,
      "%{public}d records", saved.count)
    let upsertStart = ContinuousClock.now
    Self.applyBatchSaves(saved, context: context, systemFields: systemFields)
```

Note: We keep `systemFieldsCache` and `saveSystemFieldsCache()` for now — they'll be removed in Task 5 after `buildCKRecord` is updated to read from the model.

- [ ] **Step 4: Run the test from Task 2 to verify it passes**

Run: `just test 2>&1 | tee .agent-tmp/test-output.txt | tail -10`
Expected: All tests pass, including `applyRemoteChangesStoresSystemFieldsOnModel`.

- [ ] **Step 5: Commit**

```bash
git add Backends/CloudKit/Sync/ProfileSyncEngine.swift
git commit -m "feat: pass system fields through to batch upserts and store on model"
```

---

### Task 4: Write Test and Update `buildCKRecord` to Read from Model

**Files:**
- Modify: `MoolahTests/Sync/ProfileSyncEngineTests.swift`
- Modify: `Backends/CloudKit/Sync/ProfileSyncEngine.swift`

- [ ] **Step 1: Write failing test — buildCKRecord uses system fields from model**

Add to `ProfileSyncEngineTests`:

```swift
  @Test func buildCKRecordUsesSystemFieldsFromModel() async {
    let profileId = UUID()
    let container = try! TestModelContainer.create()
    let engine = ProfileSyncEngine(profileId: profileId, modelContainer: container)

    // Create an account and simulate receiving it from CloudKit
    // (which stores system fields on the model)
    let accountId = UUID()
    let ckRecord = CKRecord(
      recordType: "CD_AccountRecord",
      recordID: CKRecord.ID(recordName: accountId.uuidString, zoneID: engine.zoneID)
    )
    ckRecord["name"] = "Test" as CKRecordValue
    ckRecord["type"] = "bank" as CKRecordValue
    ckRecord["position"] = 0 as CKRecordValue
    ckRecord["isHidden"] = 0 as CKRecordValue
    ckRecord["currencyCode"] = "AUD" as CKRecordValue

    engine.applyRemoteChanges(saved: [ckRecord], deleted: [])

    // Fetch the persisted record
    let context = ModelContext(container)
    let records = try! context.fetch(
      FetchDescriptor<AccountRecord>(predicate: #Predicate { $0.id == accountId })
    )
    let account = records.first!

    // buildCKRecord should use the model's encodedSystemFields
    let built = engine.buildCKRecord(for: account)
    #expect(built.recordID.recordName == accountId.uuidString)
    #expect(built.recordID.zoneID == engine.zoneID)
    #expect(built["name"] as? String == "Test")
  }
```

This test already passes with the current code (because the in-memory cache is also being populated). We need it to keep passing after we remove the cache. Just add it now for regression coverage.

- [ ] **Step 2: Update `buildCKRecord` to read from model's `encodedSystemFields`**

In `ProfileSyncEngine.swift`, find `buildCKRecord` (~line 340):

```swift
  func buildCKRecord<T: CloudKitRecordConvertible & IdentifiableRecord>(for record: T) -> CKRecord {
    let recordName = record.id.uuidString
    if let cachedData = systemFieldsCache[recordName],
      let cachedRecord = CKRecord.fromEncodedSystemFields(cachedData)
    {
      record.applyFields(to: cachedRecord)
      return cachedRecord
    }
    return record.toCKRecord(in: zoneID)
  }
```

Replace with:

```swift
  func buildCKRecord<T: CloudKitRecordConvertible & IdentifiableRecord & SystemFieldsCacheable>(
    for record: T
  ) -> CKRecord {
    if let cachedData = record.encodedSystemFields,
      let cachedRecord = CKRecord.fromEncodedSystemFields(cachedData)
    {
      record.applyFields(to: cachedRecord)
      return cachedRecord
    }
    return record.toCKRecord(in: zoneID)
  }
```

- [ ] **Step 3: Add `SystemFieldsCacheable` protocol to `RecordMapping.swift`**

In `Backends/CloudKit/Sync/RecordMapping.swift`, after the `IdentifiableRecord` protocol (~line 23), add:

```swift
/// Protocol for records that can store CKRecord system fields.
protocol SystemFieldsCacheable {
  var encodedSystemFields: Data? { get }
}

extension AccountRecord: SystemFieldsCacheable {}
extension TransactionRecord: SystemFieldsCacheable {}
extension CategoryRecord: SystemFieldsCacheable {}
extension EarmarkRecord: SystemFieldsCacheable {}
extension EarmarkBudgetItemRecord: SystemFieldsCacheable {}
extension InvestmentValueRecord: SystemFieldsCacheable {}
```

- [ ] **Step 4: Run tests to verify everything passes**

Run: `just test 2>&1 | tee .agent-tmp/test-output.txt | tail -10`
Expected: All tests pass.

- [ ] **Step 5: Commit**

```bash
git add Backends/CloudKit/Sync/ProfileSyncEngine.swift Backends/CloudKit/Sync/RecordMapping.swift MoolahTests/Sync/ProfileSyncEngineTests.swift
git commit -m "feat: buildCKRecord reads system fields from model instead of cache"
```

---

### Task 5: Remove System Fields Cache Infrastructure

**Files:**
- Modify: `Backends/CloudKit/Sync/ProfileSyncEngine.swift`

Now that both read (buildCKRecord) and write (applyBatchSaves) use the model, remove the cache.

- [ ] **Step 1: Remove cache properties**

Delete these properties from `ProfileSyncEngine`:
- `private var systemFieldsCache: [String: Data] = [:]` (~line 38)
- `private var systemFieldsSaveTask: Task<Void, Never>?` (~line 42)

- [ ] **Step 2: Remove cache methods**

Delete these methods entirely:
- `systemFieldsCacheURL` computed property
- `loadSystemFieldsCache()`
- `saveSystemFieldsCache()`
- `flushSystemFieldsCache(_:to:)` (the static async method)
- `deleteSystemFieldsCache()`

- [ ] **Step 3: Remove cache usage from `start()`**

Find `systemFieldsCache = loadSystemFieldsCache()` in `start()` and delete it.

- [ ] **Step 4: Remove cache usage from `stop()`**

Find the synchronous `JSONEncoder().encode(systemFieldsCache)` block in `stop()` and delete it entirely. Keep the rest of `stop()`.

- [ ] **Step 5: Remove cache usage from `applyRemoteChanges()`**

In `applyRemoteChanges()`, remove the block that updates `systemFieldsCache` and calls `saveSystemFieldsCache()`. The system fields dictionary built for `applyBatchSaves` is a local variable — it doesn't need the cache.

Find and remove:
```swift
    // Also update the in-memory cache (still needed for buildCKRecord during uploads)
    for (name, data) in systemFields {
      systemFieldsCache[name] = data
    }
    saveSystemFieldsCache()
```

- [ ] **Step 6: Remove cache usage from `handleSentRecordZoneChanges()`**

In `handleSentRecordZoneChanges()` (~line 1207), there are multiple places that update `systemFieldsCache`. Replace each with a model update.

For successfully sent records (~line 1212), replace:
```swift
    for saved in sentChanges.savedRecords {
      systemFieldsCache[saved.recordID.recordName] = saved.encodedSystemFields
    }
    saveSystemFieldsCache()
```

With:
```swift
    // Update system fields on model records after successful upload
    if !sentChanges.savedRecords.isEmpty {
      let context = ModelContext(modelContainer)
      for saved in sentChanges.savedRecords {
        guard let uuid = UUID(uuidString: saved.recordID.recordName) else { continue }
        let data = saved.encodedSystemFields
        Self.updateEncodedSystemFields(uuid, data: data, recordType: saved.recordType, context: context)
      }
      try? context.save()
    }
```

For deleted records (~line 1217), remove:
```swift
    for deleted in sentChanges.deletedRecordIDs {
      systemFieldsCache.removeValue(forKey: deleted.recordName)
    }
```

(No replacement needed — when the model record is deleted, its `encodedSystemFields` goes with it.)

For `.serverRecordChanged` (~line 1236), replace:
```swift
        if let serverRecord = failure.error.serverRecord {
          systemFieldsCache[serverRecord.recordID.recordName] = serverRecord.encodedSystemFields
          saveSystemFieldsCache()
```

With:
```swift
        if let serverRecord = failure.error.serverRecord {
          let context = ModelContext(modelContainer)
          if let uuid = UUID(uuidString: serverRecord.recordID.recordName) {
            Self.updateEncodedSystemFields(
              uuid, data: serverRecord.encodedSystemFields,
              recordType: serverRecord.recordType, context: context)
            try? context.save()
          }
```

For `.unknownItem` (~line 1244), remove:
```swift
        systemFieldsCache.removeValue(forKey: recordID.recordName)
        saveSystemFieldsCache()
```

(The record no longer exists on server — we'll re-upload as new. No cache entry needed.)

- [ ] **Step 7: Add the `updateEncodedSystemFields` helper method**

Add as a static method in the `// MARK: - Batch Processing (Static)` section:

```swift
  /// Updates `encodedSystemFields` on the model record matching the given UUID and type.
  /// Used after successful uploads and conflict resolution.
  nonisolated private static func updateEncodedSystemFields(
    _ id: UUID, data: Data, recordType: String, context: ModelContext
  ) {
    switch recordType {
    case AccountRecord.recordType:
      if let record = try? context.fetch(
        FetchDescriptor<AccountRecord>(predicate: #Predicate { $0.id == id })
      ).first {
        record.encodedSystemFields = data
      }
    case TransactionRecord.recordType:
      if let record = try? context.fetch(
        FetchDescriptor<TransactionRecord>(predicate: #Predicate { $0.id == id })
      ).first {
        record.encodedSystemFields = data
      }
    case CategoryRecord.recordType:
      if let record = try? context.fetch(
        FetchDescriptor<CategoryRecord>(predicate: #Predicate { $0.id == id })
      ).first {
        record.encodedSystemFields = data
      }
    case EarmarkRecord.recordType:
      if let record = try? context.fetch(
        FetchDescriptor<EarmarkRecord>(predicate: #Predicate { $0.id == id })
      ).first {
        record.encodedSystemFields = data
      }
    case EarmarkBudgetItemRecord.recordType:
      if let record = try? context.fetch(
        FetchDescriptor<EarmarkBudgetItemRecord>(predicate: #Predicate { $0.id == id })
      ).first {
        record.encodedSystemFields = data
      }
    case InvestmentValueRecord.recordType:
      if let record = try? context.fetch(
        FetchDescriptor<InvestmentValueRecord>(predicate: #Predicate { $0.id == id })
      ).first {
        record.encodedSystemFields = data
      }
    default:
      break
    }
  }
```

- [ ] **Step 8: Remove `deleteSystemFieldsCache()` calls from event handlers**

In `handleAccountChange()` — remove `deleteSystemFieldsCache()` from `.signOut` and `.switchAccounts` cases. The system fields are deleted when `deleteLocalData()` deletes all model records.

In `handleFetchedDatabaseChanges()` — remove `deleteSystemFieldsCache()` from `.purged` and `.encryptedDataReset` cases. Same reason.

- [ ] **Step 9: Add legacy file cleanup in `start()`**

In `start()`, after the engine is created, add a one-time cleanup of the old cache file:

```swift
    // Clean up legacy system fields cache file (now stored on model records)
    let legacyCacheURL = URL.applicationSupportDirectory
      .appending(path: "Moolah-\(profileId.uuidString).systemfields")
    try? FileManager.default.removeItem(at: legacyCacheURL)
```

- [ ] **Step 10: Build and run tests**

Run: `just test 2>&1 | tee .agent-tmp/test-output.txt | tail -10`
Expected: All tests pass.

- [ ] **Step 11: Commit**

```bash
git add Backends/CloudKit/Sync/ProfileSyncEngine.swift
git commit -m "feat: remove system fields cache — now stored on model records

Eliminates the [String: Data] dictionary, debounced save task, JSON
serialization, and the .systemfields file. System fields are persisted
as part of the existing context.save() in applyRemoteChanges."
```

---

### Task 6: Clean Up Performance Logging

**Files:**
- Modify: `Backends/CloudKit/Sync/ProfileSyncEngine.swift`

- [ ] **Step 1: Remove the `flushSystemFieldsCache` timing log**

The `⚠️ PERF: flushSystemFieldsCache` warning no longer exists (method was deleted). No action needed.

Verify the remaining perf logging still compiles — the batch timing in `applyRemoteChanges` and session summary in `endFetchingChanges` should be unaffected.

- [ ] **Step 2: Build and run full test suite**

Run: `just test 2>&1 | tee .agent-tmp/test-output.txt | tail -10`
Expected: All tests pass.

- [ ] **Step 3: Check for compiler warnings**

Run: `just build-mac 2>&1 | grep 'warning:' | grep -v 'xcodebuild\[' | grep -v 'file reference'`
Expected: No warnings in user code.

- [ ] **Step 4: Clean up temp files**

```bash
rm -f .agent-tmp/test-output.txt
```

- [ ] **Step 5: Commit if any changes were needed**

```bash
git add -A && git commit -m "chore: clean up after system fields migration" || echo "Nothing to commit"
```

---

### Task 7: Manual Verification

**Files:** None (testing only)

- [ ] **Step 1: Build and launch the app**

```bash
just run-mac-with-logs &
```

- [ ] **Step 2: Trigger a sync with a large account**

Navigate to the CloudKit profile with many transactions. Watch the logs:

```bash
tail -f .agent-tmp/app-logs.txt | grep -E "PERF|SYNC SESSION|flushSystemFields"
```

Expected:
- `⚠️ PERF: applyRemoteChanges` lines should show ~30-60ms per batch (same as before)
- NO `flushSystemFieldsCache` lines (the method no longer exists)
- `📊 SYNC SESSION COMPLETE` should appear at the end with cumulative stats
- App UI should remain responsive throughout

- [ ] **Step 3: Verify the legacy cache file is deleted**

```bash
ls ~/Library/Application\ Support/Moolah-*.systemfields 2>/dev/null && echo "FAIL: legacy file exists" || echo "OK: legacy file cleaned up"
```

- [ ] **Step 4: Stop the app and clean up**

```bash
pkill -f "Moolah.app/Contents/MacOS/Moolah" 2>/dev/null || true
pkill -f "log stream.*com.moolah.app" 2>/dev/null || true
rm -f .agent-tmp/app-logs.txt
```
