# CKSyncEngine Migration Plan

## Problem

SwiftData's automatic CloudKit sync (`cloudKitDatabase: .automatic`) maps ALL `ModelContainer` instances to a single hardcoded zone: `com.apple.coredata.cloudkit.zone`. There is no API to specify a custom zone. This means:

- All iCloud profiles share one zone — data from Profile A appears in Profile B
- Migration imports get contaminated by stale zone data from previous attempts
- Deleting a profile's local store doesn't clean up its CloudKit records
- The per-profile store architecture (`Moolah-{profileId}.store`) provides local isolation only

This is confirmed by Apple's API surface: `NSPersistentCloudKitContainerOptions` has no zone name property. The CloudKit Dashboard shows a single `com.apple.coredata.cloudkit.zone` regardless of how many containers are created.

## Solution: CKSyncEngine + SwiftData Local

Replace SwiftData's automatic CloudKit sync with `CKSyncEngine` (iOS 17+ / macOS 14+), which provides full control over record zones. Each profile gets its own `CKRecordZone`, achieving true data isolation.

### Architecture Overview

```
┌─────────────────────────────────────────────┐
│  SwiftData (local only, .none)              │
│  ┌──────────────┐  ┌──────────────┐         │
│  │ Moolah-A.store│  │ Moolah-B.store│  ...   │
│  └──────┬───────┘  └──────┬───────┘         │
│         │                  │                 │
│  ┌──────▼──────────────────▼───────┐        │
│  │     CloudKitSyncManager         │        │
│  │  (CKSyncEngine delegate)       │        │
│  └──────┬──────────────────┬───────┘        │
│         │                  │                 │
│  ┌──────▼───────┐  ┌──────▼───────┐        │
│  │  Zone: A     │  │  Zone: B     │        │
│  │ (CKRecordZone)│  │ (CKRecordZone)│       │
│  └──────────────┘  └──────────────┘        │
│                                             │
│  CloudKit Private Database                  │
│  Container: iCloud.rocks.moolah.app         │
└─────────────────────────────────────────────┘
```

### Key Design Decisions

1. **SwiftData stays as local persistence** — all existing repositories, stores, and queries are unchanged. Only the sync transport layer changes.

2. **`cloudKitDatabase: .none` on ALL ModelConfigurations** — disables SwiftData's automatic sync. The profile index store (`Moolah.store`) also switches to `.none` and gets its own sync zone.

3. **One CKSyncEngine instance per active profile** — each engine manages a single zone (`profile-{profileId}`). A separate engine (or the same one) manages the profile index zone.

4. **Change tracking via SwiftData's `ModelContext` save notifications** — when a repository saves, the sync manager converts changed records to `CKRecord` instances and queues them for upload.

5. **Conflict resolution: server wins** — for a personal finance app with single-user-per-profile, last-write-wins from the server is sufficient. No complex merge logic needed.

## What Exists Today (main branch)

### SwiftData Records (`Backends/CloudKit/Models/`)
| Record | Key Fields |
|--------|-----------|
| `ProfileRecord` | id, label, currencyCode, financialYearStartMonth, createdAt |
| `AccountRecord` | id, name, type, position, isHidden, currencyCode, cachedBalance |
| `TransactionRecord` | id, type, date, accountId, toAccountId, amount, currencyCode, payee, notes, categoryId, earmarkId, recurPeriod, recurEvery |
| `CategoryRecord` | id, name, parentId |
| `EarmarkRecord` | id, name, position, isHidden, savingsTarget, currencyCode, savingsStartDate, savingsEndDate |
| `EarmarkBudgetItemRecord` | id, earmarkId, categoryId, amount, currencyCode |
| `InvestmentValueRecord` | id, accountId, date, value, currencyCode |

### Key Files
| File | Role |
|------|------|
| `Shared/ProfileContainerManager.swift` | Creates per-profile ModelContainers with `.automatic` sync |
| `Backends/CloudKit/CloudKitBackend.swift` | Creates repositories from a ModelContainer |
| `App/ProfileSession.swift` | Creates backends, observes `NSPersistentStoreRemoteChange` |
| `App/MoolahApp.swift` | Initializes containers, profile store, session manager |
| `App/SessionManager.swift` | Caches ProfileSession instances per profile |
| `Features/Profiles/ProfileStore.swift` | Manages profile CRUD, loads cloud profiles from index |

### Current Sync Flow
1. SwiftData auto-syncs via `NSPersistentCloudKitContainer` under the hood
2. `ProfileSession.observeRemoteChanges()` listens for `NSPersistentStoreRemoteChange`
3. On notification, debounced `reloadFromSync()` calls on AccountStore, CategoryStore, EarmarkStore
4. TransactionStore and InvestmentStore don't reload directly (rely on account updates)

## Implementation Plan

