# CKSyncEngine Sync Guide

**Version:** 1.0
**Platform targets:** macOS 26+ (primary), iOS 26+ (secondary)

---

## 1. Architecture Overview

Two sync layers, each with their own CKSyncEngine instance:

1. **ProfileIndexSyncEngine** -- syncs `ProfileRecord` metadata via the `profile-index` zone
2. **ProfileSyncEngine** (one per active profile) -- syncs per-profile data via `profile-{profileId}` zones

Each engine has a corresponding change tracker that observes `NSManagedObjectContextDidSave` notifications to queue local changes for upload.

**Key files:**
- `Backends/CloudKit/Sync/ProfileSyncEngine.swift` -- per-profile sync engine
- `Backends/CloudKit/Sync/ProfileIndexSyncEngine.swift` -- profile index sync engine
- `Backends/CloudKit/Sync/ChangeTracker.swift` -- observes SwiftData saves, queues for upload
- `Backends/CloudKit/Sync/RecordMapping.swift` -- CKRecord <-> SwiftData bidirectional mapping
- `Backends/CloudKit/Sync/LegacyZoneCleanup.swift` -- one-time cleanup of old automatic sync zone

**Key Sources:**
- [WWDC23: Sync to iCloud with CKSyncEngine](https://developer.apple.com/videos/play/wwdc2023/10188/)
- [Apple's sample-cloudkit-sync-engine](https://github.com/apple/sample-cloudkit-sync-engine)
- [CKSyncEngine Apple Documentation](https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5)

---

## 2. Core Principles

### Let CKSyncEngine Drive Scheduling

CKSyncEngine manages its own scheduling, batching, and retry logic. Your job is to respond to events and provide records when asked.

```swift
// CORRECT: Add to pending queue; engine decides when to send
syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])

// WRONG: Manually triggering sync inside a delegate callback
func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
    // Never do this -- causes infinite loops
    try await syncEngine.sendChanges()
    try await syncEngine.fetchChanges()
}
```

### One Engine Per Database

Never run multiple CKSyncEngine instances against the same CloudKit database. They interfere with each other's change tokens and event routing.

Since this project uses two engines (ProfileIndex and ProfileSync), they must manage non-overlapping zones. This is safe because each engine is responsible for its own distinct zone(s).

### Initialize Early

Create and start CKSyncEngine as early as possible in the app lifecycle. The initializer is synchronous and immediately begins processing pending changes from the saved state serialization.

---

## 3. Rules

### Rule 1: Filter Notifications by Entity Type

**Bug found:** `NSManagedObjectContextDidSave` with `object: nil` catches saves from ALL ModelContainers. Without entity filtering, per-profile data saves (thousands of records) get queued as phantom pending changes in the ProfileIndexSyncEngine, bloating the sync state file and preventing real records from syncing.

**Rule:** Always filter notification objects by entity name before extracting IDs.

```swift
// CORRECT: Filter to only relevant entities
let inserted = (notification.userInfo?[NSInsertedObjectsKey] as? Set<NSManagedObject>)?
    .filter { $0.entity.name == "ProfileRecord" }

// WRONG: Processes ALL entities from ALL containers
let inserted = notification.userInfo?[NSInsertedObjectsKey] as? Set<NSManagedObject>
```

### Rule 2: Guard Against Re-uploading Remote Changes

**Bug found:** When `applyRemoteChanges()` saves fetched records to SwiftData, the save notification triggers the change tracker, which queues those records for upload back to CloudKit -- an unnecessary round-trip.

**Rule:** Set `isApplyingRemoteChanges = true` before saving remote changes, and check it in the notification observer.

```swift
func applyRemoteChanges(...) {
    isApplyingRemoteChanges = true
    defer { isApplyingRemoteChanges = false }
    // ... save to context
}

// In observer:
guard self?.isApplyingRemoteChanges != true else { return }
```

### Rule 3: Handle Zone Creation on First Send

**Bug found:** CKSyncEngine does NOT automatically create zones when sending records. The first send to a new zone fails with `CKError.zoneNotFound` (code 26/2036).

**Rule:** Handle `.zoneNotFound` errors in `sentRecordZoneChanges` by creating the zone and re-queuing the failed record.

```swift
if failed.error.code == .zoneNotFound {
    Task {
        let zone = CKRecordZone(zoneID: self.zoneID)
        try await CKContainer.default().privateCloudDatabase.save(zone)
        self.syncEngine?.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
    }
}
```

### Rule 4: Every SwiftData Write Must Be Tracked

**Bug found:** `ProfileIndexSyncEngine.addPendingSave()` existed but was never called -- profile records saved to SwiftData were never uploaded to CloudKit.

**Rule:** Every ModelContainer that syncs via CKSyncEngine must have a change tracker wired up. When adding a new syncable record type or container, verify the change tracker covers it.

### Rule 4b: Queue Existing Records on First Start

**Bug found:** Migration imports data into a profile's ModelContainer BEFORE the ProfileSyncEngine and ChangeTracker are created. The `NSManagedObjectContextDidSave` notifications fire during import, but no observer exists yet to catch them. Result: accounts and transactions sync (because the app modifies them after load, e.g., balance recomputation), but categories, earmarks, and investment values are never queued.

**Rule:** When a sync engine starts with no saved state (`loadStateSerialization()` returns nil), scan all existing records in the local store and queue them for upload.

```swift
func start() {
    let hasSavedState = loadStateSerialization() != nil
    // ... create and start engine ...

    if !hasSavedState {
        queueAllExistingRecords()  // Scan and queue all local records
    }
}
```

### Rule 5: Preserve CKRecord System Fields (Change Tags)

**Rationale:** When CKSyncEngine sends a record to CloudKit, the server checks the record's change tag to detect conflicts. If you create a fresh `CKRecord` every time (without the server's change tag), CloudKit treats every upload as a new record, causing `.serverRecordChanged` conflicts on multi-device sync.

**Rule:** After a record is successfully saved to CloudKit, persist the server-returned `CKRecord`'s system fields. Use these as the base for subsequent uploads.

```swift
// CORRECT: Preserve system fields after successful send
for saved in sentChanges.savedRecords {
    // Store the server record's system fields for future uploads
    let data = saved.encodedSystemFields
    persistSystemFields(data, for: saved.recordID)
}

// When building a record for upload, start from cached system fields
func buildCKRecord(for localRecord: SomeRecord) -> CKRecord {
    let ckRecord: CKRecord
    if let cachedSystemFields = loadSystemFields(for: localRecord.id) {
        // Re-create from cached system fields (preserves change tag)
        let coder = try NSKeyedUnarchiver(forReadingFrom: cachedSystemFields)
        coder.requiresSecureCoding = true
        ckRecord = CKRecord(coder: coder)!
    } else {
        // First upload -- create fresh record
        let recordID = CKRecord.ID(recordName: localRecord.id.uuidString, zoneID: zoneID)
        ckRecord = CKRecord(recordType: SomeRecord.recordType, recordID: recordID)
    }
    // Set field values on the record
    ckRecord["name"] = localRecord.name as CKRecordValue
    return ckRecord
}
```

**Helper to encode system fields:**

```swift
extension CKRecord {
    var encodedSystemFields: Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }
}
```

### Rule 6: Handle Conflict Resolution Explicitly

**Rationale:** When two devices modify the same record, the second upload receives `.serverRecordChanged`. The error's `userInfo` contains the server's current version. Ignoring this error means the second device's changes are silently lost.

**Rule:** On `.serverRecordChanged`, retrieve the server record from the error, merge or pick a winner, and re-queue the save.

```swift
// In handleSentRecordZoneChanges:
for failure in sentChanges.failedRecordSaves {
    switch failure.error.code {
    case .serverRecordChanged:
        // Server-wins strategy: accept server version, re-apply local fields if needed
        if let serverRecord = failure.error.serverRecord {
            persistSystemFields(serverRecord.encodedSystemFields, for: serverRecord.recordID)
            // Re-queue the save with updated system fields
            syncEngine?.state.add(pendingRecordZoneChanges: [.saveRecord(failure.record.recordID)])
        }
    // ... other error cases
    }
}
```

**Merge strategies (pick one per record type):**

| Strategy | When to Use | Complexity |
|----------|-------------|------------|
| **Server wins** | Single-user apps, records rarely edited concurrently | Low |
| **Last writer wins** | Simple multi-device, acceptable to lose concurrent edits | Low |
| **Field-level merge** | Multi-device, preserving all concurrent edits matters | Medium |

For this project, **server wins** is appropriate -- single-user, multi-device sync where concurrent edits to the same record are rare.

### Rule 7: Handle Zone Deletion Events Correctly

**Rationale:** Zone deletions arrive via `fetchedDatabaseChanges` with three distinct reasons that require different responses.

**Rule:** Check the deletion `reason` and respond appropriately.

```swift
func handleFetchedDatabaseChanges(_ changes: CKSyncEngine.Event.FetchedDatabaseChanges) {
    for deletion in changes.deletions where deletion.zoneID == zoneID {
        switch deletion.reason {
        case .deleted:
            // Programmatic deletion. Remove local data for this zone.
            deleteLocalData()

        case .purged:
            // User cleared iCloud data via Settings. Full reset required.
            deleteLocalData()
            deleteStateSerialization()
            // Engine will re-fetch from scratch

        case .encryptedDataReset:
            // User reset encrypted data during account recovery.
            // Delete state but re-upload local data to minimize loss.
            deleteStateSerialization()
            reUploadAllLocalData()

        @unknown default:
            logger.warning("Unknown zone deletion reason")
        }
    }
}
```

### Rule 8: Handle Account Changes

**Rationale:** When the iCloud account changes, the locally cached change tokens and data belong to a different user. Continuing to sync would mix data between accounts.

**Rule:** Respond to all three account change types.

```swift
func handleAccountChange(_ change: CKSyncEngine.Event.AccountChange) {
    switch change.changeType {
    case .signIn:
        // Going from no account to signed in.
        // Re-upload all local data so it appears in the new account.
        reUploadAllLocalData()

    case .signOut:
        // Account removed. Delete local synced data and state.
        // The device may have changed hands.
        deleteLocalData()
        deleteStateSerialization()

    case .switchAccounts:
        // Different account on relaunch. Full reset.
        deleteLocalData()
        deleteStateSerialization()
        // Engine will fetch the new account's data on next sync

    @unknown default:
        break
    }
}
```

**Note:** Initializing CKSyncEngine without saved state always fires `.accountChange(.signIn)`, even if the user was already signed in. Guard against deleting data on this "synthetic" sign-in by checking whether it's a first launch.

### Rule 9: Handle All Critical Error Codes

**Rationale:** CKSyncEngine automatically retries transient errors (network, rate limiting, zone busy). But several error codes require your intervention -- the engine drops the failed item from its queue.

**Rule:** Handle these errors in `sentRecordZoneChanges`:

```swift
for failure in sentChanges.failedRecordSaves {
    let error = failure.error
    let recordID = failure.record.recordID

    switch error.code {
    case .zoneNotFound:
        // Create zone and retry (existing code)
        createZoneAndRetry(recordID)

    case .serverRecordChanged:
        // Conflict -- merge and retry (see Rule 6)
        resolveConflict(failure)

    case .unknownItem:
        // Record was deleted on server. Clear cached system fields.
        // If local record still exists, re-upload from scratch.
        clearSystemFields(for: recordID)
        syncEngine?.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])

    case .quotaExceeded:
        // User's iCloud is full. Engine pauses AND drops items.
        // Re-add to pending and notify user.
        logger.error("iCloud quota exceeded -- sync paused")
        syncEngine?.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
        notifyUserQuotaExceeded()

    case .limitExceeded:
        // Batch too large. Re-queue -- engine will try smaller batches.
        syncEngine?.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])

    default:
        logger.error("Unhandled save error for \(recordID.recordName): \(error)")
    }
}
```

**Errors CKSyncEngine handles automatically (do not retry manually):**
- `.networkFailure` / `.networkUnavailable`
- `.zoneBusy`
- `.serviceUnavailable`
- `.requestRateLimited` (respects server's `retryAfterSeconds`)
- `.notAuthenticated`
- `.operationCancelled`

### Rule 10: Use Stable Record Names from UUIDs

**Rationale:** Record names are the primary key for deduplication across devices. Using random or autogenerated names causes duplicate records.

**Rule:** Always use the local model's UUID as the CKRecord name. This is already the pattern in this project:

```swift
let recordID = CKRecord.ID(recordName: localRecord.id.uuidString, zoneID: zoneID)
```

### Rule 11: Use Strings for Enum-Like Fields in CKRecords

**Rationale:** CloudKit Production schemas are additive-only -- fields can be added but never removed or changed in type. If you store Swift enums as integers, adding a new case changes the integer mapping, breaking older app versions.

**Rule:** Store enum-like values as strings in CKRecords, and convert to/from local enums at the mapping layer.

```swift
// CORRECT: Store as string
record["type"] = "expense" as CKRecordValue

// WRONG: Store as enum raw value (Int)
record["type"] = TransactionType.expense.rawValue as CKRecordValue
```

This project already follows this pattern in `RecordMapping.swift`.

### Rule 12: Never Duplicate Record IDs in a Batch

**Rationale:** CloudKit rejects requests that both save and delete the same record ID. The `addPendingChange` methods already handle this by removing from the opposite set.

**Rule:** When adding a save, remove from pending deletions. When adding a deletion, remove from pending saves.

```swift
// Already implemented correctly in ProfileSyncEngine:
func addPendingChange(_ change: PendingChange) {
    switch change {
    case .saveRecord(let recordID):
        pendingSaves.insert(recordID)
        pendingDeletions.remove(recordID)  // Prevent duplicate
    case .deleteRecord(let recordID):
        pendingDeletions.insert(recordID)
        pendingSaves.remove(recordID)      // Prevent duplicate
    }
}
```

---

## 4. State Serialization

### How It Works

Every CKSyncEngine event triggers a `.stateUpdate` containing the complete `CKSyncEngine.State.Serialization`. This `Codable` type includes pending changes, change tokens, and internal engine state.

### Rules

- **Save on every `.stateUpdate` event.** Missing a save means the engine may re-process events on next launch.
- **Use atomic writes.** Prevents corruption from interrupted writes.
- **Pass saved state to `CKSyncEngine.Configuration`.** The engine resumes exactly where it left off. Without saved state, it performs a full re-fetch.
- **Delete state on account sign-out/switch.** The tokens are invalid for a different account.
- **Delete state on zone purge.** The tokens reference deleted server state.

### State File Locations

- macOS: `~/Library/Containers/rocks.moolah.app/Data/Library/Application Support/Moolah-*.syncstate`
- iOS Simulator: `~/Library/Developer/CoreSimulator/Devices/.../Application Support/Moolah-*.syncstate`

### Corruption Recovery

Phantom pending changes accumulate in `.syncstate` files and persist across launches. If sync behaves unexpectedly, check the sync state file size -- a multi-MB file for a small record set indicates corruption.

**Recovery:** Delete the `.syncstate` file. CKSyncEngine will perform a clean initial fetch on next launch.

---

## 5. Record Mapping

### CloudKitRecordConvertible Protocol

All syncable SwiftData records conform to `CloudKitRecordConvertible`:

```swift
protocol CloudKitRecordConvertible {
    static var recordType: String { get }
    func toCKRecord(in zoneID: CKRecordZone.ID) -> CKRecord
    static func fieldValues(from ckRecord: CKRecord) -> Self
}
```

### Mapping Rules

- Record type strings use `CD_` prefix (e.g., `CD_AccountRecord`) for consistency with the legacy SwiftData CloudKit schema.
- UUID fields are stored as strings in CKRecords: `id.uuidString as CKRecordValue`.
- Boolean fields are stored as integers: `(isHidden ? 1 : 0) as CKRecordValue`.
- Optional fields are only set if non-nil (avoids storing null values in CloudKit).
- The `fieldValues(from:)` method provides sensible defaults for missing fields (defensive against schema evolution).

### Adding a New Syncable Record Type

1. Create the SwiftData `@Model` class.
2. Add `CloudKitRecordConvertible` conformance in `RecordMapping.swift`.
3. Add the record type to `RecordTypeRegistry.allTypes`.
4. Add the entity name to `ChangeTracker`'s `profileDataEntities` set.
5. Add upsert and fetch methods to `ProfileSyncEngine`.
6. Add cases to `applyRemoteSave` and `applyRemoteDeletion` switch statements.
7. **Test:** Verify the change tracker captures saves for the new entity type.

---

## 6. Initial Sync and Fresh Devices

### How It Works

When CKSyncEngine initializes without saved `State.Serialization`:
1. It sends an `.accountChange(.signIn)` event (even if the user was already signed in).
2. It performs a full fetch from CloudKit, delivering all records via `fetchedRecordZoneChanges`.
3. Change tokens are established for future incremental fetches.

### Deletion Tombstone Replay

CloudKit replays deletion tombstones indefinitely. For apps with high deletion churn, a fresh device must process thousands of stale deletion records before seeing current data.

**Mitigations:**
- Prefer soft-deletes (a boolean flag) over hard-deletes for frequently churned records.
- Use `prioritizedZoneIDs` in fetch options to process critical zones first.
- Consider a "data loaded" flag to show existing local data while the sync engine catches up.

### Batch Limits

- Upload: ~400 records per batch, 1 MB max per batch. CKSyncEngine handles chunking.
- Download: much larger (100+ MB observed). The engine handles pagination via change tokens.

---

## 7. Testing Sync Code

### Layer Separation

Test the sync layer separately from the persistence layer:

| Layer | What to Test | How |
|-------|-------------|-----|
| SwiftData repositories | CRUD, filtering, sorting | `TestBackend` with in-memory SwiftData |
| Record mapping | CKRecord <-> SwiftData conversion | Unit tests, no CloudKit |
| Change tracker | Correct entities tracked, remote changes skipped | In-memory SwiftData + mock sync engine |
| Sync engine delegate | Event handling, error recovery | `automaticallySync: false` or protocol abstraction |

### Testing Record Mapping

```swift
func testAccountRecordRoundTrip() {
    let original = AccountRecord(id: UUID(), name: "Checking", type: "bank", ...)
    let ckRecord = original.toCKRecord(in: testZoneID)
    let restored = AccountRecord.fieldValues(from: ckRecord)
    #expect(restored.name == original.name)
    #expect(restored.type == original.type)
}
```

### Testing Change Tracker

Use in-memory SwiftData and verify the change tracker queues the right pending changes:

```swift
@MainActor
func testLocalSaveQueuesUpload() async throws {
    let (backend, _, _) = try TestBackend.create()
    let syncEngine = ProfileSyncEngine(profileId: testProfileId, modelContainer: backend.modelContainer)
    let tracker = ChangeTracker(syncEngine: syncEngine, modelContainer: backend.modelContainer)
    tracker.startTracking()

    // Save a record to SwiftData
    _ = try await backend.accounts.create(testAccount)

    // Verify it was queued for upload
    #expect(syncEngine.hasPendingChanges)
}
```

### Integration Testing with Two "Devices"

Apple's sample app demonstrates testing with `automaticallySync: false`:

```swift
// Create two sync engines, both with manual sync control
let deviceA = SyncEngine(configuration: .init(..., automaticallySync: false))
let deviceB = SyncEngine(configuration: .init(..., automaticallySync: false))

// Device A saves and sends
deviceA.addPendingChange(.saveRecord(recordID))
try await deviceA.syncEngine.sendChanges()

// Device B fetches and verifies
try await deviceB.syncEngine.fetchChanges()
// Assert Device B has the record
```

---

## 8. Debugging Sync Issues

### Logging

All sync engines use `os.Logger` with the `com.moolah.app` subsystem. Filter by category:

```bash
# Profile index sync
/usr/bin/log stream \
  --predicate 'subsystem == "com.moolah.app" && category == "ProfileIndexSyncEngine"' \
  --level debug --style compact --timeout 45s

# Per-profile sync
/usr/bin/log stream \
  --predicate 'subsystem == "com.moolah.app" && category == "ProfileSyncEngine"' \
  --level debug --style compact --timeout 45s

# Change tracker
/usr/bin/log stream \
  --predicate 'subsystem == "com.moolah.app" && category == "ChangeTracker"' \
  --level debug --style compact --timeout 45s
```

### Common Symptoms and Diagnosis

| Symptom | Likely Cause | Diagnosis |
|---------|-------------|-----------|
| No delegate events after start | iCloud account not available, or corrupted sync state | Check `CKContainer.default().accountStatus()` |
| "Zone Not Found" errors | Zone hasn't been created yet | Check `sentRecordZoneChanges` error handling (Rule 3) |
| Thousands of pending changes | Entity filtering missing | Check `.syncstate` file size (Rule 1) |
| Records sent but not appearing on other devices | Change tag conflict, or second device not fetching | Check for `.serverRecordChanged` errors in logs |
| Records appear then disappear | Re-upload loop from missing `isApplyingRemoteChanges` guard | Check change tracker filtering (Rule 2) |
| Duplicate records across devices | Record names not derived from stable UUIDs | Check `CKRecord.ID` construction (Rule 10) |
| Sync works once then stops | State serialization not being saved | Check `.stateUpdate` handler |
| `.serverRecordChanged` on every upload | Not preserving CKRecord system fields | Check `toCKRecord` implementation (Rule 5) |

### CloudKit Dashboard

Use the [CloudKit Dashboard](https://icloud.developer.apple.com/) to:
- Browse records and zones in the Development or Production environment
- Verify record types and field schemas
- Check for orphaned zones from failed cleanups
- Reset the Development environment when schemas need incompatible changes

---

## 9. Anti-Patterns

| Anti-Pattern | Why It's Bad | Do This Instead |
|-------------|--------------|-----------------|
| Calling `fetchChanges()`/`sendChanges()` in delegate callbacks | Causes infinite loops -- engine re-enters your delegate | Add to pending queue; engine schedules sends |
| Multiple CKSyncEngine instances on one database | They conflict on change tokens and event routing | One engine per database, managing distinct zones |
| Creating fresh CKRecords without system fields | Every upload triggers `.serverRecordChanged` | Preserve and reuse `encodedSystemFields` |
| Ignoring `.serverRecordChanged` errors | Second device's changes silently lost | Implement conflict resolution (Rule 6) |
| Ignoring `.quotaExceeded` | Engine drops items; sync silently stops | Re-queue items and notify user (Rule 9) |
| Hard-deleting high-churn records | Deletion tombstones replay on fresh devices forever | Use soft-delete flags where practical |
| Storing enums as integers in CKRecords | Adding new cases breaks older app versions | Store as strings (Rule 11) |
| `try?` on CloudKit operations without logging | Silent failures make debugging impossible | Log errors with `os.Logger` before discarding |
| Deleting state file on every launch "just in case" | Forces full re-fetch every time, wasting bandwidth | Only delete on account change or corruption |

---

## 10. Schema Evolution

### CloudKit Production Constraints

Once a schema is deployed to CloudKit Production:
- **Fields can only be added**, never removed or changed in type.
- **Record types can only be added**, never removed.
- **Indexes can be added or removed.**

### Safe Schema Changes

```swift
// Adding a new optional field -- safe
record["newField"] = value as CKRecordValue

// Reading with a fallback -- safe for older records that don't have the field
let value = ckRecord["newField"] as? String ?? defaultValue
```

### Unsafe Schema Changes (Require Migration)

- Changing a field's type (e.g., String to Int)
- Renaming a field (old field stays, new field added)
- Removing a field (old field stays in existing records forever)

**Migration approach:** Add the new field alongside the old one. Read from new field first, fall back to old field. Write to both fields during a transition period.

---

## 11. Implementation Checklist

### Before Implementing a New Sync Engine

- [ ] Define the zone name and ensure no other engine manages the same zone
- [ ] Determine the conflict resolution strategy (server-wins, field-level merge, etc.)
- [ ] Plan which record types will be synced in this zone
- [ ] Design the `CloudKitRecordConvertible` mapping for each type

### For Every New Syncable Record Type

- [ ] Add `CloudKitRecordConvertible` conformance in `RecordMapping.swift`
- [ ] Add to `RecordTypeRegistry.allTypes`
- [ ] Add entity name to `ChangeTracker.profileDataEntities`
- [ ] Add upsert/fetch methods to the sync engine
- [ ] Add cases to `applyRemoteSave` and `applyRemoteDeletion`
- [ ] Write round-trip mapping tests
- [ ] Verify change tracker captures saves for this entity

### For Every Sync Engine

- [ ] Handle all event types in `handleEvent` (especially `.stateUpdate`, `.accountChange`, `.fetchedDatabaseChanges`, `.fetchedRecordZoneChanges`, `.sentRecordZoneChanges`)
- [ ] Save state serialization on every `.stateUpdate`
- [ ] Handle `.zoneNotFound` in sent changes
- [ ] Handle `.serverRecordChanged` with conflict resolution
- [ ] Handle `.quotaExceeded` by re-queuing and notifying user
- [ ] Handle `.unknownItem` by clearing cached system fields
- [ ] Handle all three zone deletion reasons (deleted, purged, encryptedDataReset)
- [ ] Handle all three account change types (signIn, signOut, switchAccounts)
- [ ] Filter change tracker notifications by entity type
- [ ] Guard against re-uploading remote changes (`isApplyingRemoteChanges`)
- [ ] Prevent duplicate record IDs in batches (save removes from deletions, delete removes from saves)

### Before Shipping to Production

- [ ] Test multi-device sync (create on device A, verify on device B)
- [ ] Test conflict scenario (edit same record on two devices offline, then go online)
- [ ] Test account sign-out and sign-in flow
- [ ] Test fresh device sync (delete app, reinstall, verify data appears)
- [ ] Test with iCloud storage nearly full (quota handling)
- [ ] Verify schema in CloudKit Dashboard matches expectations
- [ ] Verify sync state file doesn't grow unexpectedly

---

## Version History

- **1.0** (2026-04-13): Comprehensive sync guide -- architecture, rules, error handling, testing, debugging, schema evolution
