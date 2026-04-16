# Sync Error Handling & Robustness Fixes — Design Spec

**Goal:** Fix five pre-existing sync infrastructure issues identified during the UI freeze investigation: zone filtering on sent changes, quota exceeded user notification, save failure recovery, silent fetch errors, and ModelContext consistency.

**Scope:** Sync layer only (`Backends/CloudKit/Sync/`), plus one new UI component (`SyncStatusBanner`). No changes to domain models, repositories, or existing features.

---

## Issue 1: Filter sentChanges by Zone

### Problem

`SyncCoordinator.handleSentRecordZoneChanges` groups records by zone (lines 640-664) but then passes the full unfiltered `CKSyncEngine.Event.SentRecordZoneChanges` to each zone's handler. Each handler calls `SyncErrorRecovery.classify(sentChanges, ...)` which processes ALL records from ALL zones, causing duplicate classification and re-queuing. The `seenSaves` dedup in `nextRecordZoneChangeBatch` masks this, but it inflates pending state and wastes work.

### Fix

Change handler signatures to accept pre-filtered per-zone records instead of the full event:

```swift
func handleSentRecordZoneChanges(
  savedRecords: [CKRecord],
  failedSaves: [CKSyncEngine.RecordZoneChanges.FailedRecordSave],
  failedDeletes: [(CKRecord.ID, CKError)]
) -> SyncErrorRecovery.ClassifiedFailures
```

Update `SyncErrorRecovery.classify` to accept filtered inputs:

```swift
static func classify(
  failedSaves: [CKSyncEngine.RecordZoneChanges.FailedRecordSave],
  failedDeletes: [(CKRecord.ID, CKError)],
  logger: Logger
) -> ClassifiedFailures
```

The coordinator already has `savedByZone`, `failedSavesByZone`, and `failedDeletesByZone` dictionaries — pass these per-zone slices directly.

### Files

- Modify: `Backends/CloudKit/Sync/SyncErrorRecovery.swift` — change `classify` signature
- Modify: `Backends/CloudKit/Sync/SyncCoordinator.swift` — pass filtered records per zone
- Modify: `Backends/CloudKit/Sync/ProfileDataSyncHandler.swift` — update `handleSentRecordZoneChanges` signature, use new `classify`
- Modify: `Backends/CloudKit/Sync/ProfileIndexSyncHandler.swift` — same

---

## Issue 2: quotaExceeded User Notification

### Problem

When iCloud storage is full, `SyncErrorRecovery` logs the error but doesn't surface it to the user. The sync guide (Rule 9) requires user notification. Records are re-queued but will keep failing silently until the user frees iCloud space.

### Fix

**Data flow:**

1. Add `quotaExceeded` as a dedicated field on `ClassifiedFailures` (instead of lumping into `requeue`). It's still re-queued, but the coordinator can distinguish it.
2. Add `var isQuotaExceeded: Bool` observable property on `SyncCoordinator`. Set to `true` when any zone reports quota errors. Clear when a full send cycle completes with no quota errors.
3. Add `SyncStatusBanner` SwiftUI view that observes `SyncCoordinator.isQuotaExceeded` and displays a persistent non-modal banner.

**SyncStatusBanner behaviour:**

- Appears at the top of the main content area when `isQuotaExceeded` is `true`
- Shows: "iCloud storage is full. Some changes can't sync until you free up space."
- Non-modal, does not interrupt interaction
- Dismissible via an X button (sets a local `@State dismissed` flag)
- Reappears on next sync attempt that hits quota (clears `dismissed` when `isQuotaExceeded` transitions false → true)
- Uses `.yellow` / `.orange` semantic colour for warning severity

**Placement:** The banner is added to the profile content view (the view that wraps the main tab/sidebar content within a profile session). It appears above the content, pushing it down — not overlaid.

### Files

- Modify: `Backends/CloudKit/Sync/SyncErrorRecovery.swift` — add `quotaExceeded` field to `ClassifiedFailures`
- Modify: `Backends/CloudKit/Sync/SyncCoordinator.swift` — add `isQuotaExceeded` property, set/clear logic
- Create: `Features/Sync/SyncStatusBanner.swift` — the banner view
- Modify: `App/ProfileSession.swift` or the profile content view — add the banner

---

## Issue 3: Re-fetch on Save Failure

### Problem

When `context.save()` fails in `applyRemoteChanges`, the handler logs the error and returns an empty `changedTypes` set. Observers are never notified, and the data from that batch is silently lost. The local store diverges from iCloud with no recovery path until the next full sync.

### Fix

**Return type:** Change `applyRemoteChanges` to return a result that distinguishes success from failure:

```swift
enum ApplyResult {
  case success(changedTypes: Set<String>)
  case saveFailed(Error)
}
```

**Coordinator handling:** On `.saveFailed`:
1. Log the error at `.error` level (already done in the handler)
2. Skip observer notification (nothing was saved)
3. Schedule a re-fetch: call `syncEngine.fetchChanges()` after a 5-second delay to avoid tight retry loops. Use a single coalescing task — if multiple batches fail, only one re-fetch is scheduled.

