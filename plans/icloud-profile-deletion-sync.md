# iCloud Profile Deletion Does Not Propagate to Other Devices

## Problem

When a user deletes an iCloud profile, the app removes the local SQLite database files and the `ProfileRecord` from the shared index store. However, it does not delete the data from CloudKit's servers. This means:

1. **Other devices keep the data.** They still have local replicas and the server-side copy continues to exist. The profile's accounts, transactions, and other records remain visible on those devices indefinitely.
2. **Server data is orphaned.** The CloudKit zone for that profile remains on Apple's servers. If the user reinstalls the app or sets up a new device, SwiftData could re-download the orphaned data if the zone name matches.
3. **ProfileRecord deletion does sync.** The shared index store removal propagates, so other devices may stop listing the profile in the UI — but the underlying data zone is never cleaned up.

### Current Deletion Code

`ProfileStore.removeProfile` (`Features/Profiles/ProfileStore.swift`):
- Removes the profile from `cloudProfiles` array
- Calls `containerManager.deleteStore(for: id)` which deletes local `.store`, `-shm`, `-wal` files
- Calls `ProfileDataDeleter.deleteProfileRecord(for:)` which removes the `ProfileRecord` from the index container

`ProfileContainerManager.deleteStore` (`Shared/ProfileContainerManager.swift`):
- Removes the `ModelContainer` from the in-memory cache
- Deletes the SQLite files from `~/Library/Application Support/`

No CloudKit zone or record deletion occurs anywhere in the flow.

## Potential Solutions

### Option A: Delete the CloudKit Zone Directly (Recommended)

Use `CKDatabase.delete(withRecordZoneID:)` to delete the entire zone before removing local files. This is atomic and immediate on the server.

```swift
let zoneID = CKRecordZone.ID(
    zoneName: "<swiftdata-zone-name>",
    ownerName: CKCurrentUserDefaultName
)
let privateDB = CKContainer.default().privateCloudDatabase
try await privateDB.deleteRecordZone(withID: zoneID)
```

**Pros:**
- Single atomic server operation
- No need to enumerate model types
- Does not depend on sync timing
- Other devices will process the zone deletion when they next sync

**Cons:**
- Need to determine the exact zone name SwiftData assigns for each profile's `ModelConfiguration`. SwiftData with `cloudKitDatabase: .automatic` derives the zone name from the configuration. This can be inspected via CloudKit Dashboard or by logging `NSPersistentCloudKitContainer` events.
- Requires the device to be online at deletion time (could queue for later if offline)

**Investigation needed:** Determine the zone naming convention. SwiftData typically uses `com.apple.coredata.cloudkit.zone` as the default zone name, but when multiple configurations exist (as we have — one per profile), each may get a distinct zone name based on the store URL or configuration name.

### Option B: Delete All Records via ModelContext Before Removing Store

Fetch and delete all objects through SwiftData before removing the local store. Since CloudKit mirroring is bidirectional, deletions sync to all devices.

```swift
let context = ModelContext(container)
for type in [AccountRecord.self, TransactionRecord.self, ...] {
    let items = try context.fetch(FetchDescriptor<type>())
    items.forEach { context.delete($0) }
}
try context.save()
// Allow time for sync, then remove local files
```

**Pros:**
- Works entirely through SwiftData's API — no CloudKit framework dependency
- Deletions sync naturally through the existing mirroring

**Cons:**
- Must enumerate every model type (fragile if models are added/removed)
- No guarantee sync completes before the user closes the app or goes offline
- Slower — deletes records one by one rather than dropping the zone

### Option C: Hybrid Approach

1. Delete all records through `ModelContext` (triggers sync of deletions)
2. Save and give a brief window for sync to propagate
3. Delete the local store files as currently done
4. Optionally also delete the zone as a belt-and-suspenders measure

**Pros:**
- Best coverage — works even if one mechanism fails

**Cons:**
- Most complex to implement
- Still has the timing issue from Option B

## Recommendation

**Option A (zone deletion)** is the cleanest solution. The main prerequisite is confirming the zone name SwiftData uses per profile. Once that's known, it's a small addition to `ProfileContainerManager.deleteStore` or `ProfileStore.removeProfile` — call `deleteRecordZone` before removing local files.

If the device is offline at deletion time, the zone deletion should be queued and retried on next launch (e.g., persisted in UserDefaults as a "pending zone deletion" list).
