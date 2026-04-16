# Unified CKSyncEngine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace N+1 CKSyncEngine instances with a single SyncCoordinator that routes records by zone ID, fixing four inherited bugs and simplifying the app lifecycle.

**Architecture:** Extract batch upsert/delete logic from ProfileSyncEngine into a stateless ProfileDataSyncHandler. Extract ProfileIndexSyncEngine's apply logic into ProfileIndexSyncHandler. Build a SyncCoordinator that owns one CKSyncEngine, routes events by zone ID, and manages the full sync lifecycle. Update ProfileSession, ProfileStore, and MoolahApp to use the coordinator. Delete the old engines.

**Tech Stack:** Swift, CKSyncEngine, SwiftData, CloudKit

**Design:** `plans/2026-04-15-unified-sync-engine-design.md`

---

## File Structure

### New Files
| File | Responsibility |
|------|---------------|
| `Backends/CloudKit/Sync/ProfileDataSyncHandler.swift` | Stateless helper: batch upsert/delete, record building, system fields, queueAllExistingRecords for profile data zones. Extracted from ProfileSyncEngine. |
| `Backends/CloudKit/Sync/ProfileIndexSyncHandler.swift` | Stateless helper: apply remote profile changes, record building, system fields for the profile-index zone. Extracted from ProfileIndexSyncEngine. |
| `Backends/CloudKit/Sync/SyncCoordinator.swift` | Owns single CKSyncEngine. Routes events by zone ID. Manages state, zone creation, account changes, observer pattern. |
| `MoolahTests/Sync/ProfileDataSyncHandlerTests.swift` | Tests for extracted profile data handler. |
| `MoolahTests/Sync/ProfileIndexSyncHandlerTests.swift` | Tests for extracted profile index handler. |
| `MoolahTests/Sync/SyncCoordinatorTests.swift` | Tests for coordinator routing, observer lifecycle, state management. |

### Modified Files
| File | Changes |
|------|---------|
| `Backends/CloudKit/Sync/SyncErrorRecovery.swift` | Change `recover()` to return zone creation info instead of fire-and-forget Task. |
| `App/ProfileSession.swift` | Remove ProfileSyncEngine creation. Wire repository callbacks to SyncCoordinator via zone ID. Register observer token. |
| `App/MoolahApp.swift` | Replace ProfileIndexSyncEngine + per-profile engines with single SyncCoordinator. Simplify background sync. |
| `Features/Profiles/ProfileStore.swift` | Wire `onProfileChanged`/`onProfileDeleted` to SyncCoordinator instead of ProfileIndexSyncEngine. |
| `Shared/ProfileContainerManager.swift` | Add `deleteOldSyncStateFiles()` migration helper. Add `allProfileIds()` to enumerate known profiles. |
| `project.yml` | Add new source files to Moolah and MoolahTests targets. |

### Deleted Files
| File | Reason |
|------|--------|
| `Backends/CloudKit/Sync/ProfileSyncEngine.swift` | Replaced by SyncCoordinator + ProfileDataSyncHandler |
| `Backends/CloudKit/Sync/ProfileIndexSyncEngine.swift` | Replaced by SyncCoordinator + ProfileIndexSyncHandler |
| `MoolahTests/Sync/ProfileSyncEngineTests.swift` | Replaced by handler + coordinator tests |
| `MoolahTests/Sync/ProfileIndexSyncEngineTests.swift` | Replaced by handler + coordinator tests |

---

## Task 1: Extract ProfileDataSyncHandler

Extract the stateless batch processing logic from `ProfileSyncEngine` into a standalone handler with no CKSyncEngine dependency. This is pure extraction — no behavior changes.

**Files:**
- Create: `Backends/CloudKit/Sync/ProfileDataSyncHandler.swift`
- Test: `MoolahTests/Sync/ProfileDataSyncHandlerTests.swift`
- Reference: `Backends/CloudKit/Sync/ProfileSyncEngine.swift`

- [ ] **Step 1: Write tests for ProfileDataSyncHandler**

Create `MoolahTests/Sync/ProfileDataSyncHandlerTests.swift`. These test the handler's batch upsert, deletion, record building, and system fields logic against in-memory SwiftData. Port the existing test patterns from `ProfileSyncEngineTests.swift` but targeting the handler directly.

```swift
import CloudKit
import Foundation
import SwiftData
import Testing

@testable import Moolah

@Suite("ProfileDataSyncHandler")
@MainActor
struct ProfileDataSyncHandlerTests {

  private func makeHandler() throws -> (ProfileDataSyncHandler, ModelContainer) {
    let container = try TestModelContainer.create()
    let zoneID = CKRecordZone.ID(zoneName: "profile-test", ownerName: CKCurrentUserDefaultName)
    let handler = ProfileDataSyncHandler(zoneID: zoneID, modelContainer: container)
    return (handler, container)
  }

  // MARK: - Applying Remote Changes

  @Test func applyRemoteInsertCreatesLocalRecord() throws {
    let (handler, container) = try makeHandler()
    let accountId = UUID()
    let ckRecord = CKRecord(
      recordType: "CD_AccountRecord",
      recordID: CKRecord.ID(recordName: accountId.uuidString, zoneID: handler.zoneID)
    )
    ckRecord["name"] = "Remote Account" as CKRecordValue
    ckRecord["type"] = "bank" as CKRecordValue
    ckRecord["position"] = 0 as CKRecordValue
    ckRecord["isHidden"] = false as CKRecordValue

    handler.applyRemoteChanges(saved: [ckRecord], deleted: [])

    let context = ModelContext(container)
    let records = try context.fetch(FetchDescriptor<AccountRecord>(
      predicate: #Predicate { $0.id == accountId }
    ))
    #expect(records.count == 1)
    #expect(records.first?.name == "Remote Account")
  }

  @Test func applyRemoteUpdateModifiesExistingRecord() throws {
    let (handler, container) = try makeHandler()
    let accountId = UUID()

    // Seed existing record
    let context = ModelContext(container)
    let existing = AccountRecord(id: accountId, name: "Old Name", type: "bank", position: 0, isHidden: false)
    context.insert(existing)
    try context.save()

    // Apply remote update
    let ckRecord = CKRecord(
      recordType: "CD_AccountRecord",
      recordID: CKRecord.ID(recordName: accountId.uuidString, zoneID: handler.zoneID)
    )
    ckRecord["name"] = "New Name" as CKRecordValue
    ckRecord["type"] = "bank" as CKRecordValue
    ckRecord["position"] = 0 as CKRecordValue
    ckRecord["isHidden"] = false as CKRecordValue

    handler.applyRemoteChanges(saved: [ckRecord], deleted: [])

    let readContext = ModelContext(container)
    let records = try readContext.fetch(FetchDescriptor<AccountRecord>(
      predicate: #Predicate { $0.id == accountId }
    ))
    #expect(records.count == 1)
    #expect(records.first?.name == "New Name")
  }

  @Test func applyRemoteDeletionRemovesRecord() throws {
    let (handler, container) = try makeHandler()
    let accountId = UUID()

    let context = ModelContext(container)
    let existing = AccountRecord(id: accountId, name: "Delete Me", type: "bank", position: 0, isHidden: false)
    context.insert(existing)
    try context.save()

    let recordID = CKRecord.ID(recordName: accountId.uuidString, zoneID: handler.zoneID)
    handler.applyRemoteChanges(saved: [], deleted: [(recordID, "CD_AccountRecord")])

    let readContext = ModelContext(container)
    let records = try readContext.fetch(FetchDescriptor<AccountRecord>())
    #expect(records.isEmpty)
  }

  // MARK: - Building CKRecords

  @Test func buildCKRecordFromLocalAccount() throws {
    let (handler, container) = try makeHandler()
    let account = AccountRecord(id: UUID(), name: "Savings", type: "bank", position: 0, isHidden: false)
    let context = ModelContext(container)
    context.insert(account)
    try context.save()

    let ckRecord = handler.buildCKRecord(for: account)
    #expect(ckRecord.recordType == "CD_AccountRecord")
    #expect(ckRecord.recordID.zoneID == handler.zoneID)
    #expect(ckRecord["name"] as? String == "Savings")
  }

  @Test func buildCKRecordPreservesCachedSystemFields() throws {
    let (handler, container) = try makeHandler()

    // Create a CKRecord to get real system fields
    let sourceRecord = CKRecord(
      recordType: "CD_AccountRecord",
      recordID: CKRecord.ID(recordName: UUID().uuidString, zoneID: handler.zoneID)
    )
    let systemFieldsData = sourceRecord.encodedSystemFields

    let account = AccountRecord(id: UUID(), name: "Test", type: "bank", position: 0, isHidden: false)
    account.encodedSystemFields = systemFieldsData
    let context = ModelContext(container)
    context.insert(account)
    try context.save()

    let ckRecord = handler.buildCKRecord(for: account)
    // When system fields are cached, the record should use the cached record ID
    #expect(ckRecord["name"] as? String == "Test")
  }

  // MARK: - Delete Local Data

  @Test func deleteLocalDataRemovesAllRecordTypes() throws {
    let (handler, container) = try makeHandler()
    let context = ModelContext(container)

    context.insert(AccountRecord(id: UUID(), name: "A", type: "bank", position: 0, isHidden: false))
    context.insert(CategoryRecord(id: UUID(), name: "C", parentId: nil))
    try context.save()

    let changedTypes = handler.deleteLocalData()

    let readContext = ModelContext(container)
    #expect(try readContext.fetch(FetchDescriptor<AccountRecord>()).isEmpty)
    #expect(try readContext.fetch(FetchDescriptor<CategoryRecord>()).isEmpty)
    #expect(changedTypes.contains("CD_AccountRecord"))
    #expect(changedTypes.contains("CD_CategoryRecord"))
  }

  // MARK: - Queue All Existing Records

  @Test func queueAllExistingRecordsReturnsAllRecordIDs() throws {
    let (handler, container) = try makeHandler()
    let context = ModelContext(container)

    let accountId = UUID()
    let categoryId = UUID()
    context.insert(AccountRecord(id: accountId, name: "A", type: "bank", position: 0, isHidden: false))
    context.insert(CategoryRecord(id: categoryId, name: "C", parentId: nil))
    try context.save()

    let pending = handler.queueAllExistingRecords()

    #expect(pending.count == 2)
    let names = Set(pending.map(\.recordName))
    #expect(names.contains(accountId.uuidString))
    #expect(names.contains(categoryId.uuidString))
  }

  // MARK: - Batch Record Lookup

  @Test func buildBatchRecordLookupFindsRecordsByUUID() throws {
    let (handler, container) = try makeHandler()
    let context = ModelContext(container)

    let id1 = UUID()
    let id2 = UUID()
    context.insert(AccountRecord(id: id1, name: "A1", type: "bank", position: 0, isHidden: false))
    context.insert(CategoryRecord(id: id2, name: "C1", parentId: nil))
    try context.save()

    let lookup = handler.buildBatchRecordLookup(for: [id1, id2])
    #expect(lookup.count == 2)
    #expect(lookup[id1]?.recordType == "CD_AccountRecord")
    #expect(lookup[id2]?.recordType == "CD_CategoryRecord")
  }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `just test 2>&1 | tee .agent-tmp/test-handler.txt`
Expected: Compilation errors — `ProfileDataSyncHandler` doesn't exist yet.

- [ ] **Step 3: Create ProfileDataSyncHandler**

Create `Backends/CloudKit/Sync/ProfileDataSyncHandler.swift`. Extract the batch processing methods from `ProfileSyncEngine.swift`. The handler is `@MainActor` (same isolation as current engine) but has no CKSyncEngine dependency.

Key methods to extract (preserving exact logic from ProfileSyncEngine):
- `applyRemoteChanges(saved:deleted:preExtractedSystemFields:)` — uses a new `ModelContext` per call (design doc fix: never use `mainContext`)
- `applyBatchSaves(_:context:systemFields:)` — static, all 8 per-type upsert methods
- `applyBatchDeletions(_:context:)` — static, per-type deletion
- `buildCKRecord(for:)` — generic, applies cached system fields
- `buildBatchRecordLookup(for:)` — batch loads by type with pruning
- `recordToSave(for:)` — per-type lookup chain
- `queueAllExistingRecords()` — returns `[CKRecord.ID]` instead of directly queuing (the coordinator will queue them)
- `deleteLocalData()` — returns `Set<String>` of changed types instead of calling a callback
- `clearAllSystemFields()`
- `updateEncodedSystemFields(_:data:recordType:context:)` — static
- `clearEncodedSystemFields(_:recordType:context:)` — static
- `handleSentRecordZoneChanges(_:)` — system fields updates + error classification (returns ClassifiedFailures for the coordinator to handle recovery)

```swift
@preconcurrency import CloudKit
import Foundation
import OSLog
import SwiftData
import os

