# Unified CKSyncEngine Design

## Problem

The app runs multiple `CKSyncEngine` instances against the same CloudKit private database — one `ProfileIndexSyncEngine` for the profile-index zone and one `ProfileSyncEngine` per active CloudKit profile. Since `CKSyncEngine` subscribes at the database level, **every engine receives change notifications for every zone**. This means:

- Each fetch cycle delivers records from all zones to all engines, which discard records from zones they don't own
- Only the active profile's engine runs, so inactive profiles miss changes and must catch up from scratch when opened
- Background flush and foreground fetch iterate N+1 engines
- Database-level push notifications trigger redundant fetch requests from multiple engines
- The sync guide's anti-pattern table explicitly warns: "Multiple CKSyncEngine instances on one database — they conflict on change tokens and event routing — one engine per database, managing distinct zones"

## Solution

Replace all `CKSyncEngine` instances with a single `SyncCoordinator` that runs for the app lifecycle, processes all zones, and routes records to the appropriate handler by zone ID.

## Architecture

### SyncCoordinator

A new `@MainActor` class that owns the single `CKSyncEngine`. Responsibilities:

- Starts at app launch (when CloudKit is available), runs until termination
- Implements `CKSyncEngineDelegate`
- Routes `fetchedRecordZoneChanges` by zone ID to the appropriate handler
- Serves `nextRecordZoneChangeBatch` by building CKRecords from the correct `ModelContainer` based on each pending record's zone ID
- Manages a single `CKSyncEngine.State.Serialization` (one change token for the whole database)
- Provides `queueSave(id:zoneID:)` and `queueDeletion(id:zoneID:)` for repositories to call — both `@MainActor`-isolated so `CKSyncEngine.state.add(pendingRecordZoneChanges:)` is always called from one actor
- Fires `onRemoteChangesApplied(profileId:changedTypes:)` after applying changes, so active `ProfileSession`s can reload their stores

