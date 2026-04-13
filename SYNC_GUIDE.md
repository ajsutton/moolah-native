# CKSyncEngine Sync Guide

This guide covers patterns and pitfalls for the CKSyncEngine-based iCloud sync implementation. All sync code MUST follow these rules.

## Architecture Overview

Two sync layers, each with their own CKSyncEngine instance:

1. **ProfileIndexSyncEngine** — syncs `ProfileRecord` metadata via the `profile-index` zone
2. **ProfileSyncEngine** (one per active profile) — syncs per-profile data via `profile-{profileId}` zones

Each engine has a corresponding change tracker that observes `NSManagedObjectContextDidSave` notifications to queue local changes for upload.

## Rules

### 1. Filter Notifications by Entity Type

**Bug found:** `NSManagedObjectContextDidSave` with `object: nil` catches saves from ALL ModelContainers. Without entity filtering, per-profile data saves (thousands of records) get queued as phantom pending changes in the ProfileIndexSyncEngine, bloating the sync state file and preventing real records from syncing.

**Rule:** Always filter notification objects by entity name before extracting IDs.

```swift
// ✅ CORRECT: Filter to only relevant entities
let inserted = (notification.userInfo?[NSInsertedObjectsKey] as? Set<NSManagedObject>)?
    .filter { $0.entity.name == "ProfileRecord" }

// ❌ WRONG: Processes ALL entities from ALL containers
let inserted = notification.userInfo?[NSInsertedObjectsKey] as? Set<NSManagedObject>
```

### 2. Guard Against Re-uploading Remote Changes

**Bug found:** When `applyRemoteChanges()` saves fetched records to SwiftData, the save notification triggers the change tracker, which queues those records for upload back to CloudKit — an unnecessary round-trip.

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

### 3. Handle Zone Creation on First Send

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

### 4. Every SwiftData Write Must Be Tracked

**Bug found:** `ProfileIndexSyncEngine.addPendingSave()` existed but was never called — profile records saved to SwiftData were never uploaded to CloudKit.

**Rule:** Every ModelContainer that syncs via CKSyncEngine must have a change tracker wired up. When adding a new syncable record type or container, verify the change tracker covers it.

### 5. Sync State Files Can Become Corrupted

Phantom pending changes accumulate in `.syncstate` files and persist across launches. If sync behaves unexpectedly, check the sync state file size — a multi-MB file for a small record set indicates corruption.

**Recovery:** Delete the `.syncstate` file. CKSyncEngine will perform a clean initial fetch on next launch. State files are at:
- macOS: `~/Library/Containers/rocks.moolah.app/Data/Library/Application Support/Moolah-*.syncstate`
- iOS Simulator: `~/Library/Developer/CoreSimulator/Devices/.../Application Support/Moolah-*.syncstate`

## Debugging Sync Issues

Use the `run-mac-app-with-logs` skill to capture runtime logs. Filter by category:

```bash
/usr/bin/log stream \
  --predicate 'subsystem == "com.moolah.app" && category == "ProfileIndexSyncEngine"' \
  --level debug --style compact --timeout 45s
```

Key things to look for:
- **No delegate events after start** — iCloud account not available, or corrupted sync state
- **"Zone Not Found" errors** — zone hasn't been created yet (see Rule 3)
- **Thousands of pending changes** — entity filtering missing (see Rule 1)
- **Records sent but not appearing on other devices** — check the receiving device's sync engine logs