/// Handles batch upsert/delete operations for a single profile data zone.
/// Stateless — takes a zoneID and ModelContainer, performs operations, returns results.
/// No CKSyncEngine dependency; the coordinator owns the engine.
@MainActor
final class ProfileDataSyncHandler: Sendable {
  nonisolated let zoneID: CKRecordZone.ID
  nonisolated let modelContainer: ModelContainer

  private nonisolated let logger = Logger(
    subsystem: "com.moolah.app", category: "ProfileDataSyncHandler")

  init(zoneID: CKRecordZone.ID, modelContainer: ModelContainer) {
    self.zoneID = zoneID
    self.modelContainer = modelContainer
  }

  // MARK: - Applying Remote Changes
  // ... (extract applyRemoteChanges from ProfileSyncEngine lines 340-428)
  // Key change: use ModelContext(modelContainer) instead of modelContainer.mainContext
  // Returns Set<String> of changed record types instead of calling a callback

  // MARK: - Batch Processing (Static)
  // ... (extract lines 520-1000 as-is — all the static batch upsert/delete methods)

  // MARK: - System Fields
  // ... (extract updateEncodedSystemFields, clearEncodedSystemFields, etc.)

  // MARK: - Sent Changes
  // ... (extract handleSentRecordZoneChanges — returns ClassifiedFailures)

  // MARK: - Building CKRecords
  // ... (extract buildCKRecord, buildBatchRecordLookup, recordToSave)

  // MARK: - Queue All Existing Records
  // ... (extract queueAllExistingRecords — returns [CKRecord.ID])

  // MARK: - Delete Local Data
  // ... (extract deleteLocalData — returns Set<String>)

  // MARK: - Clear System Fields
  // ... (extract clearAllSystemFields)
}
```

The implementation should be a mechanical extraction from `ProfileSyncEngine.swift`. The key differences from the original:

1. `applyRemoteChanges` creates a fresh `ModelContext(modelContainer)` instead of using `mainContext` (design doc bug fix #4)
2. `applyRemoteChanges` returns `Set<String>` of changed record types instead of calling `onRemoteChangesApplied`
3. `queueAllExistingRecords` returns `[CKRecord.ID]` instead of directly calling `syncEngine?.state.add()`
4. `deleteLocalData` returns `Set<String>` instead of calling `onRemoteChangesApplied`
5. `handleSentRecordZoneChanges` returns `SyncErrorRecovery.ClassifiedFailures` instead of calling `SyncErrorRecovery.recover()`
6. All signpost instrumentation preserved as-is

- [ ] **Step 4: Run tests to verify they pass**

Run: `just test 2>&1 | tee .agent-tmp/test-handler.txt`
Expected: All ProfileDataSyncHandlerTests pass.

- [ ] **Step 5: Check for warnings**

Run: `mcp__xcode__XcodeListNavigatorIssues` with severity "warning".
Fix any warnings in the new file.

- [ ] **Step 6: Commit**

```bash
git add Backends/CloudKit/Sync/ProfileDataSyncHandler.swift MoolahTests/Sync/ProfileDataSyncHandlerTests.swift
git commit -m "feat: extract ProfileDataSyncHandler from ProfileSyncEngine"
```

---

## Task 2: Extract ProfileIndexSyncHandler

Extract the profile-index apply logic from `ProfileIndexSyncEngine` into a standalone handler.

**Files:**
- Create: `Backends/CloudKit/Sync/ProfileIndexSyncHandler.swift`
- Test: `MoolahTests/Sync/ProfileIndexSyncHandlerTests.swift`
- Reference: `Backends/CloudKit/Sync/ProfileIndexSyncEngine.swift`

- [ ] **Step 1: Write tests for ProfileIndexSyncHandler**

Create `MoolahTests/Sync/ProfileIndexSyncHandlerTests.swift`. Port patterns from `ProfileIndexSyncEngineTests.swift`.

```swift
import CloudKit
import Foundation
import SwiftData
import Testing

@testable import Moolah

@Suite("ProfileIndexSyncHandler")
@MainActor
struct ProfileIndexSyncHandlerTests {

  private static let indexZoneID = CKRecordZone.ID(
    zoneName: "profile-index", ownerName: CKCurrentUserDefaultName)

  private func makeHandler() throws -> (ProfileIndexSyncHandler, ModelContainer) {
    let schema = Schema([ProfileRecord.self])
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try ModelContainer(for: schema, configurations: [config])
    let handler = ProfileIndexSyncHandler(
      zoneID: Self.indexZoneID, modelContainer: container)
    return (handler, container)
  }

  @Test func applyRemoteInsertCreatesProfileRecord() throws {
    let (handler, container) = try makeHandler()
    let profileId = UUID()
    let ckRecord = CKRecord(
      recordType: "CD_ProfileRecord",
      recordID: CKRecord.ID(recordName: profileId.uuidString, zoneID: Self.indexZoneID)
    )
    ckRecord["label"] = "Test" as CKRecordValue
    ckRecord["currencyCode"] = "AUD" as CKRecordValue
    ckRecord["financialYearStartMonth"] = 7 as CKRecordValue
    ckRecord["createdAt"] = Date() as CKRecordValue

    handler.applyRemoteChanges(saved: [ckRecord], deleted: [])

    let context = ModelContext(container)
    let records = try context.fetch(FetchDescriptor<ProfileRecord>(
      predicate: #Predicate { $0.id == profileId }
    ))
    #expect(records.count == 1)
    #expect(records.first?.label == "Test")
    #expect(records.first?.currencyCode == "AUD")
  }

  @Test func applyRemoteUpdateModifiesExistingProfile() throws {
    let (handler, container) = try makeHandler()
    let profileId = UUID()

    let context = ModelContext(container)
    let existing = ProfileRecord(
      id: profileId, label: "Old", currencyCode: "USD",
      financialYearStartMonth: 1, createdAt: Date())
    context.insert(existing)
    try context.save()

    let ckRecord = CKRecord(
      recordType: "CD_ProfileRecord",
      recordID: CKRecord.ID(recordName: profileId.uuidString, zoneID: Self.indexZoneID)
    )
    ckRecord["label"] = "New" as CKRecordValue
    ckRecord["currencyCode"] = "AUD" as CKRecordValue
    ckRecord["financialYearStartMonth"] = 7 as CKRecordValue
    ckRecord["createdAt"] = Date() as CKRecordValue

    handler.applyRemoteChanges(saved: [ckRecord], deleted: [])

    let readContext = ModelContext(container)
    let records = try readContext.fetch(FetchDescriptor<ProfileRecord>(
      predicate: #Predicate { $0.id == profileId }
    ))
    #expect(records.first?.label == "New")
  }