### Phase 1: CKSyncEngine Infrastructure

#### Task 1.1: Create CKRecord ↔ SwiftData Mapping

**New file:** `Backends/CloudKit/Sync/RecordMapping.swift`

Define bidirectional conversion between each SwiftData record and `CKRecord`:

```swift
protocol CloudKitRecordConvertible {
    static var recordType: String { get }
    func toCKRecord(in zoneID: CKRecordZone.ID) -> CKRecord
    static func from(ckRecord: CKRecord) -> Self  // returns field values, not @Model instance
}
```

Each record type implements this protocol. The `CKRecord.ID` should be derived from the SwiftData record's `id` field (UUID) to ensure idempotent sync:
```swift
CKRecord.ID(recordName: id.uuidString, zoneID: zoneID)
```

**Record type mapping:**
- `ProfileRecord` → `"CD_ProfileRecord"`
- `AccountRecord` → `"CD_AccountRecord"`
- `TransactionRecord` → `"CD_TransactionRecord"`
- `CategoryRecord` → `"CD_CategoryRecord"`
- `EarmarkRecord` → `"CD_EarmarkRecord"`
- `EarmarkBudgetItemRecord` → `"CD_EarmarkBudgetItemRecord"`
- `InvestmentValueRecord` → `"CD_InvestmentValueRecord"`

Note: The `CD_` prefix matches what NSPersistentCloudKitContainer uses. This isn't strictly necessary for CKSyncEngine but aids debugging if inspecting the CloudKit Dashboard.

#### Task 1.2: Create CloudKitSyncEngine Wrapper

**New file:** `Backends/CloudKit/Sync/ProfileSyncEngine.swift`

```swift
@MainActor
final class ProfileSyncEngine: CKSyncEngineDelegate {
    let profileId: UUID
    let zoneID: CKRecordZone.ID
    let modelContainer: ModelContainer
    private var engine: CKSyncEngine
    
    init(profileId: UUID, modelContainer: ModelContainer)
    
    // CKSyncEngineDelegate
    func handleEvent(_ event: CKSyncEngine.Event)
    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext) -> CKSyncEngine.RecordZoneChangeBatch?
}
```

**Responsibilities:**
- Creates `CKRecordZone(zoneName: "profile-\(profileId)")` on first sync
- Tracks pending changes (inserts/updates/deletes) from local saves
- Converts between `CKRecord` and SwiftData records
- Handles incoming changes by upserting into the local ModelContext
- Persists the sync engine state (change tokens) between launches

**State persistence:** Store `CKSyncEngine.State.Serialization` in a file alongside the profile store: `Moolah-{profileId}.syncstate`

#### Task 1.3: Create ProfileIndex Sync

**New file:** `Backends/CloudKit/Sync/ProfileIndexSyncEngine.swift`

Separate sync engine for the profile index (`Moolah.store`), using zone name `"profile-index"`. Only syncs `ProfileRecord` instances. This ensures the profile list syncs across devices.

#### Task 1.4: Change Tracking

**New file:** `Backends/CloudKit/Sync/ChangeTracker.swift`

Listen for `ModelContext.didSave` notifications (or `NSManagedObjectContextDidSave` under the hood) to detect local changes that need uploading:

```swift
@MainActor
final class ChangeTracker {
    func startTracking(modelContainer: ModelContainer, syncEngine: ProfileSyncEngine)
}
```

When a save occurs:
1. Inspect inserted/updated/deleted objects
2. Convert to `CKSyncEngine.PendingRecordZoneChange` entries
3. Add to `engine.state.add(pendingRecordZoneChanges:)`

### Phase 2: Integration

#### Task 2.1: Disable Automatic CloudKit Sync

**Modify:** `Shared/ProfileContainerManager.swift`

