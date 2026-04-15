# UI Freeze Investigation — 2026-04-15

## Problem

The app regularly freezes/locks up during CloudKit sync. The UI becomes unresponsive for 500-600ms at a time, repeatedly, as CKSyncEngine delivers batches of ~200 records.

## Root Cause Identified

`ProfileDataSyncHandler.applyRemoteChanges` processes 200-record batches synchronously on `@MainActor`. Each batch blocks the main thread for ~570ms:
- **Upsert phase: ~520ms** — SwiftData fetch + insert/update per record type (the dominant cost is `batchUpsertTransactionLegs` doing SQLite reads via CoreData)
- **Context save: ~55ms**

The `SyncCoordinator.handleEvent` delegate callback hops to `@MainActor` via `await MainActor.run { handleEventOnMain(...) }`, which means the entire batch processing runs on the main thread.

## Why the Unified SyncCoordinator Made It Worse

The old architecture had N+1 `CKSyncEngine` instances (one per profile + one for the profile index). Each engine fetched independently. The new unified `SyncCoordinator` has a single `CKSyncEngine` that delivers all zones' changes in one stream. During initial/catchup sync, batches of 200 records arrive back-to-back (~10 batches in 90 seconds), each blocking the main thread for ~570ms.

The design doc (commit `cc74f08`) explicitly acknowledged this risk: *"The `@MainActor` design is correct for simplicity and safety... However, we should verify this with measurements."* The measurements now show the per-batch cost exceeds the 16ms frame budget by 35x.

## Evidence

### PERF Logs (original code)

```
PERF: applyRemoteChanges blocked main thread for 578ms (upsert: 522ms, save: 56ms, 200 saves, 0 deletes)
PERF: applyFetchedChanges blocked main thread for 584ms
```

These repeat every ~10 seconds during sync.

### Stack Sample (with off-main fix applied)

Confirmed the fix moves work off-main. The hot path on background threads:

```
SyncCoordinator.handleEvent → handleFetchedRecordZoneChangesAsync
  → ProfileDataSyncHandler.applyRemoteChanges
    → applyBatchSaves → batchUpsertTransactionLegs
      → SwiftData → CoreData → NSManagedObjectContext.performAndWait
        → NSSQLiteConnection.performAndWait → sqlite3_step → pread
```

Main thread was idle (2251/3438 samples in `mach_msg2_trap`).

## Attempted Fix — Off-Main applyRemoteChanges

**Approach:** Make `applyRemoteChanges` `nonisolated` on both handlers (safe because they only use `nonisolated let` properties and create fresh `ModelContext` per call), then restructure `handleEvent` to run the heavy work off-main and only hop to `@MainActor` for handler resolution and observer notifications.

**Status:** Builds and passes tests (774 iOS + 790 macOS). Stack sampling confirms sync runs off-main. However, the user reported the app still froze — further instrumentation needed to identify what else is blocking the main thread (possibly SwiftData merge notifications from `context.save()` on the background context, or observer-triggered store reloads).

**Next steps:**
1. Apply the stashed diff (see below)
2. Add instrumentation to the observer notification callbacks and store reload paths to measure their main-thread cost
3. Use `sample` to capture a stack trace during an actual freeze with the off-main fix applied
4. If SwiftData `context.save()` merge is the culprit, consider using `ModelActor` or a separate `ModelContainer`

## Stashed Diff

The work-in-progress changes are in `git stash` (`WIP: off-main sync changes`). Key changes:

### ProfileDataSyncHandler.swift
- `applyRemoteChanges` marked `nonisolated` — safe because it only uses `nonisolated let` properties (`profileId`, `zoneID`, `modelContainer`, `logger`) and creates a fresh `ModelContext` per call
- PERF log threshold raised from 16ms to 100ms, severity changed from warning to info (no longer blocking main thread)

### ProfileIndexSyncHandler.swift
- `applyRemoteChanges` marked `nonisolated` — same reasoning

### SyncCoordinator.swift
- `parseZone` marked `nonisolated static` (pure computation)
- `handleEvent` routes `fetchedRecordZoneChanges` to new `handleFetchedRecordZoneChangesAsync` instead of `handleEventOnMain`
- `handleFetchedRecordZoneChangesAsync` is `nonisolated` and `async`:
  - Groups records by zone off-main
  - Pre-extracts system fields off-main
  - Hops to `@MainActor` briefly to resolve handlers via `handlerForProfileZone`
  - Runs `applyRemoteChanges` off-main
  - Hops to `@MainActor` for observer notifications
- `handleEventOnMain` has `fetchedRecordZoneChanges` case as a no-op `break`

To apply: `git stash pop`