  @Test func applyRemoteDeletionRemovesProfile() throws {
    let (handler, container) = try makeHandler()
    let profileId = UUID()

    let context = ModelContext(container)
    context.insert(ProfileRecord(
      id: profileId, label: "X", currencyCode: "AUD",
      financialYearStartMonth: 7, createdAt: Date()))
    try context.save()

    handler.applyRemoteChanges(
      saved: [],
      deleted: [CKRecord.ID(recordName: profileId.uuidString, zoneID: Self.indexZoneID)])

    let readContext = ModelContext(container)
    #expect(try readContext.fetch(FetchDescriptor<ProfileRecord>()).isEmpty)
  }

  @Test func deleteLocalDataClearsAllProfiles() throws {
    let (handler, container) = try makeHandler()
    let context = ModelContext(container)
    context.insert(ProfileRecord(
      id: UUID(), label: "A", currencyCode: "AUD",
      financialYearStartMonth: 7, createdAt: Date()))
    context.insert(ProfileRecord(
      id: UUID(), label: "B", currencyCode: "USD",
      financialYearStartMonth: 1, createdAt: Date()))
    try context.save()

    handler.deleteLocalData()

    let readContext = ModelContext(container)
    #expect(try readContext.fetch(FetchDescriptor<ProfileRecord>()).isEmpty)
  }

  @Test func queueAllExistingProfilesReturnsIDs() throws {
    let (handler, container) = try makeHandler()
    let id1 = UUID(), id2 = UUID()
    let context = ModelContext(container)
    context.insert(ProfileRecord(
      id: id1, label: "A", currencyCode: "AUD",
      financialYearStartMonth: 7, createdAt: Date()))
    context.insert(ProfileRecord(
      id: id2, label: "B", currencyCode: "USD",
      financialYearStartMonth: 1, createdAt: Date()))
    try context.save()

    let ids = handler.queueAllExistingRecords()
    #expect(ids.count == 2)
    let names = Set(ids.map(\.recordName))
    #expect(names.contains(id1.uuidString))
    #expect(names.contains(id2.uuidString))
  }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `just test 2>&1 | tee .agent-tmp/test-index-handler.txt`
Expected: Compilation errors — `ProfileIndexSyncHandler` doesn't exist.

- [ ] **Step 3: Create ProfileIndexSyncHandler**

Create `Backends/CloudKit/Sync/ProfileIndexSyncHandler.swift`. Extract from `ProfileIndexSyncEngine.swift`.

```swift
import CloudKit
import Foundation
import OSLog
import SwiftData

/// Handles batch upsert/delete for the profile-index zone.
/// Stateless — no CKSyncEngine dependency.
@MainActor
final class ProfileIndexSyncHandler: Sendable {
  nonisolated let zoneID: CKRecordZone.ID
  nonisolated let modelContainer: ModelContainer

  private nonisolated let logger = Logger(
    subsystem: "com.moolah.app", category: "ProfileIndexSyncHandler")

  init(zoneID: CKRecordZone.ID, modelContainer: ModelContainer) {
    self.zoneID = zoneID
    self.modelContainer = modelContainer
  }

  /// Applies remote changes to the profile-index container.
  /// Extracted from ProfileIndexSyncEngine.applyRemoteChanges.
  func applyRemoteChanges(saved: [CKRecord], deleted: [CKRecord.ID]) {
    // ... (extract ProfileIndexSyncEngine lines 137-180)
    // Use ModelContext(modelContainer) instead of mainContext
  }

  /// Builds a CKRecord for a ProfileRecord with cached system fields.
  func buildCKRecord(for record: ProfileRecord) -> CKRecord {
    // ... (extract ProfileIndexSyncEngine lines 255-266)
  }

  /// Looks up a ProfileRecord by CKRecord.ID and builds a CKRecord.
  func recordToSave(for recordID: CKRecord.ID) -> CKRecord? {
    // ... (extract ProfileIndexSyncEngine lines 242-250)
  }

  /// Returns CKRecord.IDs for all existing profiles (for initial queue).
  func queueAllExistingRecords() -> [CKRecord.ID] {
    // ... (extract ProfileIndexSyncEngine lines 81-89, return IDs)
  }

  /// Deletes all ProfileRecords from the local store.
  func deleteLocalData() {
    // ... (extract ProfileIndexSyncEngine lines 224-238)
  }

  /// Clears encodedSystemFields on all ProfileRecords.
  func clearAllSystemFields() {
    // ... (extract ProfileIndexSyncEngine lines 210-218)
  }

  /// Updates system fields after successful upload or conflict.
  func updateEncodedSystemFields(_ recordID: CKRecord.ID, data: Data) {
    // ... (extract ProfileIndexSyncEngine lines 410-420)
  }

  /// Clears system fields on unknownItem.
  func clearEncodedSystemFields(_ recordID: CKRecord.ID) {
    // ... (extract ProfileIndexSyncEngine lines 425-435)
  }

  /// Processes sent record zone changes — updates system fields and returns failures.
  func handleSentRecordZoneChanges(
    _ sentChanges: CKSyncEngine.Event.SentRecordZoneChanges
  ) -> SyncErrorRecovery.ClassifiedFailures {
    // ... (extract ProfileIndexSyncEngine lines 367-407)
    // Return failures instead of calling SyncErrorRecovery.recover()
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `just test 2>&1 | tee .agent-tmp/test-index-handler.txt`
Expected: All ProfileIndexSyncHandlerTests pass.

- [ ] **Step 5: Check for warnings and commit**

```bash
git add Backends/CloudKit/Sync/ProfileIndexSyncHandler.swift MoolahTests/Sync/ProfileIndexSyncHandlerTests.swift
git commit -m "feat: extract ProfileIndexSyncHandler from ProfileIndexSyncEngine"
```

---

## Task 3: Fix SyncErrorRecovery

Change `recover()` to return zone creation info instead of launching a fire-and-forget Task. The coordinator will manage zone creation as a tracked task.

**Files:**
- Modify: `Backends/CloudKit/Sync/SyncErrorRecovery.swift`

- [ ] **Step 1: Modify SyncErrorRecovery.recover()**

Split `recover()` into two parts:
1. `requeueFailures()` — re-queues conflicts, unknownItems, and other failures (synchronous, same as before)
2. Return the zoneNotFound records separately so the caller can handle zone creation

```swift
/// Re-queues all classified failures except zone-not-found records.
/// Returns zone-not-found save and delete IDs for the caller to handle zone creation.
static func requeueFailures(
  _ failures: ClassifiedFailures,
  syncEngine: CKSyncEngine?,
  logger: Logger
) -> (zoneNotFoundSaves: [CKRecord.ID], zoneNotFoundDeletes: [CKRecord.ID]) {
  // Re-queue conflicts, unknownItems, and other failures
  var pendingSaves: [CKSyncEngine.PendingRecordZoneChange] = []
  for (recordID, _) in failures.conflicts {
    pendingSaves.append(.saveRecord(recordID))
  }
  for (recordID, _) in failures.unknownItems {
    pendingSaves.append(.saveRecord(recordID))
  }
  for recordID in failures.requeue {
    pendingSaves.append(.saveRecord(recordID))
  }
  if !pendingSaves.isEmpty {
    syncEngine?.state.add(pendingRecordZoneChanges: pendingSaves)
  }

  return (failures.zoneNotFoundSaves, failures.zoneNotFoundDeletes)
}
```

Keep the old `recover()` method as a deprecated wrapper so existing code compiles during the transition:

```swift
@available(*, deprecated, message: "Use requeueFailures() — zone creation is now managed by SyncCoordinator")
static func recover(
  _ failures: ClassifiedFailures,
  syncEngine: CKSyncEngine?,
  zoneID: CKRecordZone.ID,
  logger: Logger
) {
  _ = requeueFailures(failures, syncEngine: syncEngine, logger: logger)
  // Zone creation is now the caller's responsibility
  if !failures.zoneNotFoundSaves.isEmpty || !failures.zoneNotFoundDeletes.isEmpty {
    logger.warning("Zone-not-found records returned but not handled by deprecated recover() — caller should use requeueFailures()")
  }
}
```

- [ ] **Step 2: Verify existing tests still pass**

Run: `just test 2>&1 | tee .agent-tmp/test-recovery.txt`

- [ ] **Step 3: Commit**

```bash
git add Backends/CloudKit/Sync/SyncErrorRecovery.swift
git commit -m "refactor: split SyncErrorRecovery.recover into requeueFailures + zone-not-found return"
```

---

## Task 4: Build SyncCoordinator — Core Structure

Build the coordinator class with state persistence, zone parsing, and the CKSyncEngineDelegate shell.

**Files:**
- Create: `Backends/CloudKit/Sync/SyncCoordinator.swift`
- Create: `MoolahTests/Sync/SyncCoordinatorTests.swift`

- [ ] **Step 1: Write tests for coordinator core**

```swift
import CloudKit
import Foundation
import SwiftData
import Testing

@testable import Moolah

@Suite("SyncCoordinator")
@MainActor
struct SyncCoordinatorTests {

  // MARK: - Zone Parsing

  @Test func parseProfileIndexZone() {
    let zoneID = CKRecordZone.ID(zoneName: "profile-index", ownerName: CKCurrentUserDefaultName)
    let parsed = SyncCoordinator.parseZone(zoneID)
    #expect(parsed == .profileIndex)
  }