**Why re-fetch works:** CKSyncEngine tracks server change tokens. A failed local save doesn't advance the token, so the next `fetchChanges()` re-delivers the same records. This is the intended recovery path.

**ProfileIndexSyncHandler:** Same pattern — return `ApplyResult` instead of `Void`. Coordinator handles `.saveFailed` identically.

### Files

- Create: `Backends/CloudKit/Sync/ApplyResult.swift` — the result enum (shared by both handlers)
- Modify: `Backends/CloudKit/Sync/ProfileDataSyncHandler.swift` — return `ApplyResult`
- Modify: `Backends/CloudKit/Sync/ProfileIndexSyncHandler.swift` — return `ApplyResult`
- Modify: `Backends/CloudKit/Sync/SyncCoordinator.swift` — handle `.saveFailed`, schedule re-fetch

---

## Issue 4: Replace try? with Logged Errors

### Problem

`ProfileDataSyncHandler.buildBatchRecordLookup` has 7 instances of `(try? context.fetch(...)) ?? []`. If SwiftData fails (schema migration error, store corruption), records silently disappear from upload batches with no log entry.

Similar patterns exist in `ProfileIndexSyncHandler` for `try? context.fetch(...)` in `applyRemoteChanges`, `queueAllExistingRecords`, etc.

### Fix

Add a private helper to each handler:

```swift
private func fetchOrLog<T: PersistentModel>(
  _ descriptor: FetchDescriptor<T>,
  context: ModelContext
) -> [T] {
  do {
    return try context.fetch(descriptor)
  } catch {
    logger.error("SwiftData fetch failed for \(T.self): \(error)")
    return []
  }
}
```

Replace all `(try? context.fetch(...)) ?? []` with `fetchOrLog(descriptor, context: context)`.

The behaviour is identical (fetch failure returns empty array, code continues) but failures are now visible in logs.

### Files

- Modify: `Backends/CloudKit/Sync/ProfileDataSyncHandler.swift` — add helper, replace 7 `try?` sites in `buildBatchRecordLookup`
- Modify: `Backends/CloudKit/Sync/ProfileIndexSyncHandler.swift` — add helper, replace `try?` sites in `applyRemoteChanges` and other methods

---

## Issue 5: Use mainContext for On-Main Methods

### Problem

`ProfileIndexSyncHandler`'s `@MainActor` methods create `ModelContext(modelContainer)` instead of using `modelContainer.mainContext`. This creates a second context on the main thread alongside the main context. Changes aren't visible to other `@MainActor` code reading from `mainContext` until saved and merged. This is contrary to SwiftData conventions and can cause stale reads.

### Fix

Change `@MainActor` methods in `ProfileIndexSyncHandler` to use `modelContainer.mainContext` instead of creating a fresh `ModelContext(modelContainer)`.

**Affected methods:**
- `deleteLocalData`
- `clearAllSystemFields`
- `queueAllExistingRecords`
- `recordToSave`
- `updateEncodedSystemFields`
- `clearEncodedSystemFields`
- `handleSentRecordZoneChanges`

**Not affected:** `applyRemoteChanges` — this is `nonisolated` and intentionally creates its own context for off-main work.

**Same fix for ProfileDataSyncHandler:** Check whether any `@MainActor` methods there also create fresh contexts instead of using `mainContext`, and fix those too.

### Files

- Modify: `Backends/CloudKit/Sync/ProfileIndexSyncHandler.swift` — replace `ModelContext(modelContainer)` with `modelContainer.mainContext` in `@MainActor` methods
- Modify: `Backends/CloudKit/Sync/ProfileDataSyncHandler.swift` — same check and fix

---

## Testing Strategy

All fixes are testable against the existing `TestBackend` (CloudKitBackend + in-memory SwiftData):

- **Issue 1:** Existing sync handler tests verify `handleSentRecordZoneChanges` — update to use new signature. Add a test that verifies records from zone A are not processed by zone B's handler.
- **Issue 2:** Test that `SyncCoordinator.isQuotaExceeded` is set when `classify` returns quota errors, and cleared after a clean send cycle.
- **Issue 3:** Test that `applyRemoteChanges` returns `.saveFailed` when context save fails (can be triggered by deleting the model container mid-operation). Test that coordinator schedules re-fetch on failure.
- **Issue 4:** No new tests needed — this is a logging change with identical behaviour. Existing tests cover the fetch paths.
- **Issue 5:** No new tests needed — this fixes context consistency. Existing tests pass through both code paths.

## Order of Implementation

Issues are independent and can be implemented in any order. Recommended order by risk:

1. **Issue 4** (try? → logged errors) — zero-risk mechanical change, immediate observability improvement
2. **Issue 5** (mainContext consistency) — low-risk, fixes potential stale reads
3. **Issue 1** (zone filtering) — moderate complexity, changes multiple signatures
4. **Issue 3** (save failure recovery) — new return type, new coordinator logic
5. **Issue 2** (quota banner) — most complex, new UI component + observable state