Change all `ModelConfiguration` creation to use `cloudKitDatabase: .none`:
- `container(for:)` — profile data stores
- Remove the `cloudKitDatabase` parameter from the init (it's always `.none` now)

**Modify:** `App/MoolahApp.swift`

Change the profile index container to use `cloudKitDatabase: .none`:
```swift
let profileConfig = ModelConfiguration(
    url: profileStoreURL,
    cloudKitDatabase: .none  // was .automatic
)
```

#### Task 2.2: Wire Up Sync Engines in ProfileSession

**Modify:** `App/ProfileSession.swift`

For CloudKit profiles:
1. Create `ProfileSyncEngine(profileId:modelContainer:)` alongside the backend
2. Start the sync engine
3. Replace `NSPersistentStoreRemoteChange` observation with sync engine callbacks
4. The sync engine calls the existing `reloadFromSync()` methods on stores when remote changes arrive

#### Task 2.3: Wire Up Profile Index Sync

**Modify:** `App/MoolahApp.swift` or `Features/Profiles/ProfileStore.swift`

Create and start `ProfileIndexSyncEngine` at app launch. When remote profile changes arrive, call `profileStore.loadCloudProfiles()`.

#### Task 2.4: Update ProfileStore Remote Change Handling

**Modify:** `Features/Profiles/ProfileStore.swift`

Replace the `NSPersistentStoreRemoteChange` observer (line 276-285) with a callback from `ProfileIndexSyncEngine`.

### Phase 3: Migration from Existing Data

#### Task 3.1: One-Time Zone Migration

Users upgrading from the current version will have data in the `com.apple.coredata.cloudkit.zone` zone. On first launch after the update:

1. Check if the old zone exists (via `CKDatabase.allRecordZones()`)
2. If it does, fetch all records from it
3. Create the new per-profile zone(s) and write records there
4. Delete the old zone

This only affects users who had iCloud profiles on the old version. Since the app is pre-release (TestFlight only), this could also be handled by simply documenting "delete your iCloud profile and re-migrate" in release notes.

#### Task 3.2: Clean Up Old Zone Data

**If taking the simple approach:** Add a one-time cleanup that deletes the `com.apple.coredata.cloudkit.zone` zone on first launch. This purges all stale data from previous migration attempts.

### Phase 4: Profile Lifecycle

#### Task 4.1: Profile Deletion Cleans Up Zone

**Modify:** `Shared/ProfileContainerManager.swift` → `deleteStore(for:)`

In addition to deleting the local SQLite file, also delete the CloudKit zone:
```swift
let zoneID = CKRecordZone.ID(zoneName: "profile-\(profileId)")
// Delete zone via CKDatabase or CKSyncEngine
```

#### Task 4.2: Migration Coordinator Update

**Modify:** `Backends/CloudKit/Migration/MigrationCoordinator.swift`

Migration no longer needs special handling — since sync is manual via CKSyncEngine, the import writes to a local-only store. The sync engine is started AFTER verification succeeds, uploading the imported data to a fresh zone.

## Testing Strategy

### Unit Tests
- `RecordMapping` tests: round-trip each record type through CKRecord conversion
- `ChangeTracker` tests: verify correct pending changes generated from ModelContext saves
- `ProfileSyncEngine` tests: mock CKSyncEngine events, verify local store is updated correctly

### Integration Tests
- Use in-memory ModelContainers (existing `TestBackend` pattern)
- Mock CKSyncEngine (or use the test configuration Apple provides)
- Verify that two profile sync engines with different zone IDs don't interfere

### Manual Testing
- Create two iCloud profiles, add different data to each, verify isolation
- Delete a profile, verify zone is cleaned up
- Migration from remote → iCloud, verify data appears correctly
- Multi-device: create data on one device, verify it appears on another

## Files Changed Summary

| Action | File |
|--------|------|
| **New** | `Backends/CloudKit/Sync/RecordMapping.swift` |
| **New** | `Backends/CloudKit/Sync/ProfileSyncEngine.swift` |
| **New** | `Backends/CloudKit/Sync/ProfileIndexSyncEngine.swift` |
| **New** | `Backends/CloudKit/Sync/ChangeTracker.swift` |
| **New** | Tests for all new sync files |
| **Modify** | `Shared/ProfileContainerManager.swift` — `.none` for all containers |
| **Modify** | `App/MoolahApp.swift` — `.none` for index container, init sync engines |
| **Modify** | `App/ProfileSession.swift` — create ProfileSyncEngine, replace notification observer |
| **Modify** | `Features/Profiles/ProfileStore.swift` — replace notification observer |
| **Modify** | `Backends/CloudKit/Migration/MigrationCoordinator.swift` — start sync after verify |
| **Modify** | `project.yml` — add new files to Xcode target |

## Risks & Considerations

1. **CKSyncEngine requires iOS 17+ / macOS 14+** — the app targets iOS 26+ / macOS 26+ so this is fine.

2. **Conflict resolution** — server-wins is simple but could lose data if two devices edit simultaneously. For a personal finance app this is low risk. Can be enhanced later.

3. **Initial sync performance** — first sync after migration downloads all records. For 18K+ transactions this could take time. Should show progress.

4. **CloudKit rate limits** — bulk uploads (migration) should batch records appropriately. CKSyncEngine handles this automatically.

5. **Existing CloudKit zone data** — stale data from `com.apple.coredata.cloudkit.zone` must be cleaned up. Since this is pre-release, the simplest approach is to delete the old zone on first launch.

6. **Schema compatibility with multi-instrument branch** — the multi-instrument branch changes the SwiftData schema (adds TransactionLegRecord, InstrumentRecord, changes field types). The CKSyncEngine work on main will need the RecordMapping updated when rebased onto multi-instrument. The sync infrastructure itself is schema-agnostic.