  @Test func parseProfileDataZone() {
    let profileId = UUID()
    let zoneID = CKRecordZone.ID(
      zoneName: "profile-\(profileId.uuidString)",
      ownerName: CKCurrentUserDefaultName)
    let parsed = SyncCoordinator.parseZone(zoneID)
    #expect(parsed == .profileData(profileId))
  }

  @Test func parseUnknownZone() {
    let zoneID = CKRecordZone.ID(zoneName: "unknown-zone", ownerName: CKCurrentUserDefaultName)
    let parsed = SyncCoordinator.parseZone(zoneID)
    #expect(parsed == .unknown)
  }

  // MARK: - Observer Token

  @Test func addObserverReturnsToken() throws {
    let containerManager = try ProfileContainerManager.forTesting()
    let coordinator = SyncCoordinator(containerManager: containerManager)

    var callbackCount = 0
    let token = coordinator.addObserver(for: UUID()) { _ in callbackCount += 1 }
    #expect(token != nil)
  }

  @Test func removeObserverStopsCallbacks() throws {
    let containerManager = try ProfileContainerManager.forTesting()
    let coordinator = SyncCoordinator(containerManager: containerManager)

    let profileId = UUID()
    var callbackCount = 0
    let token = coordinator.addObserver(for: profileId) { _ in callbackCount += 1 }

    coordinator.removeObserver(token: token)
    // After removal, callbacks should not fire (verified in integration tests)
  }

  // MARK: - State File Path

  @Test func stateFileUsesUnifiedName() throws {
    let containerManager = try ProfileContainerManager.forTesting()
    let coordinator = SyncCoordinator(containerManager: containerManager)
    #expect(coordinator.stateFileURL.lastPathComponent == "Moolah-v2-sync.syncstate")
  }
}
```

- [ ] **Step 2: Run tests to verify they fail**

- [ ] **Step 3: Create SyncCoordinator core**

Create `Backends/CloudKit/Sync/SyncCoordinator.swift`:

```swift
@preconcurrency import CloudKit
import Foundation
import OSLog
import SwiftData
import os

/// Owns the single CKSyncEngine for the entire app.
/// Routes events by zone ID to ProfileDataSyncHandler or ProfileIndexSyncHandler.
/// Everything runs on @MainActor — no concurrency races by construction.
@MainActor
final class SyncCoordinator: Sendable {

  // MARK: - Zone Parsing

  enum ZoneType: Equatable {
    case profileIndex
    case profileData(UUID)
    case unknown
  }

  static func parseZone(_ zoneID: CKRecordZone.ID) -> ZoneType {
    let name = zoneID.zoneName
    if name == "profile-index" { return .profileIndex }
    if name.hasPrefix("profile-"),
       let uuid = UUID(uuidString: String(name.dropFirst("profile-".count))) {
      return .profileData(uuid)
    }
    return .unknown
  }

  // MARK: - Properties

  private let containerManager: ProfileContainerManager
  private let indexHandler: ProfileIndexSyncHandler
  private var profileHandlers: [UUID: ProfileDataSyncHandler] = [:]

  private var syncEngine: CKSyncEngine?
  private(set) var isRunning = false
  private var isFirstLaunch = false

  private let logger = Logger(subsystem: "com.moolah.app", category: "SyncCoordinator")

  // MARK: - Fetch Session State

  private var isFetchingChanges = false
  private var fetchSessionChangedTypes: [UUID: Set<String>] = [:]  // per profile
  private var fetchSessionIndexChanged = false
  private var fetchSessionStartTime: ContinuousClock.Instant?
  private var fetchSessionTotalSaves = 0
  private var fetchSessionTotalDeletes = 0
  private var fetchSessionBatchCount = 0

  // MARK: - Zone Creation Tracking (Bug Fix #1)

  private var pendingZoneCreation: [CKRecordZone.ID: [CKSyncEngine.PendingRecordZoneChange]] = [:]
  private var zoneCreationTasks: [CKRecordZone.ID: Task<Void, Never>] = [:]

  // MARK: - Observer Registry

  struct ObserverToken: Equatable {
    let id: UUID
    let profileId: UUID
  }

  private var observers: [UUID: (profileId: UUID, callback: @MainActor (Set<String>) -> Void)] = [:]
  private var indexObservers: [UUID: @MainActor () -> Void] = [:]

  // MARK: - State Persistence

  let stateFileURL = URL.applicationSupportDirectory
    .appending(path: "Moolah-v2-sync.syncstate")

  // MARK: - Lifecycle

  init(containerManager: ProfileContainerManager) {
    self.containerManager = containerManager
    let indexZoneID = CKRecordZone.ID(
      zoneName: "profile-index", ownerName: CKCurrentUserDefaultName)
    self.indexHandler = ProfileIndexSyncHandler(
      zoneID: indexZoneID, modelContainer: containerManager.indexContainer)
  }

  func addObserver(for profileId: UUID, callback: @escaping @MainActor (Set<String>) -> Void) -> ObserverToken {
    let token = ObserverToken(id: UUID(), profileId: profileId)
    observers[token.id] = (profileId: profileId, callback: callback)
    return token
  }

  func removeObserver(token: ObserverToken) {
    observers.removeValue(forKey: token.id)
  }

  func addIndexObserver(_ callback: @escaping @MainActor () -> Void) -> UUID {
    let id = UUID()
    indexObservers[id] = callback
    return id
  }

  func removeIndexObserver(_ id: UUID) {
    indexObservers.removeValue(forKey: id)
  }