**Design principle:** Everything runs on `@MainActor`. This eliminates all concurrency races — container creation, observer management, state mutation, and batch building are all serial. The `@MainActor` requirement is safe because `nextRecordZoneChangeBatch` is already capped at 400 records per call (same per-call cost as today), and fetch-side batch upserts are bounded by what CKSyncEngine delivers per batch. See [Performance](#performance-instrumentation) for how we verify this.

### Zone Routing

The coordinator parses zone IDs to determine the handler:

- `profile-index` zone → profile index handler (upserts `ProfileRecord`s in the index `ModelContainer`)
- `profile-<uuid>` zone → per-profile handler (upserts data records in that profile's `ModelContainer` via `ProfileContainerManager`)

### Receiving Side (Fetched Changes)

```
CKSyncEngine delivers fetchedRecordZoneChanges
  → SyncCoordinator groups records by zoneID
  → profile-index records → applyProfileIndexChanges(saved:deleted:)
  → profile-<uuid> records → applyProfileDataChanges(profileId:saved:deleted:)
      → looks up ModelContainer via ProfileContainerManager.container(for:)
      → batch upserts/deletes using extracted logic from current ProfileSyncEngine
      → accumulates changedTypes into per-profile fetchSessionChangedTypes
```

Containers are created lazily on first sync — no need to open all containers at startup. `ProfileContainerManager.container(for:)` already handles this. Because all coordinator code runs on `@MainActor`, the check-then-set in `container(for:)` is safe — no two calls can interleave.

### Fetch Session Batching

The coordinator preserves the current `ProfileSyncEngine`'s fetch session batching pattern to avoid O(N) store reloads during bulk sync:

- On `.willFetchChanges`: set `isFetchingChanges = true`, reset per-profile `fetchSessionChangedTypes` dictionaries
- During `fetchedRecordZoneChanges`: accumulate changed types per profile in `fetchSessionChangedTypes[profileId]`
- On `.didFetchChanges`: set `isFetchingChanges = false`, fire `onRemoteChangesApplied(profileId, changedTypes)` once per profile that had changes, then clear the accumulated state

When `isFetchingChanges` is false (single-record pushes), fire the callback immediately after applying changes — same as today.

If `.didFetchChanges` is never delivered (CKSyncEngine disconnects or crashes), the `isFetchingChanges` flag must not get stuck. **Fix (inherited bug):** Reset `isFetchingChanges` to `false` in `stop()` and in `handleAccountChange(.signOut)`. If the flag is still true when a new `.willFetchChanges` arrives, log a warning and reset it — this means the prior session ended abnormally.

### Sending Side (Local Changes → CloudKit)

Repositories continue to use `onRecordChanged`/`onRecordDeleted` closures (per SYNC_GUIDE Rule 2 — no `NSManagedObjectContextDidSave` observers). The wiring changes from:

```swift
// Before: ProfileSession wires to per-profile engine
repo.onRecordChanged = { [weak syncEngine] id in syncEngine?.queueSave(id: id) }
```

To:

```swift
// After: ProfileSession wires to coordinator with zone ID
repo.onRecordChanged = { [weak coordinator] id in
    coordinator?.queueSave(id: id, zoneID: profileZoneID)
}
```

For the profile index zone, `ProfileStore` explicitly calls `coordinator.queueSave(id:zoneID:profileIndexZoneID)` after profile mutations. This replaces the current `NSManagedObjectContextDidSave` observer in `ProfileIndexSyncEngine`, aligning with SYNC_GUIDE Rule 2.

When CKSyncEngine calls `nextRecordZoneChangeBatch`, the coordinator:
1. Filters pending changes to the requested scope (same as today)
2. Deduplicates using `Set<CKRecord.ID>` (not `Set<UUID>`) — `CKRecord.ID` includes the zone component, so records with the same UUID in different zones are correctly treated as distinct
3. Takes the first 400 (same batch limit as today)
4. For each record, looks up the correct `ModelContainer` by zone ID
5. Builds CKRecords using the same batch-lookup logic as today
6. Returns the batch with `atomicByZone: true` (each zone's records committed atomically, independent across zones)

**Fix (inherited bug): `recordToSave` returning nil.** Currently, if a record is queued for save but deleted locally before the batch is built, `recordToSave` returns nil and the record is silently dropped via `compactMap`. The server never sees the deletion. **Fix:** When `recordToSave` returns nil for a record ID that is in the pending saves, check if a corresponding `.deleteRecord` is already pending. If not, queue a `.deleteRecord` for that ID so the server-side record is cleaned up. Log at `.info` level (this is expected during concurrent local edits, not an error).

### Observer Pattern

`ProfileSession` registers for change notifications using a cancellable token:

```swift
// Registration
let token = coordinator.addObserver(for: profile.id) { changedTypes in
    self.scheduleReloadFromSync(changedTypes: changedTypes)
}
// Token stored as a property on ProfileSession

// Cleanup — token fires on deinit via Task
class SyncObserverToken {
    let profileId: UUID
    weak var coordinator: SyncCoordinator?
    deinit {
        let id = profileId
        let coord = coordinator
        Task { @MainActor in coord?.removeObserver(for: id) }
    }
}
```

This avoids the `nonisolated deinit` calling into `@MainActor`-isolated code directly. The observer dictionary is `@MainActor`-isolated state on `SyncCoordinator` — no lock needed.

Observer closures are typed as `@MainActor (Set<String>) -> Void` to make the isolation contract compiler-enforced.

### Notifications to Active Sessions

After applying changes for a profile zone, the coordinator calls:

```swift
onRemoteChangesApplied?(profileId, changedTypes)
```

`ProfileSession` registers interest when created (see Observer Pattern above). If no session is observing, the data is silently up to date in the `ModelContainer` for next time.

### Zone Creation

The coordinator creates zones proactively (per SYNC_GUIDE Rule 3), with a phased approach:

1. **On `start()`:** Create the `profile-index` zone via `ensureZoneExists()`, then `sendChanges()` once confirmed
2. **On profile zone registration:** When a profile zone is first registered (via `addObserver` or `queueSave` for a new zone ID), create that zone via `ensureZoneExists()` before processing pending sends for it
3. **Fallback:** `SyncErrorRecovery` handles `.zoneNotFound` errors as a safety net (see Bug Fixes below)

This means the coordinator doesn't need to know about all profile zones at startup. Zones are created on-demand as profiles are opened or as sync delivers records for new zones.

**Store the zone-creation task** as `private var zoneSetupTask: Task<Void, Never>?` and cancel it in `stop()`.

### Synthetic Sign-In Guard

CKSyncEngine fires a synthetic `.accountChange(.signIn)` when starting without saved state. The coordinator must handle this:

```swift
private var isFirstLaunch = false

func start() {
    let savedState = loadStateSerialization()
    isFirstLaunch = savedState == nil
    // ... create CKSyncEngine with savedState ...
}

func handleAccountChange(_ change: CKSyncEngine.Event.AccountChange) {
    switch change.changeType {
    case .signIn:
        if isFirstLaunch {
            logger.info("Synthetic sign-in on first launch — skipping re-upload")
            isFirstLaunch = false
        } else {
            logger.info("Account signed in — re-uploading all local data")
            queueAllExistingRecordsForAllZones()
        }
    // ...
    }
}
```

On migration (first launch with new state file), `isFirstLaunch = true`. The synthetic sign-in is ignored. The full fetch delivers all current records from the server; since local data already exists, upserts are no-ops (matched by ID).

### Account Change Handling

Account changes affect all containers:

- **`.signOut`:** Delete local data from the profile-index container AND all profile containers via `ProfileContainerManager`. Delete the shared state file.
- **`.switchAccounts`:** Same as `.signOut` — full reset of all containers and state.
- **`.signIn`:** Guarded by `isFirstLaunch` (see above). On real sign-in, call `queueAllExistingRecordsForAllZones()` which iterates the profile-index container to discover all profile IDs, then queues records from each profile container.

### Zone Deletion Handling

Zone deletions arrive via `fetchedDatabaseChanges` with three reasons:

| Reason | Action |
|--------|--------|
| `.deleted` | Delete local data for that zone only. State file is kept (other zones unaffected). |
| `.purged` | Delete local data for that zone AND delete the shared state file (triggers full re-fetch of all zones on next sync cycle). Conservative but safe — avoids partial state. |
| `.encryptedDataReset` | Delete shared state file, clear system fields for that zone, re-queue all existing records for that zone. |

For `.purged` and `.encryptedDataReset`, deleting the shared state file means all zones re-fetch. This is the simplest correct behavior — a single state file cannot represent "partially valid" state.

### State Persistence

One state serialization file: `Moolah-v2-sync.syncstate`. This replaces the per-engine files (`Moolah-v2-profile-index.syncstate`, `Moolah-<profileId>.syncstate`).

**Migration:** On first launch after the refactor:
1. Delete old state files immediately (they contain per-engine change tokens that are invalid for the unified coordinator — do not attempt to parse them)
2. The coordinator starts without saved state and performs a full fetch
3. CloudKit delivers all current records; since local data already exists, the upserts are no-ops (matched by ID)
4. `isFirstLaunch = true` guards against the synthetic `.signIn` re-upload
5. On `isFirstLaunch`, call `queueAllExistingRecordsForAllZones()` — this queues records from the profile-index container AND every profile container discovered via `ProfileContainerManager`

### Background Sync

`MoolahApp` simplifies from iterating N+1 engines to:

```swift
// Before
await profileIndexSyncEngine.sendChanges()
for engine in activeProfileSyncEngines() {
    await engine.sendChanges()
}

// After
await syncCoordinator.sendChanges()
```

Same for `fetchRemoteChanges()` — one call.

## Inherited Bug Fixes

These bugs exist in the current engines and will be fixed during extraction rather than carried forward.

### 1. SyncErrorRecovery zone creation is fire-and-forget

**Current behavior:** `SyncErrorRecovery.recover()` launches a `Task { }` to create the zone and re-queue records. If zone creation fails, records are permanently lost (error is only logged). If CKSyncEngine calls `nextRecordZoneChangeBatch` before the Task completes, the re-queued records aren't in the pending list yet.

**Fix:** Move zone creation into the coordinator's event handling flow rather than a detached Task. When `SyncErrorRecovery.classify()` returns `zoneNotFoundSaves`/`zoneNotFoundDeletes`, the coordinator:
1. Stores the affected record IDs in a `pendingZoneCreation[zoneID]` dictionary
2. Starts zone creation as a tracked task (`zoneCreationTasks[zoneID]`)
3. On success: re-queues the stored records and clears the dictionary
4. On failure: logs the error, keeps the records in `pendingZoneCreation` for retry on next sync cycle
5. `nextRecordZoneChangeBatch` skips records whose zone is in `pendingZoneCreation` (they'll be re-queued after zone creation succeeds)

### 2. `recordToSave` silently drops missing records

**Current behavior:** If a record is queued for save but deleted locally before the batch is built, `recordToSave` returns nil. The record is `compactMap`'d away. CKSyncEngine removes it from pending. The server-side record is never cleaned up.

**Fix:** In the coordinator's batch builder, when `recordToSave` returns nil: check if a `.deleteRecord` for this ID is already pending. If not, queue a `.deleteRecord`. This ensures the server-side record is cleaned up. Log at `.info` level.

### 3. `isFetchingChanges` can get stuck true

**Current behavior:** If CKSyncEngine disconnects between `.willFetchChanges` and `.didFetchChanges`, the flag stays true, stores never reload, and the app shows stale data.

**Fix:** Reset `isFetchingChanges` in `stop()` and `handleAccountChange(.signOut/.switchAccounts)`. When `.willFetchChanges` arrives while `isFetchingChanges` is already true, log a warning ("prior fetch session ended abnormally") and reset state before starting the new session.

### 4. Model context consistency in system fields updates

**Current behavior:** `applyRemoteChanges` uses `modelContainer.mainContext` while `handleSentRecordZoneChanges` creates new `ModelContext` instances for system field updates. Concurrent modifications to the same record across contexts means last-save-wins.

**Fix:** All ModelContext usage in the coordinator goes through a single pattern: create a new `ModelContext` per operation, do all work in that context, save once. Never use `modelContainer.mainContext` in the coordinator — this avoids interference with contexts held by the UI layer. Since everything is `@MainActor`, there is no concurrent access — operations are serial.

## Performance Instrumentation

The `@MainActor` design is correct for simplicity and safety. The per-call cost of `nextRecordZoneChangeBatch` is unchanged (still max 400 records), and fetch-side batches are bounded by CKSyncEngine. However, we should verify this with measurements.

**Add signpost instrumentation:**

```swift
// In nextRecordZoneChangeBatch
os_signpost(.begin, log: Signposts.sync, name: "nextBatch")
// ... build batch across zones ...
os_signpost(.end, log: Signposts.sync, name: "nextBatch",
    "%{public}d records across %{public}d zones", recordCount, zoneCount)

// In applyProfileDataChanges
os_signpost(.begin, log: Signposts.sync, name: "applyChanges")
// ... upsert/delete ...
os_signpost(.end, log: Signposts.sync, name: "applyChanges",
    "%{public}d saves, %{public}d deletes for zone %{public}@", saves, deletes, zoneID.zoneName)
```

**Add a sync benchmark** to `MoolahBenchmarks` that measures:
- Time to build a 400-record batch across 1, 3, and 5 profile zones
- Time to apply a 200-record fetch batch to a single profile container
- Time for `ProfileContainerManager.container(for:)` on first access (cold) vs subsequent (warm)

If any measurement exceeds 16ms (one frame), restructure that specific path. Until then, the `@MainActor` design stands.

## What Changes

| Component | Before | After |
|-----------|--------|-------|
| `ProfileSyncEngine` | Full CKSyncEngine wrapper (1480 lines) | **Removed.** Batch upsert/delete logic extracted to `ProfileDataSyncHandler` (~400 lines, no CKSyncEngine dependency) |
| `ProfileIndexSyncEngine` | Full CKSyncEngine wrapper (474 lines) | **Removed.** Apply logic extracted to `ProfileIndexSyncHandler`. NSManagedObjectContextDidSave observer removed |
| `SyncCoordinator` | N/A | **New.** Owns CKSyncEngine, routes by zone, manages state (~300 lines) |
| `SyncErrorRecovery` | Fire-and-forget zone creation Task | Zone creation tracked with retry; `recordToSave` nil → queue deletion |
| `ProfileSession` | Creates/owns ProfileSyncEngine, wires callbacks | No longer creates a sync engine. Wires repository callbacks to coordinator. Registers for change notifications via cancellable token |
| `ProfileStore` | No sync awareness | Explicitly calls `coordinator.queueSave/queueDeletion` after profile mutations |
| `MoolahApp` | Manages profileIndexSyncEngine + iterates active profile engines | Manages one `SyncCoordinator` |
| `ProfileContainerManager` | Creates containers for active profiles | Same, but now also creates containers on-demand for background sync of inactive profiles |
| `SYNC_GUIDE.md` | References dual-engine architecture and "review against both engines" rule | Updated to reference `SyncCoordinator` and zone handlers |

## What Doesn't Change

- Repository layer — still calls `onRecordChanged`/`onRecordDeleted` closures
- Record mapping (`RecordMapping.swift`) — untouched
- `RecordTypeRegistry.allTypes` — no record types added or removed
- Batch upsert/delete logic — extracted as-is (into handlers), not rewritten
- Store reload debouncing in `ProfileSession` — same mechanism
- Error recovery classification (`SyncErrorRecovery.classify()`) — same logic, recovery improved
- System fields caching on model records — same pattern
- 400-record batch limit (Rule 13) and dependency ordering in `queueAllExistingRecords` (Rule 14)

## Benefits

- **One fetch per sync cycle** instead of N+1 redundant fetches
- **All profiles stay current** even when not open — instant profile switching
- **Single change token** — no divergent state across engines
- **Follows SYNC_GUIDE:** "One engine per database, managing distinct zones"
- **Simpler app lifecycle** — one engine to start/stop/flush
- **No NSManagedObjectContextDidSave observer** — explicit queueing everywhere
- **Fixes four inherited bugs** — zone creation recovery, nil record drops, stuck fetch flag, context consistency
- **Everything on `@MainActor`** — no concurrency races by construction