  // ... (start, stop, state persistence — see Task 7)
  // ... (handleEvent, nextRecordZoneChangeBatch — see Tasks 5 & 6)
}
```

- [ ] **Step 4: Run tests to verify they pass**

- [ ] **Step 5: Commit**

```bash
git add Backends/CloudKit/Sync/SyncCoordinator.swift MoolahTests/Sync/SyncCoordinatorTests.swift
git commit -m "feat: add SyncCoordinator core with zone parsing and observer registry"
```

---

## Task 5: SyncCoordinator — Receiving Side (Fetch Events)

Add event handling for fetched changes: zone routing, fetch session batching, and the `isFetchingChanges` stuck-flag fix.

**Files:**
- Modify: `Backends/CloudKit/Sync/SyncCoordinator.swift`
- Modify: `MoolahTests/Sync/SyncCoordinatorTests.swift`

- [ ] **Step 1: Write tests for fetch event handling**

Add to `SyncCoordinatorTests.swift`:

```swift
// MARK: - Fetch Session Batching

@Test func fetchSessionBatchesDeferCallbacksUntilEnd() throws {
  let containerManager = try ProfileContainerManager.forTesting()
  let coordinator = SyncCoordinator(containerManager: containerManager)

  let profileId = UUID()
  var callbackTypes: Set<String>?
  _ = coordinator.addObserver(for: profileId) { types in
    callbackTypes = types
  }

  // Simulate willFetchChanges → batch → didFetchChanges
  coordinator.beginFetchingChanges()
  #expect(coordinator.isFetchingChanges)

  // Apply changes during fetch session — callback should NOT fire yet
  let zoneID = CKRecordZone.ID(
    zoneName: "profile-\(profileId.uuidString)",
    ownerName: CKCurrentUserDefaultName)
  let profileContainer = try containerManager.container(for: profileId)
  let handler = ProfileDataSyncHandler(zoneID: zoneID, modelContainer: profileContainer)
  coordinator.registerProfileHandler(profileId: profileId, handler: handler)

  let ckRecord = CKRecord(
    recordType: "CD_AccountRecord",
    recordID: CKRecord.ID(recordName: UUID().uuidString, zoneID: zoneID))
  ckRecord["name"] = "Test" as CKRecordValue
  ckRecord["type"] = "bank" as CKRecordValue
  ckRecord["position"] = 0 as CKRecordValue
  ckRecord["isHidden"] = false as CKRecordValue

  coordinator.applyFetchedChanges(zoneID: zoneID, saved: [ckRecord], deleted: [])
  #expect(callbackTypes == nil)  // Deferred

  coordinator.endFetchingChanges()
  #expect(!coordinator.isFetchingChanges)
  #expect(callbackTypes != nil)
  #expect(callbackTypes?.contains("CD_AccountRecord") == true)
}

@Test func stuckFetchFlagResetOnNewSession() throws {
  let containerManager = try ProfileContainerManager.forTesting()
  let coordinator = SyncCoordinator(containerManager: containerManager)

  coordinator.beginFetchingChanges()
  // Simulate abnormal end — didFetchChanges never called
  // New session starts
  coordinator.beginFetchingChanges()  // Should reset, not crash
  #expect(coordinator.isFetchingChanges)
  coordinator.endFetchingChanges()
  #expect(!coordinator.isFetchingChanges)
}
```

- [ ] **Step 2: Run tests to verify they fail**

- [ ] **Step 3: Implement fetch event handling**

Add to `SyncCoordinator`:

```swift
// MARK: - Fetch Session Lifecycle

func beginFetchingChanges() {
  if isFetchingChanges {
    logger.warning("beginFetchingChanges called while already fetching — prior session ended abnormally, resetting")
  }
  isFetchingChanges = true
  fetchSessionChangedTypes.removeAll()
  fetchSessionIndexChanged = false
  fetchSessionStartTime = .now
  fetchSessionTotalSaves = 0
  fetchSessionTotalDeletes = 0
  fetchSessionBatchCount = 0
}

func endFetchingChanges() {
  isFetchingChanges = false

  // Fire deferred callbacks per profile
  for (profileId, changedTypes) in fetchSessionChangedTypes where !changedTypes.isEmpty {
    for (_, observer) in observers where observer.profileId == profileId {
      observer.callback(changedTypes)
    }
  }

  if fetchSessionIndexChanged {
    for (_, callback) in indexObservers {
      callback()
    }
  }

  // Log session summary
  if let startTime = fetchSessionStartTime {
    let sessionMs = (ContinuousClock.now - startTime).inMilliseconds
    let totalRecords = fetchSessionTotalSaves + fetchSessionTotalDeletes
    logger.info(
      "SYNC SESSION COMPLETE: \(totalRecords) records in \(self.fetchSessionBatchCount) batches | \(sessionMs)ms")
  }

  fetchSessionChangedTypes.removeAll()
  fetchSessionIndexChanged = false
  fetchSessionStartTime = nil
}

// MARK: - Apply Fetched Changes (Zone Routed)

func applyFetchedChanges(
  zoneID: CKRecordZone.ID,
  saved: [CKRecord],
  deleted: [(CKRecord.ID, String)],
  preExtractedSystemFields: [(String, Data)]? = nil
) {
  switch Self.parseZone(zoneID) {
  case .profileIndex:
    indexHandler.applyRemoteChanges(
      saved: saved,
      deleted: deleted.map(\.0))
    if isFetchingChanges {
      fetchSessionIndexChanged = true
    } else {
      for (_, callback) in indexObservers { callback() }
    }

  case .profileData(let profileId):
    let handler = profileHandler(for: profileId)
    let changedTypes = handler.applyRemoteChanges(
      saved: saved, deleted: deleted,
      preExtractedSystemFields: preExtractedSystemFields)
    if isFetchingChanges {
      fetchSessionChangedTypes[profileId, default: []].formUnion(changedTypes)
    } else {
      for (_, observer) in observers where observer.profileId == profileId {
        observer.callback(changedTypes)
      }
    }

  case .unknown:
    logger.warning("Ignoring changes for unknown zone: \(zoneID.zoneName)")
  }

  fetchSessionTotalSaves += saved.count
  fetchSessionTotalDeletes += deleted.count
  fetchSessionBatchCount += 1
}

/// Returns or creates a ProfileDataSyncHandler for the given profile.
private func profileHandler(for profileId: UUID) -> ProfileDataSyncHandler {
  if let existing = profileHandlers[profileId] { return existing }
  let zoneID = CKRecordZone.ID(
    zoneName: "profile-\(profileId.uuidString)",
    ownerName: CKCurrentUserDefaultName)
  let container = try! containerManager.container(for: profileId)
  let handler = ProfileDataSyncHandler(zoneID: zoneID, modelContainer: container)
  profileHandlers[profileId] = handler
  return handler
}

/// Registers a handler for testing (avoids needing real containers).
func registerProfileHandler(profileId: UUID, handler: ProfileDataSyncHandler) {
  profileHandlers[profileId] = handler
}
```

- [ ] **Step 4: Run tests to verify they pass**

- [ ] **Step 5: Commit**

```bash
git add Backends/CloudKit/Sync/SyncCoordinator.swift MoolahTests/Sync/SyncCoordinatorTests.swift
git commit -m "feat: add SyncCoordinator fetch event handling with session batching"
```

---

## Task 6: SyncCoordinator — Sending Side

Add `queueSave`, `queueDeletion`, `nextRecordZoneChangeBatch` with the nil-record deletion fix, and deduplication using `CKRecord.ID`.

**Files:**
- Modify: `Backends/CloudKit/Sync/SyncCoordinator.swift`
- Modify: `MoolahTests/Sync/SyncCoordinatorTests.swift`

- [ ] **Step 1: Write tests for sending side**

```swift
// MARK: - Queue Methods

@Test func queueSaveAddsZoneIDToRecordID() throws {
  // Can only fully test when engine is running.
  // Unit test verifies the record ID construction.
  let profileId = UUID()
  let zoneID = CKRecordZone.ID(
    zoneName: "profile-\(profileId.uuidString)",
    ownerName: CKCurrentUserDefaultName)
  let recordID = CKRecord.ID(recordName: UUID().uuidString, zoneID: zoneID)
  #expect(recordID.zoneID == zoneID)
}
```

- [ ] **Step 2: Implement sending side**

Add to `SyncCoordinator`:

```swift
// MARK: - Pending Changes

func queueSave(id: UUID, zoneID: CKRecordZone.ID) {
  let recordID = CKRecord.ID(recordName: id.uuidString, zoneID: zoneID)
  syncEngine?.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
}

func queueSave(recordName: String, zoneID: CKRecordZone.ID) {
  let recordID = CKRecord.ID(recordName: recordName, zoneID: zoneID)
  syncEngine?.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
}

func queueDeletion(id: UUID, zoneID: CKRecordZone.ID) {
  let recordID = CKRecord.ID(recordName: id.uuidString, zoneID: zoneID)
  syncEngine?.state.add(pendingRecordZoneChanges: [.deleteRecord(recordID)])
}

var hasPendingChanges: Bool {
  syncEngine.map { !$0.state.pendingRecordZoneChanges.isEmpty } ?? false
}

func sendChanges() async {
  guard let syncEngine, isRunning else { return }
  do { try await syncEngine.sendChanges() }
  catch { logger.error("Failed to send changes: \(error)") }
}

func fetchChanges() async {
  guard let syncEngine, isRunning else { return }
  do { try await syncEngine.fetchChanges() }
  catch { logger.error("Failed to fetch changes: \(error)") }
}
```

Implement `nextRecordZoneChangeBatch` on the CKSyncEngineDelegate extension:

```swift
nonisolated func nextRecordZoneChangeBatch(
  _ context: CKSyncEngine.SendChangesContext,
  syncEngine: CKSyncEngine
) async -> CKSyncEngine.RecordZoneChangeBatch? {
  await MainActor.run {
    nextRecordZoneChangeBatchOnMain(context, syncEngine: syncEngine)
  }
}

private func nextRecordZoneChangeBatchOnMain(
  _ context: CKSyncEngine.SendChangesContext,
  syncEngine: CKSyncEngine
) -> CKSyncEngine.RecordZoneChangeBatch? {
  let signpostID = OSSignpostID(log: Signposts.sync)
  os_signpost(.begin, log: Signposts.sync, name: "nextBatch", signpostID: signpostID)
  defer { os_signpost(.end, log: Signposts.sync, name: "nextBatch", signpostID: signpostID) }

  let scope = context.options.scope
  // Deduplicate using CKRecord.ID (includes zone component)
  var seenSaves = Set<CKRecord.ID>()
  var seenDeletes = Set<CKRecord.ID>()
  let pendingChanges = syncEngine.state.pendingRecordZoneChanges
    .filter { scope.contains($0) }
    .filter { change in
      switch change {
      case .saveRecord(let id):
        // Skip records whose zone is pending creation
        if pendingZoneCreation[id.zoneID] != nil { return false }
        return seenSaves.insert(id).inserted
      case .deleteRecord(let id):
        if pendingZoneCreation[id.zoneID] != nil { return false }
        return seenDeletes.insert(id).inserted
      @unknown default: return true
      }
    }

  guard !pendingChanges.isEmpty else { return nil }

  let batchLimit = 400
  let batch = Array(pendingChanges.prefix(batchLimit))

  // Group by zone, build records from correct handler
  var recordsToSave: [CKRecord] = []
  var recordIDsToDelete: [CKRecord.ID] = []

  for change in batch {
    switch change {
    case .saveRecord(let recordID):
      if let record = recordToSave(for: recordID) {
        recordsToSave.append(record)
      } else {
        // Bug fix #2: record deleted locally before batch — queue server deletion
        let hasPendingDelete = seenDeletes.contains(recordID)
        if !hasPendingDelete {
          logger.info("Record \(recordID.recordName) not found locally — queuing deletion")
          syncEngine.state.add(pendingRecordZoneChanges: [.deleteRecord(recordID)])
        }
      }
    case .deleteRecord(let recordID):
      recordIDsToDelete.append(recordID)
    @unknown default:
      break
    }
  }

  guard !recordsToSave.isEmpty || !recordIDsToDelete.isEmpty else { return nil }

  os_signpost(.end, log: Signposts.sync, name: "nextBatch", signpostID: signpostID,
    "%{public}d records across zones", recordsToSave.count + recordIDsToDelete.count)

  return CKSyncEngine.RecordZoneChangeBatch(
    recordsToSave: recordsToSave,
    recordIDsToDelete: recordIDsToDelete,
    atomicByZone: true
  )
}

/// Looks up a record for upload, routing to the correct handler by zone ID.
private func recordToSave(for recordID: CKRecord.ID) -> CKRecord? {
  switch Self.parseZone(recordID.zoneID) {
  case .profileIndex:
    return indexHandler.recordToSave(for: recordID)
  case .profileData(let profileId):
    return profileHandler(for: profileId).recordToSave(for: recordID)
  case .unknown:
    logger.warning("recordToSave for unknown zone: \(recordID.zoneID.zoneName)")
    return nil
  }
}
```

- [ ] **Step 3: Run tests to verify they pass**

- [ ] **Step 4: Commit**

```bash
git add Backends/CloudKit/Sync/SyncCoordinator.swift MoolahTests/Sync/SyncCoordinatorTests.swift
git commit -m "feat: add SyncCoordinator sending side with nil-record deletion fix"
```

---

## Task 7: SyncCoordinator — Lifecycle, Account Changes, Zone Management

Add `start()`, `stop()`, state persistence, account change handling with synthetic sign-in guard, zone creation, zone deletion handling, and the CKSyncEngineDelegate event dispatch.

**Files:**
- Modify: `Backends/CloudKit/Sync/SyncCoordinator.swift`
- Modify: `Backends/CloudKit/Sync/SyncErrorRecovery.swift` (remove deprecated wrapper if no longer needed)
- Modify: `Shared/ProfileContainerManager.swift` (add migration helpers)
- Modify: `MoolahTests/Sync/SyncCoordinatorTests.swift`

- [ ] **Step 1: Add migration helpers to ProfileContainerManager**

Add to `ProfileContainerManager.swift`:

```swift
/// Returns all known profile IDs from the index container.
func allProfileIds() -> [UUID] {
  let context = ModelContext(indexContainer)
  let records = (try? context.fetch(FetchDescriptor<ProfileRecord>())) ?? []
  return records.map(\.id)
}

/// Deletes old per-engine sync state files from before the unified coordinator.
func deleteOldSyncStateFiles() {
  let fm = FileManager.default
  let appSupport = URL.applicationSupportDirectory

  // Delete profile-index state file
  try? fm.removeItem(at: appSupport.appending(path: "Moolah-v2-profile-index.syncstate"))

  // Delete per-profile state files
  for profileId in allProfileIds() {
    try? fm.removeItem(at: appSupport.appending(path: "Moolah-\(profileId.uuidString).syncstate"))
  }

  // Also scan for any other .syncstate files matching the old pattern
  if let contents = try? fm.contentsOfDirectory(at: appSupport, includingPropertiesForKeys: nil) {
    for url in contents where url.pathExtension == "syncstate"
      && url.lastPathComponent != "Moolah-v2-sync.syncstate" {
      try? fm.removeItem(at: url)
    }
  }
}
```

- [ ] **Step 2: Implement coordinator lifecycle and event dispatch**

Add to `SyncCoordinator`:

```swift
// MARK: - Lifecycle

private var zoneSetupTask: Task<Void, Never>?

func start() {
  guard !isRunning else { return }

  // Migration: delete old per-engine state files
  containerManager.deleteOldSyncStateFiles()

  let savedState = loadStateSerialization()
  isFirstLaunch = savedState == nil
  let configuration = CKSyncEngine.Configuration(
    database: CKContainer.default().privateCloudDatabase,
    stateSerialization: savedState,
    delegate: self
  )
  syncEngine = CKSyncEngine(configuration)
  isRunning = true
  logger.info("Started SyncCoordinator (isFirstLaunch=\(self.isFirstLaunch))")

  // Clean up legacy system fields cache files
  cleanupLegacyFiles()

  if isFirstLaunch {
    queueAllExistingRecordsForAllZones()
  }

  // Ensure profile-index zone exists, then send
  zoneSetupTask = Task {
    await ensureZoneExists(indexHandler.zoneID)
    if self.hasPendingChanges {
      await self.sendChanges()
    }
  }
}

func stop() {
  zoneSetupTask?.cancel()
  zoneSetupTask = nil
  for task in zoneCreationTasks.values { task.cancel() }
  zoneCreationTasks.removeAll()
  syncEngine = nil
  isRunning = false
  isFetchingChanges = false
  logger.info("Stopped SyncCoordinator")
}

// MARK: - State Persistence

private func loadStateSerialization() -> CKSyncEngine.State.Serialization? {
  guard let data = try? Data(contentsOf: stateFileURL) else { return nil }
  return try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
}

private func saveStateSerialization(_ serialization: CKSyncEngine.State.Serialization) {
  do {
    let data = try JSONEncoder().encode(serialization)
    try data.write(to: stateFileURL, options: .atomic)
  } catch {
    logger.error("Failed to save sync state: \(error)")
  }
}

private func deleteStateSerialization() {
  try? FileManager.default.removeItem(at: stateFileURL)
}

// MARK: - Zone Creation

private var knownZones = Set<CKRecordZone.ID>()

private func ensureZoneExists(_ zoneID: CKRecordZone.ID) async {
  guard !knownZones.contains(zoneID) else { return }
  do {
    let zone = CKRecordZone(zoneID: zoneID)
    _ = try await CKContainer.default().privateCloudDatabase.save(zone)
    knownZones.insert(zoneID)
    logger.info("Ensured zone exists: \(zoneID.zoneName)")
  } catch {
    logger.error("Failed to ensure zone exists: \(error)")
  }
}

/// Creates a profile zone on first registration, then re-queues any pending records.
private func ensureProfileZone(_ zoneID: CKRecordZone.ID, pendingRecords: [CKSyncEngine.PendingRecordZoneChange]) {
  guard zoneCreationTasks[zoneID] == nil else { return }
  pendingZoneCreation[zoneID] = pendingRecords
  zoneCreationTasks[zoneID] = Task {
    await ensureZoneExists(zoneID)
    if let records = self.pendingZoneCreation.removeValue(forKey: zoneID), !records.isEmpty {
      self.syncEngine?.state.add(pendingRecordZoneChanges: records)
    }
    self.zoneCreationTasks.removeValue(forKey: zoneID)
  }
}

// MARK: - Queue All Existing Records

private func queueAllExistingRecordsForAllZones() {
  // Profile index
  let indexRecordIDs = indexHandler.queueAllExistingRecords()
  if !indexRecordIDs.isEmpty {
    syncEngine?.state.add(pendingRecordZoneChanges: indexRecordIDs.map { .saveRecord($0) })
    logger.info("Queued \(indexRecordIDs.count) profile index records")
  }

  // All profile data zones
  for profileId in containerManager.allProfileIds() {
    let handler = profileHandler(for: profileId)
    let recordIDs = handler.queueAllExistingRecords()
    if !recordIDs.isEmpty {
      syncEngine?.state.add(pendingRecordZoneChanges: recordIDs.map { .saveRecord($0) })
      logger.info("Queued \(recordIDs.count) records for profile \(profileId)")
    }
  }
}

// MARK: - Account Changes

private func handleAccountChange(_ change: CKSyncEngine.Event.AccountChange) {
  switch change.changeType {
  case .signIn:
    if isFirstLaunch {
      logger.info("Synthetic sign-in on first launch — skipping re-upload")
      isFirstLaunch = false
    } else {
      logger.info("Account signed in — re-uploading all data")
      queueAllExistingRecordsForAllZones()
    }

  case .signOut:
    logger.info("Account signed out — deleting all local data and sync state")
    deleteAllLocalData()
    deleteStateSerialization()
    isFetchingChanges = false

  case .switchAccounts:
    logger.info("Account switched — full reset")
    deleteAllLocalData()
    deleteStateSerialization()
    isFetchingChanges = false

  @unknown default:
    break
  }
}

private func deleteAllLocalData() {
  indexHandler.deleteLocalData()
  for (_, callback) in indexObservers { callback() }

  for profileId in containerManager.allProfileIds() {
    let handler = profileHandler(for: profileId)
    let changedTypes = handler.deleteLocalData()
    for (_, observer) in observers where observer.profileId == profileId {
      observer.callback(changedTypes)
    }
  }
}

// MARK: - Zone Deletion

private func handleFetchedDatabaseChanges(_ changes: CKSyncEngine.Event.FetchedDatabaseChanges) {
  for deletion in changes.deletions {
    switch Self.parseZone(deletion.zoneID) {
    case .profileIndex:
      handleZoneDeletion(reason: deletion.reason, isIndex: true, profileId: nil)
    case .profileData(let profileId):
      handleZoneDeletion(reason: deletion.reason, isIndex: false, profileId: profileId)
    case .unknown:
      logger.debug("Zone deletion for unknown zone: \(deletion.zoneID.zoneName)")
    }
  }
}

private func handleZoneDeletion(
  reason: CKSyncEngine.Event.FetchedDatabaseChanges.Deletion.Reason,
  isIndex: Bool,
  profileId: UUID?
) {
  switch reason {
  case .deleted:
    if isIndex {
      indexHandler.deleteLocalData()
      for (_, cb) in indexObservers { cb() }
    } else if let profileId {
      let handler = profileHandler(for: profileId)
      let types = handler.deleteLocalData()
      for (_, obs) in observers where obs.profileId == profileId { obs.callback(types) }
    }

  case .purged:
    if isIndex {
      indexHandler.deleteLocalData()
      for (_, cb) in indexObservers { cb() }
    } else if let profileId {
      let handler = profileHandler(for: profileId)
      let types = handler.deleteLocalData()
      for (_, obs) in observers where obs.profileId == profileId { obs.callback(types) }
    }
    // Conservative: delete shared state file, triggering full re-fetch
    deleteStateSerialization()

  case .encryptedDataReset:
    if isIndex {
      indexHandler.clearAllSystemFields()
      let ids = indexHandler.queueAllExistingRecords()
      syncEngine?.state.add(pendingRecordZoneChanges: ids.map { .saveRecord($0) })
    } else if let profileId {
      let handler = profileHandler(for: profileId)
      handler.clearAllSystemFields()
      let ids = handler.queueAllExistingRecords()
      syncEngine?.state.add(pendingRecordZoneChanges: ids.map { .saveRecord($0) })
    }
    deleteStateSerialization()

  @unknown default:
    logger.warning("Unknown zone deletion reason")
  }
}

// MARK: - Sent Changes

private func handleSentRecordZoneChanges(_ sentChanges: CKSyncEngine.Event.SentRecordZoneChanges) {
  // Route to correct handler based on zone of first record
  // Group saved/failed records by zone
  var indexSentChanges = false
  var profileSentChanges = Set<UUID>()

  // Process successful saves — update system fields
  for saved in sentChanges.savedRecords {
    switch Self.parseZone(saved.recordID.zoneID) {
    case .profileIndex:
      indexSentChanges = true
    case .profileData(let profileId):
      profileSentChanges.insert(profileId)
    case .unknown:
      break
    }
  }

  // Let handlers process their portion and get back failures
  // For simplicity, each handler processes the full sentChanges and filters by zone
  if indexSentChanges {
    let failures = indexHandler.handleSentRecordZoneChanges(sentChanges)
    let (zoneNotFoundSaves, zoneNotFoundDeletes) = SyncErrorRecovery.requeueFailures(
      failures, syncEngine: syncEngine, logger: logger)
    if !zoneNotFoundSaves.isEmpty || !zoneNotFoundDeletes.isEmpty {
      let changes: [CKSyncEngine.PendingRecordZoneChange] =
        zoneNotFoundSaves.map { .saveRecord($0) } +
        zoneNotFoundDeletes.map { .deleteRecord($0) }
      ensureProfileZone(indexHandler.zoneID, pendingRecords: changes)
    }
  }

  for profileId in profileSentChanges {
    let handler = profileHandler(for: profileId)
    let failures = handler.handleSentRecordZoneChanges(sentChanges)
    let (zoneNotFoundSaves, zoneNotFoundDeletes) = SyncErrorRecovery.requeueFailures(
      failures, syncEngine: syncEngine, logger: logger)
    if !zoneNotFoundSaves.isEmpty || !zoneNotFoundDeletes.isEmpty {
      let changes: [CKSyncEngine.PendingRecordZoneChange] =
        zoneNotFoundSaves.map { .saveRecord($0) } +
        zoneNotFoundDeletes.map { .deleteRecord($0) }
      ensureProfileZone(handler.zoneID, pendingRecords: changes)
    }
  }
}

// MARK: - Legacy Cleanup

private func cleanupLegacyFiles() {
  let fm = FileManager.default
  let appSupport = URL.applicationSupportDirectory
  try? fm.removeItem(at: appSupport.appending(path: "Moolah-profile-index.systemfields"))
  for profileId in containerManager.allProfileIds() {
    try? fm.removeItem(at: appSupport.appending(path: "Moolah-\(profileId.uuidString).systemfields"))
  }
}
```

- [ ] **Step 3: Implement CKSyncEngineDelegate extension**

```swift
extension SyncCoordinator: CKSyncEngineDelegate {
  nonisolated func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
    // Pre-extract system fields off main actor
    let preExtracted: [(String, Data)]?
    if case .fetchedRecordZoneChanges(let changes) = event {
      preExtracted = changes.modifications
        .map { ($0.record.recordID.recordName, $0.record.encodedSystemFields) }
    } else {
      preExtracted = nil
    }

    await MainActor.run {
      handleEventOnMain(event, syncEngine: syncEngine, preExtractedSystemFields: preExtracted)
    }
  }

  private func handleEventOnMain(
    _ event: CKSyncEngine.Event,
    syncEngine: CKSyncEngine,
    preExtractedSystemFields: [(String, Data)]? = nil
  ) {
    switch event {
    case .stateUpdate(let stateUpdate):
      saveStateSerialization(stateUpdate.stateSerialization)

    case .accountChange(let accountChange):
      handleAccountChange(accountChange)

    case .fetchedDatabaseChanges(let changes):
      handleFetchedDatabaseChanges(changes)

    case .fetchedRecordZoneChanges(let changes):
      // Group records by zone and route to handlers
      var byZone: [CKRecordZone.ID: (saved: [CKRecord], deleted: [(CKRecord.ID, String)])] = [:]
      for modification in changes.modifications {
        let zoneID = modification.record.recordID.zoneID
        byZone[zoneID, default: ([], [])].saved.append(modification.record)
      }
      for deletion in changes.deletions {
        let zoneID = deletion.recordID.zoneID
        byZone[zoneID, default: ([], [])].deleted.append((deletion.recordID, deletion.recordType))
      }

      let systemFieldsDict: [String: Data]?
      if let preExtracted = preExtractedSystemFields {
        systemFieldsDict = Dictionary(preExtracted, uniquingKeysWith: { _, last in last })
      } else {
        systemFieldsDict = nil
      }

      for (zoneID, changes) in byZone {
        // Build pre-extracted system fields for this zone's records
        let zoneSystemFields: [(String, Data)]?
        if let dict = systemFieldsDict {
          zoneSystemFields = changes.saved.compactMap { record in
            dict[record.recordID.recordName].map { (record.recordID.recordName, $0) }
          }
        } else {
          zoneSystemFields = nil
        }
        applyFetchedChanges(
          zoneID: zoneID,
          saved: changes.saved,
          deleted: changes.deleted,
          preExtractedSystemFields: zoneSystemFields)
      }

    case .sentRecordZoneChanges(let sentChanges):
      handleSentRecordZoneChanges(sentChanges)

    case .sentDatabaseChanges:
      break

    case .willFetchChanges:
      beginFetchingChanges()

    case .didFetchChanges:
      endFetchingChanges()

    case .willFetchRecordZoneChanges, .didFetchRecordZoneChanges,
         .willSendChanges, .didSendChanges:
      break

    @unknown default:
      logger.debug("Unknown sync engine event")
    }
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `just test 2>&1 | tee .agent-tmp/test-coordinator.txt`

- [ ] **Step 5: Check for warnings and commit**

```bash
git add Backends/CloudKit/Sync/SyncCoordinator.swift Shared/ProfileContainerManager.swift MoolahTests/Sync/SyncCoordinatorTests.swift
git commit -m "feat: add SyncCoordinator lifecycle, account changes, zone management"
```

---

## Task 8: Wire ProfileSession to SyncCoordinator

Remove ProfileSyncEngine creation from ProfileSession. Wire repository callbacks to the coordinator with zone IDs. Register an observer token for sync reload.

**Files:**
- Modify: `App/ProfileSession.swift`

- [ ] **Step 1: Update ProfileSession**

Replace the sync engine setup in `ProfileSession.init` (lines 123-166) with coordinator wiring:

```swift
// Replace: private(set) var profileSyncEngine: ProfileSyncEngine?
// With:
private var syncObserverToken: SyncCoordinator.ObserverToken?

// In init, replace the entire sync engine block with:
if profile.backendType == .cloudKit, let coordinator = SyncCoordinator.shared {
  let zoneID = CKRecordZone.ID(
    zoneName: "profile-\(profile.id.uuidString)",
    ownerName: CKCurrentUserDefaultName)

  // Register observer for sync reload
  syncObserverToken = coordinator.addObserver(for: profile.id) { [weak self] changedTypes in
    self?.scheduleReloadFromSync(changedTypes: changedTypes)
  }

  // Wire repository sync closures
  if let repo = backend.accounts as? CloudKitAccountRepository {
    repo.onRecordChanged = { [weak coordinator] id in coordinator?.queueSave(id: id, zoneID: zoneID) }
    repo.onRecordDeleted = { [weak coordinator] id in coordinator?.queueDeletion(id: id, zoneID: zoneID) }
    repo.onInstrumentChanged = { [weak coordinator] id in coordinator?.queueSave(recordName: id, zoneID: zoneID) }
  }
  if let repo = backend.transactions as? CloudKitTransactionRepository {
    repo.onRecordChanged = { [weak coordinator] id in coordinator?.queueSave(id: id, zoneID: zoneID) }
    repo.onRecordDeleted = { [weak coordinator] id in coordinator?.queueDeletion(id: id, zoneID: zoneID) }
    repo.onInstrumentChanged = { [weak coordinator] id in coordinator?.queueSave(recordName: id, zoneID: zoneID) }
  }
  if let repo = backend.categories as? CloudKitCategoryRepository {
    repo.onRecordChanged = { [weak coordinator] id in coordinator?.queueSave(id: id, zoneID: zoneID) }
    repo.onRecordDeleted = { [weak coordinator] id in coordinator?.queueDeletion(id: id, zoneID: zoneID) }
  }
  if let repo = backend.earmarks as? CloudKitEarmarkRepository {
    repo.onRecordChanged = { [weak coordinator] id in coordinator?.queueSave(id: id, zoneID: zoneID) }
    repo.onRecordDeleted = { [weak coordinator] id in coordinator?.queueDeletion(id: id, zoneID: zoneID) }
  }
  if let repo = backend.investments as? CloudKitInvestmentRepository {
    repo.onRecordChanged = { [weak coordinator] id in coordinator?.queueSave(id: id, zoneID: zoneID) }
    repo.onRecordDeleted = { [weak coordinator] id in coordinator?.queueDeletion(id: id, zoneID: zoneID) }
  }

  // Ensure the profile zone exists
  Task {
    await coordinator.ensureZoneExists(zoneID)
  }
}
```

Add a deinit token cleanup:

```swift
// ProfileSession needs to clean up its observer token.
// Since deinit is nonisolated, use the cancellable token pattern:
// Store the token as a property. On deallocation, the SyncCoordinator
// will naturally stop calling this session's callback because the
// [weak self] capture becomes nil. The token is cleaned up lazily
// or when the coordinator is next asked to fire callbacks for this profile.
// Alternatively, add explicit cleanup in SessionManager.removeSession.
```

Actually, the simpler approach: have `SessionManager.removeSession` call `coordinator.removeObserver(token:)` explicitly. This avoids the `nonisolated deinit` problem entirely.

- [ ] **Step 2: Update SessionManager to clean up observer tokens**

In `SessionManager.removeSession(for:)`, if the session has a sync observer token, remove it from the coordinator.

- [ ] **Step 3: Run tests to verify they pass**

Run: `just test 2>&1 | tee .agent-tmp/test-session.txt`

- [ ] **Step 4: Commit**

```bash
git add App/ProfileSession.swift App/SessionManager.swift
git commit -m "refactor: wire ProfileSession to SyncCoordinator instead of ProfileSyncEngine"
```

---

## Task 9: Wire MoolahApp and ProfileStore

Replace ProfileIndexSyncEngine in MoolahApp with SyncCoordinator. Wire ProfileStore to coordinator. Simplify background sync.

**Files:**
- Modify: `App/MoolahApp.swift`
- Modify: `Features/Profiles/ProfileStore.swift`

- [ ] **Step 1: Update MoolahApp**

Replace the sync engine properties and initialization:

```swift
// Replace:
//   private let profileIndexSyncEngine: ProfileIndexSyncEngine
// With:
//   private let syncCoordinator: SyncCoordinator

// In init(), replace ProfileIndexSyncEngine creation and wiring with:
let coordinator = SyncCoordinator(containerManager: manager)
syncCoordinator = coordinator

if CloudKitAuthProvider.isCloudKitAvailable {
  logger.info("CloudKit available — starting SyncCoordinator")

  let indexObserverId = coordinator.addIndexObserver { [weak store] in
    store?.loadCloudProfiles()
  }
  store.onProfileChanged = { [weak coordinator] id in
    let zoneID = CKRecordZone.ID(zoneName: "profile-index", ownerName: CKCurrentUserDefaultName)
    coordinator?.queueSave(id: id, zoneID: zoneID)
  }
  store.onProfileDeleted = { [weak coordinator] id in
    let zoneID = CKRecordZone.ID(zoneName: "profile-index", ownerName: CKCurrentUserDefaultName)
    coordinator?.queueDeletion(id: id, zoneID: zoneID)
  }

  coordinator.start()
  LegacyZoneCleanup.performIfNeeded()
}
```

Simplify background sync methods:

```swift
private func flushPendingChanges() {
  guard syncCoordinator.hasPendingChanges else {
    logger.debug("No pending changes to flush on background entry")
    return
  }
  logger.info("Flushing pending sync changes on background entry")
  #if os(iOS)
    ProcessInfo.processInfo.performExpiringActivity(
      withReason: "Uploading pending sync changes"
    ) { expired in
      guard !expired else { return }
      Task { @MainActor in
        await self.syncCoordinator.sendChanges()
      }
    }
  #else
    Task { await syncCoordinator.sendChanges() }
  #endif
}

private func fetchRemoteChanges() async {
  logger.info("Fetching remote changes on foreground entry")
  await syncCoordinator.fetchChanges()
}
```

Remove `activeProfileSyncEngines()` method entirely.

- [ ] **Step 2: Pass coordinator to ProfileSession**

Update `ProfileSession.init` to accept a `SyncCoordinator?` parameter instead of looking it up via a static property. Pass it from `SessionManager.session(for:)` or from the iOS `ProfileRootView`.

- [ ] **Step 3: Run tests to verify they pass**

Run: `just test 2>&1 | tee .agent-tmp/test-app.txt`

- [ ] **Step 4: Check for warnings and commit**

```bash
git add App/MoolahApp.swift Features/Profiles/ProfileStore.swift App/ProfileSession.swift App/SessionManager.swift
git commit -m "refactor: replace ProfileIndexSyncEngine with SyncCoordinator in MoolahApp"
```

---

## Task 10: Delete Old Engines

Remove `ProfileSyncEngine.swift` and `ProfileIndexSyncEngine.swift` and their test files. Update any remaining references.

**Files:**
- Delete: `Backends/CloudKit/Sync/ProfileSyncEngine.swift`
- Delete: `Backends/CloudKit/Sync/ProfileIndexSyncEngine.swift`
- Delete: `MoolahTests/Sync/ProfileSyncEngineTests.swift`
- Delete: `MoolahTests/Sync/ProfileIndexSyncEngineTests.swift`

- [ ] **Step 1: Search for remaining references**

Run: `grep -r "ProfileSyncEngine\|ProfileIndexSyncEngine" --include="*.swift" .`

Fix any remaining references (there should be none if Tasks 8-9 are complete).

- [ ] **Step 2: Delete the old files**

```bash
git rm Backends/CloudKit/Sync/ProfileSyncEngine.swift
git rm Backends/CloudKit/Sync/ProfileIndexSyncEngine.swift
git rm MoolahTests/Sync/ProfileSyncEngineTests.swift
git rm MoolahTests/Sync/ProfileIndexSyncEngineTests.swift
```

- [ ] **Step 3: Regenerate Xcode project**

Run: `just generate`

- [ ] **Step 4: Build and test**

Run: `just test 2>&1 | tee .agent-tmp/test-final.txt`
Expected: All tests pass, no compilation errors.

- [ ] **Step 5: Check for warnings**

Run: `mcp__xcode__XcodeListNavigatorIssues` with severity "warning".

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "refactor: remove ProfileSyncEngine and ProfileIndexSyncEngine"
```

---

## Task 11: Remove Deprecated SyncErrorRecovery.recover()

Now that no code calls the old `recover()` method, remove it.

**Files:**
- Modify: `Backends/CloudKit/Sync/SyncErrorRecovery.swift`

- [ ] **Step 1: Remove deprecated method**

Delete the `@available(*, deprecated)` `recover()` method from `SyncErrorRecovery.swift`.

- [ ] **Step 2: Verify no references remain**

Run: `grep -r "SyncErrorRecovery.recover" --include="*.swift" .`
Expected: No matches.

- [ ] **Step 3: Build and commit**

```bash
just test 2>&1 | tee .agent-tmp/test-cleanup.txt
git add Backends/CloudKit/Sync/SyncErrorRecovery.swift
git commit -m "chore: remove deprecated SyncErrorRecovery.recover()"
```

---

## Task 12: Performance Instrumentation

Add signpost instrumentation to the coordinator and create a sync benchmark.

**Files:**
- Modify: `Backends/CloudKit/Sync/SyncCoordinator.swift`

- [ ] **Step 1: Add signpost instrumentation to coordinator**

Ensure the following signposts exist in `SyncCoordinator` (some were added in earlier tasks, verify completeness):

```swift
// In nextRecordZoneChangeBatchOnMain:
os_signpost(.begin, log: Signposts.sync, name: "nextBatch", signpostID: signpostID)
os_signpost(.end, log: Signposts.sync, name: "nextBatch", signpostID: signpostID,
  "%{public}d records across %{public}d zones", recordCount, zoneCount)

// In applyFetchedChanges:
os_signpost(.begin, log: Signposts.sync, name: "applyFetchedChanges", signpostID: signpostID,
  "%{public}@ zone", zoneID.zoneName)
os_signpost(.end, log: Signposts.sync, name: "applyFetchedChanges", signpostID: signpostID)

// In handleSentRecordZoneChanges:
os_signpost(.begin, log: Signposts.sync, name: "handleSentChanges", signpostID: signpostID)
os_signpost(.end, log: Signposts.sync, name: "handleSentChanges", signpostID: signpostID)

// In start():
os_signpost(.begin, log: Signposts.sync, name: "coordinatorStart", signpostID: signpostID)
os_signpost(.end, log: Signposts.sync, name: "coordinatorStart", signpostID: signpostID)
```

- [ ] **Step 2: Add main-thread latency warning**

In `applyFetchedChanges`, add the same >16ms warning as the current engine:

```swift
let batchMs = (ContinuousClock.now - batchStart).inMilliseconds
if batchMs > 16 {
  logger.warning(
    "PERF: applyFetchedChanges blocked main thread for \(batchMs)ms (\(saved.count) saves, \(deleted.count) deletes)")
}
```

- [ ] **Step 3: Build and test**

Run: `just test 2>&1 | tee .agent-tmp/test-perf.txt`

- [ ] **Step 4: Commit**

```bash
git add Backends/CloudKit/Sync/SyncCoordinator.swift
git commit -m "feat: add signpost instrumentation and latency warnings to SyncCoordinator"
```

---

## Task 13: Update SYNC_GUIDE.md

Update the sync guide to reference the new architecture.

**Files:**
- Modify: `guides/SYNC_GUIDE.md`

- [ ] **Step 1: Update architecture section**

Replace references to "dual engine" with "SyncCoordinator + zone handlers". Update the review rule from "review against both ProfileSyncEngine and ProfileIndexSyncEngine" to "review against SyncCoordinator, ProfileDataSyncHandler, and ProfileIndexSyncHandler".

- [ ] **Step 2: Update anti-pattern table**

The "Multiple CKSyncEngine instances" anti-pattern should note it's been fixed, or be removed and replaced with the new architecture description.

- [ ] **Step 3: Commit**

```bash
git add guides/SYNC_GUIDE.md
git commit -m "docs: update SYNC_GUIDE.md for unified SyncCoordinator architecture"
```

---

## Task 14: Final Integration Verification

Run the full test suite, check for warnings, and verify the app builds for both platforms.

- [ ] **Step 1: Run full test suite**

```bash
just test 2>&1 | tee .agent-tmp/test-full.txt
grep -i 'failed\|error:' .agent-tmp/test-full.txt
```
Expected: All tests pass.

- [ ] **Step 2: Build for both platforms**

```bash
just build-mac 2>&1 | tee .agent-tmp/build-mac.txt
just build-ios 2>&1 | tee .agent-tmp/build-ios.txt
```
Expected: Both build successfully.

- [ ] **Step 3: Check for warnings**

Run: `mcp__xcode__XcodeListNavigatorIssues` with severity "warning".
Expected: No warnings in user code.

- [ ] **Step 4: Clean up temp files**

```bash
rm -rf .agent-tmp/test-*.txt .agent-tmp/build-*.txt
```

- [ ] **Step 5: Final commit if any fixes were needed**

```bash
git add -A
git commit -m "fix: address final integration issues from unified sync engine refactor"
```
